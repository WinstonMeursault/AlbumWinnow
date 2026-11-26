use crate::{
    CoreError,
    matching::MatchKind,
    model::AssetId,
    review::{
        ProtectionState, ReadOnlyPolicy, ReviewAsset, ReviewDecision, ReviewGroup, ReviewSettings,
        ReviewSort, ReviewStatus, SourceKind, SourceRecord,
    },
    review_query::SizeEstimate,
    review_store::{ReviewMetadata, ReviewSnapshot, ReviewStore, StoredDecision, StoredGroup},
};
use serde::Serialize;
use std::{collections::BTreeMap, path::Path};

mod cleanup;
mod presentation;
mod read_only;
pub use presentation::{ReviewOverview, ReviewPageMode};
mod scan;

#[cfg(test)]
mod tests;

#[derive(Clone, Debug, Serialize)]
pub enum ReviewIntent {
    ConfirmKeep { keep: AssetId },
    ConfirmDeleteAll,
    SetStatus { status: ReviewStatus },
}
#[derive(Clone, Debug)]
pub struct GroupSummary {
    pub signature: String,
    pub preferred: AssetId,
    pub ordinal: u64,
    pub kind: MatchKind,
    pub member_count: u64,
    pub status: ReviewStatus,
    pub latest_date: Option<f64>,
    pub estimate: SizeEstimate,
    pub confirmed_removal_count: u64,
    pub saved_removal_count: u64,
    /// Preferred first; the saved keeper second only when different. At most2.
    pub preview_assets: Vec<ReviewAsset>,
    pub preferred_evidence: Option<crate::review::ReviewEvidence>,
}
pub struct GroupDetail<'a> {
    pub group: &'a ReviewGroup,
    pub decision: Option<&'a ReviewDecision>,
}
pub struct ReviewDelta {
    pub metadata: ReviewMetadata,
    pub signature: String,
    pub decision: ReviewDecision,
    pub replayed: bool,
}
pub struct SourceInput {
    pub kind: SourceKind,
    pub namespace: String,
    pub identity: Vec<u8>,
    pub bookmark: Vec<u8>,
    pub label: String,
}
struct StagedScan {
    operation: String,
    revision: u64,
    groups: Vec<ReviewGroup>,
    assets: BTreeMap<AssetId, crate::review_scan::PackedScanReviewAsset>,
}
struct StagedReadOnly {
    operation: String,
    revision: u64,
    policy: ReadOnlyPolicy,
    seen: std::collections::BTreeSet<AssetId>,
}

/// The one live owner of review state. Hosts receive pages, details and deltas;
/// persistence always finishes before the corresponding in-memory change.
pub struct ReviewSession {
    store: ReviewStore,
    metadata: ReviewMetadata,
    sources: BTreeMap<String, SourceRecord>,
    groups: BTreeMap<String, StoredGroup>,
    decisions: BTreeMap<String, StoredDecision>,
    protection: ProtectionState,
    settings: ReviewSettings,
    anchor: Option<String>,
    position: Option<u64>,
    navigation_sequence: u64,
    healthy: bool,
    query_order: Option<Vec<String>>,
    staged_scan: Option<StagedScan>,
    staged_read_only: Option<StagedReadOnly>,
    cleanup: Option<crate::cleanup::run::CleanupRun>,
    last_cleanup: Vec<crate::cleanup::run::CleanupItemResult>,
    last_cleanup_operation: Option<String>,
}

