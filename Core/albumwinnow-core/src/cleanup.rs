use crate::{
    CoreError,
    matching::MatchKind,
    model::SceneProvider,
    review::{
        ProtectionState, ReviewAsset, ReviewDecision, ReviewGroup, ReviewStatus, SourceKind,
        SourceRecord,
    },
    review_store::ReviewMetadata,
    scene::{self, SceneQuality},
};
use std::collections::{BTreeMap, BTreeSet, HashSet};

pub mod run;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CleanupEpochs {
    pub scan_generation: u64,
    pub scope: u64,
    pub protection: u64,
    pub decision: u64,
}
impl From<&ReviewMetadata> for CleanupEpochs {
    fn from(value: &ReviewMetadata) -> Self {
        Self {
            scan_generation: value.scan_generation,
            scope: value.scope_epoch,
            protection: value.protection_epoch,
            decision: value.decision_epoch,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanupReason {
    StalePlan,
    InvalidSelection,
    UnavailableSource,
    UnavailableProtection,
    ChangedAsset,
    ProtectedResources,
    UserProtected,
    ReadOnlySource,
    SameFile,
    NoLongerDuplicate,
    Inaccessible,
    Cancelled,
    OperationInProgress,
}
#[derive(Clone, Debug)]
pub struct CleanupPair {
    pub group_signature: String,
    pub keep: Option<ReviewAsset>,
    pub remove: ReviewAsset,
    pub scene: Option<SceneProvider>,
}
#[derive(Clone, Debug)]
pub struct CleanupGroup {
    pub signature: String,
    pub kind: MatchKind,
    pub retained: Vec<ReviewAsset>,
    pub pairs: Vec<CleanupPair>,
    pub delete_all: bool,
}
pub struct PlanGroup<'a> {
    pub signature: &'a str,
    pub group: &'a ReviewGroup,
    pub decision: Option<&'a ReviewDecision>,
}
#[derive(Clone, Debug)]
pub struct CleanupPlan {
    pub operation: String,
    pub epochs: CleanupEpochs,
    pub groups: Vec<CleanupGroup>,
    sources: BTreeMap<String, SourceRecord>,
}
impl CleanupPlan {
    pub fn build<'a>(
        operation: String,
        metadata: &ReviewMetadata,
        groups: impl IntoIterator<Item = PlanGroup<'a>>,
        sources: impl IntoIterator<Item = &'a SourceRecord>,
        protection: &ProtectionState,
    ) -> Result<Self, CoreError> {
        if operation.is_empty() || operation.len() > 256 {
            return Err(CoreError::InvalidValue);
        }
        if metadata.scan_generation == 0 || metadata.scan_scope_epoch != metadata.scope_epoch {
            return Err(CoreError::StaleOperation);
        }
        let mut registered = BTreeMap::new();
        for source in sources {
            source.validate()?;
            if registered
                .insert(source.id.clone(), source.clone())
                .is_some()
            {
                return Err(CoreError::InvalidValue);
            }
        }
        let mut plan = Self {
            operation,
            epochs: metadata.into(),
            groups: Vec::new(),
            sources: registered,
        };
        let mut signatures = HashSet::new();
        let mut all_assets = BTreeMap::new();
        for input in groups {
            for asset in &input.group.members {
                if all_assets.insert(&asset.id, asset).is_some() {
                    return Err(CoreError::InvalidValue);
                }
            }
            let Some(decision) = input.decision.filter(|d| {
                !d.invalidated
                    && matches!(d.status, ReviewStatus::Confirmed | ReviewStatus::Deferred)
                    && !d.removals.is_empty()
            }) else {
                continue;
            };
            input.group.validate()?;
            decision.validate(input.group)?;
            if input.group.signature()? != input.signature || !signatures.insert(input.signature) {
                return Err(CoreError::InvalidValue);
            }
            if input.group.members.iter().any(|a| {
                plan.sources
                    .get(&a.id.source_id)
                    .is_none_or(|s| !s.active || s.kind != a.kind)
            }) {
                return Err(CoreError::ProtectionUnavailable);
            }
            let by_id: BTreeMap<_, _> = input.group.members.iter().map(|a| (&a.id, a)).collect();
            let pairs = if decision.delete_all {
                if input.group.members.iter().any(|a| protection.protected(a)) {
                    continue;
                }
                input
                    .group
                    .members
                    .iter()
                    .map(|asset| CleanupPair {
                        group_signature: input.signature.into(),
                        keep: None,
                        remove: asset.clone(),
                        scene: input.group.scene.clone(),
                    })
                    .collect::<Vec<_>>()
            } else {
                let keep = decision.keep.as_ref().ok_or(CoreError::InvalidValue)?;
                input
                    .group
                    .removal_pairs(keep, protection)
                    .into_iter()
                    .filter(|(_, remove)| decision.removals.contains(remove))
                    .map(|(keep, remove)| CleanupPair {
                        group_signature: input.signature.into(),
                        keep: Some(by_id[&keep].clone()),
                        remove: by_id[&remove].clone(),
                        scene: input.group.scene.clone(),
                    })
                    .collect()
            };
            if pairs.is_empty() {
                continue;
            }
            let removing: BTreeSet<_> = pairs.iter().map(|p| &p.remove.id).collect();
            let retained = input
                .group
                .members
                .iter()
                .filter(|a| !removing.contains(&a.id))
                .cloned()
                .collect();
            plan.groups.push(CleanupGroup {
                signature: input.signature.into(),
                kind: input.group.match_kind(),
                retained,
                pairs,
                delete_all: decision.delete_all,
            });
        }
        let selected: HashSet<_> = plan
            .groups
            .iter()
            .flat_map(|g| g.pairs.iter().map(|p| &p.remove.id))
            .collect();
        let retained: HashSet<_> = all_assets
            .keys()
            .copied()
            .filter(|id| !selected.contains(id))
            .collect();
        let retained_identities: HashSet<_> = all_assets
            .values()
            .filter(|a| retained.contains(&a.id))
            .filter_map(|a| a.native_identity.as_ref())
            .collect();
        let mut removals = HashSet::new();
        let mut identities = HashSet::new();
        for pair in plan.groups.iter().flat_map(|g| &g.pairs) {
            if retained.contains(&pair.remove.id)
                || !removals.insert(&pair.remove.id)
                || pair
                    .remove
                    .native_identity
                    .as_ref()
                    .is_some_and(|id| retained_identities.contains(id) || !identities.insert(id))
            {
                return Err(CoreError::InvalidValue);
            }
        }
        Ok(plan)
    }
    pub fn check_epochs(&self, metadata: &ReviewMetadata) -> Result<(), CleanupReason> {
        if self.epochs != metadata.into() || metadata.scan_scope_epoch != metadata.scope_epoch {
            return Err(CleanupReason::StalePlan);
        }
        Ok(())
    }
    pub fn item_count(&self) -> usize {
        self.groups.iter().map(|g| g.pairs.len()).sum()
    }
    fn resource<'a>(
        &self,
        expected: &ReviewAsset,
        facts: &'a RemovalFacts,
        removing: bool,
        protection: &ProtectionState,
    ) -> Result<&'a ReviewAsset, CleanupReason> {
        let source = self
            .sources
            .get(&expected.id.source_id)
            .ok_or(CleanupReason::UnavailableSource)?;
        if facts.asset.id != expected.id
            || facts.asset.kind != expected.kind
            || facts.asset.revision != expected.revision
            || facts.asset.native_identity != expected.native_identity
        {
            return Err(CleanupReason::ChangedAsset);
        }
        if facts.asset.validate().is_err() {
            return Err(CleanupReason::ChangedAsset);
        }
        if facts.source_namespace != source.native_namespace
            || facts.source_identity != source.native_identity
        {
            return Err(CleanupReason::UnavailableSource);
        }
        if !facts.accessible {
            return Err(CleanupReason::Inaccessible);
        }
        if !facts.in_scan_scope {
            return Err(CleanupReason::ChangedAsset);
        }
        if removing {
            if facts.asset.associated_resources() {
                return Err(CleanupReason::ProtectedResources);
            }
            if facts.inside_read_only_root {
                return Err(CleanupReason::ReadOnlySource);
            }
            if facts.matches_saved_lock {
                return Err(CleanupReason::UserProtected);
            }
            if !protection.lock_owners(&facts.asset).is_empty() {
                return Err(CleanupReason::UserProtected);
            }
            if protection.read_only_source_or_alias(&facts.asset) {
                return Err(CleanupReason::ReadOnlySource);
            }
            if facts.asset.kind == SourceKind::FileSystem && !facts.protection_complete {
                return Err(CleanupReason::UnavailableProtection);
            }
            if protection.protected(&facts.asset) {
                return Err(CleanupReason::UnavailableProtection);
            }
            if !facts.independently_removable {
                return Err(CleanupReason::Inaccessible);
            }
        }
        Ok(&facts.asset)
    }
    /// Validate every whole-group resource before authorizing any member.
    pub fn preflight_whole_group(
        &self,
        group_index: usize,
        facts: &[RemovalFacts],
        metadata: &ReviewMetadata,
        protection: &ProtectionState,
    ) -> Result<(), CleanupReason> {
        self.check_epochs(metadata)?;
        let group = self
            .groups
            .get(group_index)
            .filter(|g| g.delete_all)
            .ok_or(CleanupReason::InvalidSelection)?;
        if facts.len() != group.pairs.len() {
            return Err(CleanupReason::InvalidSelection);
        }
        let by_id: BTreeMap<_, _> = facts.iter().map(|f| (&f.asset.id, f)).collect();
        if by_id.len() != facts.len() {
            return Err(CleanupReason::InvalidSelection);
        }
        for pair in &group.pairs {
            self.resource(
                &pair.remove,
                by_id
                    .get(&pair.remove.id)
                    .ok_or(CleanupReason::InvalidSelection)?,
                true,
                protection,
            )?;
        }
        Ok(())
    }
    pub fn validate_pair(
        &self,
        group_index: usize,
        pair_index: usize,
        facts: &PairFacts,
        metadata: &ReviewMetadata,
        protection: &ProtectionState,
    ) -> Result<(), CleanupReason> {
        self.check_epochs(metadata)?;
        let pair = self
            .groups
            .get(group_index)
            .and_then(|g| g.pairs.get(pair_index))
            .ok_or(CleanupReason::InvalidSelection)?;
        let remove = self.resource(&pair.remove, &facts.remove, true, protection)?;
        match (&pair.keep, &facts.keep) {
            (Some(expected), Some(current)) => {
                let keep = self.resource(expected, current, false, protection)?;
                if keep.id == remove.id
                    || keep
                        .native_identity
                        .as_ref()
                        .is_some_and(|id| Some(id) == remove.native_identity.as_ref())
                {
                    return Err(CleanupReason::SameFile);
                }
                if keep.kind == SourceKind::FileSystem && keep.native_identity.is_none() {
                    return Err(CleanupReason::UnavailableProtection);
                }
                match (&pair.scene, &facts.proof) {
                    (None, ComparisonProof::Pixels { kind }) if *kind != MatchKind::Distinct => {}
                    (
                        Some(expected),
                        ComparisonProof::Scene {
                            provider,
                            first,
                            second,
                            shared_burst,
                            distance,
                        },
                    ) if expected == provider => {
                        if !scene::matches(*first, *second, *shared_burst, *distance)
                            .map_err(|_| CleanupReason::NoLongerDuplicate)?
                        {
                            return Err(CleanupReason::NoLongerDuplicate);
                        }
                    }
                    _ => return Err(CleanupReason::NoLongerDuplicate),
                }
            }
            (None, None) if matches!(facts.proof, ComparisonProof::WholeGroup) => {}
            _ => return Err(CleanupReason::InvalidSelection),
        }
        Ok(())
    }
}

/// Current native facts, gathered again immediately before system recovery-bin
/// operations. No paths or revision string parsing cross this boundary.
#[derive(Clone, Debug)]
pub struct RemovalFacts {
    pub asset: ReviewAsset,
    pub source_namespace: String,
    pub source_identity: Vec<u8>,
    pub accessible: bool,
    pub in_scan_scope: bool,
    pub independently_removable: bool,
    pub inside_read_only_root: bool,
    pub matches_saved_lock: bool,
    pub protection_complete: bool,
}
#[derive(Clone, Debug)]
pub enum ComparisonProof {
    Pixels {
        kind: MatchKind,
    },
    Scene {
        provider: SceneProvider,
        first: SceneQuality,
        second: SceneQuality,
        shared_burst: bool,
        distance: f32,
    },
    WholeGroup,
}
#[derive(Clone, Debug)]
pub struct PairFacts {
    pub keep: Option<RemovalFacts>,
    pub remove: RemovalFacts,
    pub proof: ComparisonProof,
}