impl ReviewSession {
    pub fn open(path: &Path, initialized: bool) -> Result<Self, CoreError> {
        let mut store = ReviewStore::open(path, initialized)?;
        let snapshot = store.load()?;
        let mut session = Self {
            store,
            metadata: snapshot.metadata.clone(),
            sources: BTreeMap::new(),
            groups: BTreeMap::new(),
            decisions: BTreeMap::new(),
            protection: ProtectionState::default(),
            settings: ReviewSettings::default(),
            anchor: None,
            position: None,
            navigation_sequence: 0,
            healthy: true,
            query_order: None,
            staged_scan: None,
            staged_read_only: None,
            cleanup: None,
            last_cleanup: Vec::new(),
            last_cleanup_operation: None,
        };
        session.adopt(snapshot);
        Ok(session)
    }
    fn adopt(&mut self, snapshot: ReviewSnapshot) {
        self.metadata = snapshot.metadata;
        self.sources = snapshot
            .sources
            .into_iter()
            .map(|s| (s.id.clone(), s))
            .collect();
        self.groups = snapshot
            .groups
            .into_iter()
            .map(|g| (g.signature.clone(), g))
            .collect();
        self.decisions = snapshot
            .decisions
            .into_iter()
            .map(|d| (d.signature.clone(), d))
            .collect();
        self.protection = snapshot.protection;
        self.settings = snapshot.settings;
        self.anchor = snapshot.anchor;
        self.position = snapshot.position;
        self.navigation_sequence = snapshot.navigation_sequence;
        self.query_order = None;
    }
    fn storage_result<T>(&mut self, result: Result<T, CoreError>) -> Result<T, CoreError> {
        if matches!(
            &result,
            Err(CoreError::WriteFailed
                | CoreError::StorageCorrupt
                | CoreError::StorageUnavailable
                | CoreError::ProtectionUnavailable
                | CoreError::UnsupportedSchema)
        ) {
            self.healthy = false;
        }
        result
    }
    fn ensure_healthy(&mut self) -> Result<(), CoreError> {
        if !self.healthy {
            return Err(CoreError::ProtectionUnavailable);
        }
        let result = self.store.ensure_current();
        self.storage_result(result)
    }
    fn ensure_cleanup_idle(&self) -> Result<(), CoreError> {
        if self.cleanup.as_ref().is_some_and(|run| run.busy()) {
            return Err(CoreError::InvalidState);
        }
        Ok(())
    }
    fn ensure_editable(&mut self) -> Result<(), CoreError> {
        self.ensure_healthy()?;
        self.ensure_cleanup_idle()
    }
    pub fn healthy(&self) -> bool {
        self.healthy
    }
    pub fn metadata(&self) -> &ReviewMetadata {
        &self.metadata
    }
    pub fn settings(&self) -> &ReviewSettings {
        &self.settings
    }
    pub fn sources(&self) -> impl Iterator<Item = &SourceRecord> {
        self.sources.values()
    }
    pub fn protection(&self) -> &ProtectionState {
        &self.protection
    }
    pub fn navigation_sequence(&self) -> u64 {
        self.navigation_sequence
    }
    pub fn position(&self) -> (Option<&str>, Option<u64>) {
        (self.anchor.as_deref(), self.position)
    }
    pub fn validate_storage(&mut self) -> Result<(), CoreError> {
        self.ensure_healthy()
    }
    pub fn invalid_decision_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|d| d.decision.invalidated)
            .count()
    }

    pub fn register_source(
        &mut self,
        expected: u64,
        input: SourceInput,
    ) -> Result<SourceRecord, CoreError> {
        self.ensure_editable()?;
        let result = self.store.register_source(
            expected,
            input.kind,
            input.namespace,
            input.identity,
            input.bookmark,
            input.label,
        );
        let committed = self.storage_result(result)?;
        if committed.metadata.scope_epoch != self.metadata.scope_epoch {
            for group in self.groups.values_mut() {
                group.active = false;
            }
            self.query_order = None;
        }
        self.metadata = committed.metadata;
        self.sources
            .insert(committed.source.id.clone(), committed.source.clone());
        Ok(committed.source)
    }
    pub fn set_source_active(
        &mut self,
        expected: u64,
        id: &str,
        active: bool,
    ) -> Result<SourceRecord, CoreError> {
        self.ensure_editable()?;
        let result = self.store.set_source_active(expected, id, active);
        let committed = self.storage_result(result)?;
        if committed.metadata.scope_epoch != self.metadata.scope_epoch {
            for group in self.groups.values_mut() {
                group.active = false;
            }
            self.query_order = None;
        }
        self.metadata = committed.metadata;
        self.sources
            .insert(committed.source.id.clone(), committed.source.clone());
        Ok(committed.source)
    }
    pub fn complete_scan(
        &mut self,
        expected: u64,
        groups: Vec<ReviewGroup>,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let result = self.store.complete_scan(expected, groups);
        self.storage_result(result)?;
        let result = self.store.load();
        let snapshot = self.storage_result(result)?;
        self.adopt(snapshot);
        Ok(())
    }
    pub fn begin_scan(&mut self, expected: u64, operation: String) -> Result<(), CoreError> {
        self.ensure_editable()?;
        if operation.is_empty() || operation.len() > 256 {
            return Err(CoreError::InvalidValue);
        }
        if expected != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        self.staged_scan = Some(StagedScan {
            operation,
            revision: expected,
            groups: Vec::new(),
            assets: BTreeMap::new(),
        });
        Ok(())
    }
    pub fn append_scan_groups(
        &mut self,
        operation: &str,
        groups: Vec<ReviewGroup>,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        if groups.len() > 16 {
            return Err(CoreError::InvalidBuffer);
        }
        let staged = self.staged_scan.as_mut().ok_or(CoreError::InvalidState)?;
        if staged.operation != operation || staged.revision != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        if !staged.assets.is_empty() {
            return Err(CoreError::InvalidState);
        }
        for group in &groups {
            group.validate()?;
        }
        staged.groups.extend(groups);
        Ok(())
    }
    pub fn finish_scan(&mut self, operation: &str) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let staged = self.staged_scan.as_ref().ok_or(CoreError::InvalidState)?;
        if staged.operation != operation || staged.revision != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        if !staged.assets.is_empty() {
            return Err(CoreError::InvalidState);
        }
        let staged = self.staged_scan.take().ok_or(CoreError::InvalidState)?;
        self.complete_scan(staged.revision, staged.groups)
    }
    pub fn discard_scan(&mut self, operation: &str) -> Result<(), CoreError> {
        if self
            .staged_scan
            .as_ref()
            .is_some_and(|s| s.operation != operation)
        {
            return Err(CoreError::StaleOperation);
        }
        self.staged_scan = None;
        Ok(())
    }
    pub fn apply_intent(
        &mut self,
        expected: u64,
        signature: &str,
        command_id: String,
        intent: ReviewIntent,
    ) -> Result<ReviewDelta, CoreError> {
        self.ensure_healthy()?;
        if command_id.is_empty() || command_id.len() > 256 {
            return Err(CoreError::InvalidValue);
        }
        let bytes = serde_json::to_vec(&intent).map_err(|_| CoreError::InvalidValue)?;
        let mut hash = blake3::Hasher::new();
        hash.update(b"AlbumWinnow.v2.review-command.1\0");
        hash.update(&(signature.len() as u64).to_le_bytes());
        hash.update(signature.as_bytes());
        hash.update(&bytes);
        let request_hash = *hash.finalize().as_bytes();
        if let Some(previous) = self.decisions.get(signature)
            && previous.command_id.as_ref() == Some(&command_id)
        {
            if previous.request_hash.as_deref() != Some(request_hash.as_slice()) {
                return Err(CoreError::InvalidValue);
            }
            return Ok(ReviewDelta {
                metadata: self.metadata.clone(),
                signature: signature.into(),
                decision: previous.decision.clone(),
                replayed: true,
            });
        }
        self.ensure_cleanup_idle()?;
        if expected != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        let stored = self.groups.get(signature).ok_or(CoreError::InvalidValue)?;
        if !stored.active
            || self.metadata.scan_generation == 0
            || self.metadata.scan_scope_epoch != self.metadata.scope_epoch
        {
            return Err(CoreError::StaleOperation);
        }
        let group = &stored.group;
        let decision = match intent {
            ReviewIntent::ConfirmKeep { keep } => {
                ReviewDecision::confirm(group, Some(keep), false, &self.protection)?
            }
            ReviewIntent::ConfirmDeleteAll => {
                ReviewDecision::confirm(group, None, true, &self.protection)?
            }
            ReviewIntent::SetStatus {
                status: ReviewStatus::Confirmed,
            } => return Err(CoreError::InvalidValue),
            ReviewIntent::SetStatus { status } => {
                let mut decision = self
                    .decisions
                    .get(signature)
                    .filter(|d| !d.decision.invalidated)
                    .map(|d| d.decision.clone())
                    .unwrap_or_default();
                if status == ReviewStatus::Kept || status == ReviewStatus::Pending {
                    decision = ReviewDecision::default();
                }
                decision.status = status;
                decision.invalidated = false;
                decision.prune(group, &self.protection);
                decision
            }
        };
        let result = self.store.save_decision(
            expected,
            signature,
            decision,
            command_id.clone(),
            request_hash,
        );
        let committed = self.storage_result(result)?;
        self.metadata = committed.metadata;
        self.decisions.insert(
            signature.into(),
            StoredDecision {
                signature: signature.into(),
                decision: committed.decision.clone(),
                command_id: Some(command_id),
                request_hash: Some(request_hash.to_vec()),
            },
        );
        self.query_order = None;
        Ok(ReviewDelta {
            metadata: self.metadata.clone(),
            signature: signature.into(),
            decision: committed.decision,
            replayed: committed.replayed,
        })
    }

    fn commit_protection(
        &mut self,
        expected: u64,
        protection: ProtectionState,
    ) -> Result<(), CoreError> {
        let result = self.store.save_protection(expected, &protection);
        let committed = self.storage_result(result)?;
        for (signature, decision) in committed.changed_decisions {
            if let Some(stored) = self.decisions.get_mut(&signature) {
                stored.decision = decision;
            }
        }
        self.protection = protection;
        self.metadata = committed.metadata;
        self.query_order = None;
        Ok(())
    }
    pub fn set_locked(
        &mut self,
        expected: u64,
        asset: ReviewAsset,
        locked: bool,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let protection = self.protection.setting_lock(asset, locked)?;
        self.commit_protection(expected, protection)
    }
    pub fn remove_saved_lock(&mut self, expected: u64, id: &AssetId) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let protection = self.protection.removing_saved_lock(id)?;
        self.commit_protection(expected, protection)
    }
    pub fn set_read_only(
        &mut self,
        expected: u64,
        source: &str,
        policy: Option<ReadOnlyPolicy>,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let protection = self.protection.setting_read_only(source, policy)?;
        self.commit_protection(expected, protection)
    }
    pub fn save_settings(
        &mut self,
        expected: u64,
        settings: ReviewSettings,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let result = self.store.save_settings(expected, &settings);
        let metadata = self.storage_result(result)?;
        if metadata.scope_epoch != self.metadata.scope_epoch {
            for group in self.groups.values_mut() {
                group.active = false;
            }
        }
        self.metadata = metadata;
        self.settings = settings;
        self.query_order = None;
        Ok(())
    }
    pub fn save_position(
        &mut self,
        expected: u64,
        sequence: u64,
        anchor: Option<String>,
        position: Option<u64>,
    ) -> Result<(), CoreError> {
        self.ensure_healthy()?;
        let result = self
            .store
            .save_position(expected, sequence, anchor.clone(), position);
        self.storage_result(result)?;
        self.anchor = anchor;
        self.position = position;
        self.navigation_sequence = sequence;
        Ok(())
    }
    pub fn reset_progress(&mut self, expected: u64) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let result = self.store.reset_progress(expected);
        self.metadata = self.storage_result(result)?;
        self.decisions.clear();
        self.groups.retain(|_, g| g.active);
        self.anchor = None;
        self.position = None;
        self.navigation_sequence += 1;
        self.query_order = None;
        Ok(())
    }
    pub fn remove_invalid_decisions(&mut self, expected: u64) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let result = self.store.remove_invalid_decisions(expected);
        self.metadata = self.storage_result(result)?;
        self.decisions.retain(|_, d| !d.decision.invalidated);
        self.groups
            .retain(|signature, g| g.active || self.decisions.contains_key(signature));
        self.query_order = None;
        Ok(())
    }
    pub fn detail(&mut self, signature: &str) -> Result<GroupDetail<'_>, CoreError> {
        self.ensure_healthy()?;
        let stored = self
            .groups
            .get(signature)
            .filter(|g| g.active)
            .ok_or(CoreError::InvalidValue)?;
        Ok(GroupDetail {
            group: &stored.group,
            decision: self.decisions.get(signature).map(|d| &d.decision),
        })
    }
    pub fn group_summary(&mut self, signature: &str) -> Result<GroupSummary, CoreError> {
        self.ensure_healthy()?;
        let stored = self
            .groups
            .get(signature)
            .filter(|g| g.active)
            .ok_or(CoreError::InvalidValue)?;
        Ok(self.summary(stored, true))
    }
    fn summary(&self, stored: &StoredGroup, include_preview: bool) -> GroupSummary {
        let decision = self
            .decisions
            .get(&stored.signature)
            .filter(|d| !d.decision.invalidated)
            .map(|d| &d.decision);
        let removals = stored.group.estimated_removals(decision, &self.protection);
        GroupSummary {
            signature: stored.signature.clone(),
            preferred: stored.group.preferred.clone(),
            ordinal: stored.ordinal,
            kind: stored.group.match_kind(),
            member_count: stored.group.members.len() as u64,
            status: decision.map_or(ReviewStatus::Pending, |d| d.status),
            latest_date: stored.group.latest_date(),
            estimate: stored.group.size_estimate(&removals),
            confirmed_removal_count: decision
                .filter(|d| d.status == ReviewStatus::Confirmed)
                .map_or(0, |_| removals.len() as u64),
            saved_removal_count: decision
                .filter(|d| {
                    !d.removals.is_empty()
                        && matches!(d.status, ReviewStatus::Confirmed | ReviewStatus::Deferred)
                })
                .map_or(0, |_| removals.len() as u64),
            preview_assets: if include_preview {
                let group = &stored.group;
                let mut assets = Vec::with_capacity(2);
                if let Some(asset) = group.members.iter().find(|a| a.id == group.preferred) {
                    assets.push(asset.clone());
                }
                if let Some(keep) = decision.and_then(|d| d.keep.as_ref())
                    && *keep != group.preferred
                    && let Some(asset) = group.members.iter().find(|a| a.id == *keep)
                {
                    assets.push(asset.clone());
                }
                assets
            } else {
                Vec::new()
            },
            preferred_evidence: include_preview
                .then(|| {
                    stored
                        .group
                        .evidence
                        .iter()
                        .find(|e| e.asset == stored.group.preferred)
                        .cloned()
                })
                .flatten(),
        }
    }
    fn ordered_query(&mut self) {
        if self.query_order.is_some() {
            return;
        }
        let query = &self.settings.query;
        let mut summaries: Vec<_> = self
            .groups
            .values()
            .filter(|g| g.active)
            .filter(|g| {
                query.includes(
                    &g.group,
                    self.decisions
                        .get(&g.signature)
                        .filter(|d| !d.decision.invalidated)
                        .map_or(ReviewStatus::Pending, |d| d.decision.status),
                )
            })
            .map(|g| self.summary(g, false))
            .collect();
        summaries.sort_by(|a, b| {
            use std::cmp::Ordering;
            let order = match query.sort {
                ReviewSort::Stable => Ordering::Equal,
                ReviewSort::Newest | ReviewSort::Oldest => match (a.latest_date, b.latest_date) {
                    (Some(a), Some(b)) => {
                        if query.sort == ReviewSort::Newest {
                            b.total_cmp(&a)
                        } else {
                            a.total_cmp(&b)
                        }
                    }
                    (Some(_), None) => Ordering::Less,
                    (None, Some(_)) => Ordering::Greater,
                    (None, None) => Ordering::Equal,
                },
                ReviewSort::Count => b.member_count.cmp(&a.member_count),
                ReviewSort::Bytes => b
                    .estimate
                    .has_known_amount()
                    .cmp(&a.estimate.has_known_amount())
                    .then_with(|| b.estimate.known_bytes.cmp(&a.estimate.known_bytes)),
            };
            order.then_with(|| a.ordinal.cmp(&b.ordinal))
        });
        self.query_order = Some(summaries.into_iter().map(|s| s.signature).collect());
    }
    pub fn query_count(&mut self) -> Result<usize, CoreError> {
        self.ensure_healthy()?;
        self.ordered_query();
        Ok(self.query_order.as_ref().map_or(0, Vec::len))
    }
    pub fn query_page(
        &mut self,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<GroupSummary>, CoreError> {
        self.ensure_healthy()?;
        if limit > 256 {
            return Err(CoreError::InvalidValue);
        }
        self.ordered_query();
        Ok(self
            .query_order
            .as_ref()
            .into_iter()
            .flatten()
            .skip(offset)
            .take(limit)
            .filter_map(|signature| self.groups.get(signature))
            .map(|group| self.summary(group, true))
            .collect())
    }
    pub fn resume_signature(&mut self) -> Result<Option<String>, CoreError> {
        self.ensure_healthy()?;
        self.ordered_query();
        let order = self.query_order.as_ref().ok_or(CoreError::InvalidState)?;
        let status = |signature: &String| {
            self.decisions
                .get(signature)
                .filter(|d| !d.decision.invalidated)
                .map_or(ReviewStatus::Pending, |d| d.decision.status)
        };
        if let Some(anchor) = &self.anchor
            && order.contains(anchor)
            && status(anchor) != ReviewStatus::Kept
        {
            return Ok(Some(anchor.clone()));
        }
        let mut first = None;
        for (index, signature) in order.iter().enumerate() {
            if matches!(
                status(signature),
                ReviewStatus::Pending | ReviewStatus::Deferred
            ) {
                if first.is_none() {
                    first = Some(signature.clone());
                }
                if index as u64 >= self.position.unwrap_or(0) {
                    return Ok(Some(signature.clone()));
                }
            }
        }
        Ok(first)
    }
}
