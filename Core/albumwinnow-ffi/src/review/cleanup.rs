use super::*;
use albumwinnow_core::cleanup::{self, run};

#[derive(uniffi::Enum)]
pub enum CoreCleanupReason {
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
impl From<CoreCleanupReason> for cleanup::CleanupReason {
    fn from(v: CoreCleanupReason) -> Self {
        match v {
            CoreCleanupReason::StalePlan => Self::StalePlan,
            CoreCleanupReason::InvalidSelection => Self::InvalidSelection,
            CoreCleanupReason::UnavailableSource => Self::UnavailableSource,
            CoreCleanupReason::UnavailableProtection => Self::UnavailableProtection,
            CoreCleanupReason::ChangedAsset => Self::ChangedAsset,
            CoreCleanupReason::ProtectedResources => Self::ProtectedResources,
            CoreCleanupReason::UserProtected => Self::UserProtected,
            CoreCleanupReason::ReadOnlySource => Self::ReadOnlySource,
            CoreCleanupReason::SameFile => Self::SameFile,
            CoreCleanupReason::NoLongerDuplicate => Self::NoLongerDuplicate,
            CoreCleanupReason::Inaccessible => Self::Inaccessible,
            CoreCleanupReason::Cancelled => Self::Cancelled,
            CoreCleanupReason::OperationInProgress => Self::OperationInProgress,
        }
    }
}
impl From<cleanup::CleanupReason> for CoreCleanupReason {
    fn from(v: cleanup::CleanupReason) -> Self {
        match v {
            cleanup::CleanupReason::StalePlan => Self::StalePlan,
            cleanup::CleanupReason::InvalidSelection => Self::InvalidSelection,
            cleanup::CleanupReason::UnavailableSource => Self::UnavailableSource,
            cleanup::CleanupReason::UnavailableProtection => Self::UnavailableProtection,
            cleanup::CleanupReason::ChangedAsset => Self::ChangedAsset,
            cleanup::CleanupReason::ProtectedResources => Self::ProtectedResources,
            cleanup::CleanupReason::UserProtected => Self::UserProtected,
            cleanup::CleanupReason::ReadOnlySource => Self::ReadOnlySource,
            cleanup::CleanupReason::SameFile => Self::SameFile,
            cleanup::CleanupReason::NoLongerDuplicate => Self::NoLongerDuplicate,
            cleanup::CleanupReason::Inaccessible => Self::Inaccessible,
            cleanup::CleanupReason::Cancelled => Self::Cancelled,
            cleanup::CleanupReason::OperationInProgress => Self::OperationInProgress,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreCleanupKey {
    pub group: u64,
    pub pair: u64,
}
impl TryFrom<CoreCleanupKey> for run::CleanupItemKey {
    type Error = BridgeError;
    fn try_from(v: CoreCleanupKey) -> Result<Self, BridgeError> {
        Ok(Self {
            group: usize::try_from(v.group).map_err(|_| BridgeError::InvalidValue)?,
            pair: usize::try_from(v.pair).map_err(|_| BridgeError::InvalidValue)?,
        })
    }
}
impl From<run::CleanupItemKey> for CoreCleanupKey {
    fn from(v: run::CleanupItemKey) -> Self {
        Self {
            group: v.group as u64,
            pair: v.pair as u64,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreCleanupTicket {
    pub operation: String,
    pub nonce: u64,
    pub items: Vec<CoreCleanupKey>,
}
impl TryFrom<CoreCleanupTicket> for run::CleanupTicket {
    type Error = BridgeError;
    fn try_from(v: CoreCleanupTicket) -> Result<Self, BridgeError> {
        if v.items.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        Ok(Self {
            operation: v.operation,
            nonce: v.nonce,
            items: v
                .items
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_, _>>()?,
        })
    }
}
impl From<run::CleanupTicket> for CoreCleanupTicket {
    fn from(v: run::CleanupTicket) -> Self {
        Self {
            operation: v.operation,
            nonce: v.nonce,
            items: v.items.into_iter().map(Into::into).collect(),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreRemovalFacts {
    pub asset: CoreReviewAsset,
    pub source_namespace: String,
    pub source_identity: Vec<u8>,
    pub accessible: bool,
    pub in_scan_scope: bool,
    pub independently_removable: bool,
    pub inside_read_only_root: bool,
    pub matches_saved_lock: bool,
    pub protection_complete: bool,
}
impl From<CoreRemovalFacts> for cleanup::RemovalFacts {
    fn from(v: CoreRemovalFacts) -> Self {
        Self {
            asset: v.asset.into(),
            source_namespace: v.source_namespace,
            source_identity: v.source_identity,
            accessible: v.accessible,
            in_scan_scope: v.in_scan_scope,
            independently_removable: v.independently_removable,
            inside_read_only_root: v.inside_read_only_root,
            matches_saved_lock: v.matches_saved_lock,
            protection_complete: v.protection_complete,
        }
    }
}
#[derive(uniffi::Enum)]
pub enum CoreComparisonProof {
    Pixels {
        kind: CoreMatch,
    },
    Scene {
        provider: CoreSceneProvider,
        first: CoreSceneQuality,
        second: CoreSceneQuality,
        shared_burst: bool,
        distance: f32,
    },
    WholeGroup,
}
impl From<CoreComparisonProof> for cleanup::ComparisonProof {
    fn from(v: CoreComparisonProof) -> Self {
        match v {
            CoreComparisonProof::Pixels { kind } => Self::Pixels { kind: kind.into() },
            CoreComparisonProof::Scene {
                provider,
                first,
                second,
                shared_burst,
                distance,
            } => Self::Scene {
                provider: provider.into(),
                first: first.into(),
                second: second.into(),
                shared_burst,
                distance,
            },
            CoreComparisonProof::WholeGroup => Self::WholeGroup,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CorePairFacts {
    pub keep: Option<CoreRemovalFacts>,
    pub remove: CoreRemovalFacts,
    pub proof: CoreComparisonProof,
}
impl From<CorePairFacts> for cleanup::PairFacts {
    fn from(v: CorePairFacts) -> Self {
        Self {
            keep: v.keep.map(Into::into),
            remove: v.remove.into(),
            proof: v.proof.into(),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreCleanupValidation {
    pub key: CoreCleanupKey,
    pub facts: CorePairFacts,
}
#[derive(uniffi::Record)]
pub struct CoreCleanupPair {
    pub group_signature: String,
    pub keep: Option<CoreReviewAsset>,
    pub remove: CoreReviewAsset,
    pub scene: Option<CoreSceneProvider>,
}
impl From<cleanup::CleanupPair> for CoreCleanupPair {
    fn from(v: cleanup::CleanupPair) -> Self {
        Self {
            group_signature: v.group_signature,
            keep: v.keep.map(Into::into),
            remove: v.remove.into(),
            scene: v.scene.map(Into::into),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreCleanupItem {
    pub key: CoreCleanupKey,
    pub pair: CoreCleanupPair,
}
#[derive(uniffi::Enum)]
pub enum CoreCleanupOutcome {
    MovedToTrash,
    MovedToRecentlyDeleted,
    Skipped { reason: CoreCleanupReason },
    Failed,
}
impl From<CoreCleanupOutcome> for run::CleanupOutcome {
    fn from(v: CoreCleanupOutcome) -> Self {
        match v {
            CoreCleanupOutcome::MovedToTrash => Self::MovedToTrash,
            CoreCleanupOutcome::MovedToRecentlyDeleted => Self::MovedToRecentlyDeleted,
            CoreCleanupOutcome::Skipped { reason } => Self::Skipped(reason.into()),
            CoreCleanupOutcome::Failed => Self::Failed,
        }
    }
}
impl From<run::CleanupOutcome> for CoreCleanupOutcome {
    fn from(v: run::CleanupOutcome) -> Self {
        match v {
            run::CleanupOutcome::MovedToTrash => Self::MovedToTrash,
            run::CleanupOutcome::MovedToRecentlyDeleted => Self::MovedToRecentlyDeleted,
            run::CleanupOutcome::Skipped(reason) => Self::Skipped {
                reason: reason.into(),
            },
            run::CleanupOutcome::Failed => Self::Failed,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreCleanupResult {
    pub item: CoreCleanupItem,
    pub outcome: CoreCleanupOutcome,
}
impl From<run::CleanupItemResult> for CoreCleanupResult {
    fn from(v: run::CleanupItemResult) -> Self {
        Self {
            item: CoreCleanupItem {
                key: v.key.into(),
                pair: v.pair.into(),
            },
            outcome: v.outcome.into(),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreCleanupAuthorization {
    pub ticket: Option<CoreCleanupTicket>,
    pub rejection: Option<CoreCleanupReason>,
}
#[derive(uniffi::Record)]
pub struct CoreCleanupReport {
    pub recorded: bool,
    pub rejection: Option<CoreCleanupReason>,
}
#[derive(uniffi::Record)]
pub struct CoreCleanupHeader {
    pub operation: String,
    pub scan_generation: u64,
    pub scope_epoch: u64,
    pub protection_epoch: u64,
    pub decision_epoch: u64,
    pub group_count: u64,
    pub item_count: u64,
    pub completed_count: u64,
    pub cancelled: bool,
    pub executing: bool,
}
#[derive(uniffi::Record)]
pub struct CoreCleanupGroupSummary {
    pub index: u64,
    pub signature: String,
    pub kind: CoreMatch,
    pub retained_count: u64,
    pub removal_count: u64,
    pub delete_all: bool,
}
fn index(value: u64) -> Result<usize, BridgeError> {
    usize::try_from(value).map_err(|_| BridgeError::InvalidValue)
}
fn header(session: &ReviewSession, operation: &str) -> Result<CoreCleanupHeader, CoreError> {
    let plan = session
        .cleanup_plan()
        .filter(|p| p.operation == operation)
        .ok_or(CoreError::StaleOperation)?;
    let (completed, cancelled, executing) = session
        .cleanup_progress(operation)
        .ok_or(CoreError::StaleOperation)?;
    Ok(CoreCleanupHeader {
        operation: operation.into(),
        scan_generation: plan.epochs.scan_generation,
        scope_epoch: plan.epochs.scope,
        protection_epoch: plan.epochs.protection,
        decision_epoch: plan.epochs.decision,
        group_count: plan.groups.len() as u64,
        item_count: plan.item_count() as u64,
        completed_count: completed as u64,
        cancelled,
        executing,
    })
}
#[uniffi::export]
impl RustReviewSession {
    pub fn start_cleanup(&self, expected_revision: u64) -> Result<CoreCleanupHeader, BridgeError> {
        self.access(|s| {
            let operation = s.start_cleanup(expected_revision)?;
            header(s, &operation)
        })
    }
    pub fn cleanup_header(&self, operation: String) -> Result<CoreCleanupHeader, BridgeError> {
        self.access(|s| header(s, &operation))
    }
    pub fn cleanup_groups_page(
        &self,
        operation: String,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreCleanupGroupSummary>, BridgeError> {
        if limit > 256 {
            return Err(BridgeError::InvalidBuffer);
        }
        let offset = index(offset)?;
        self.access(|s| {
            let plan = s
                .cleanup_plan()
                .filter(|p| p.operation == operation)
                .ok_or(CoreError::StaleOperation)?;
            Ok(plan
                .groups
                .iter()
                .enumerate()
                .skip(offset)
                .take(limit as usize)
                .map(|(i, g)| CoreCleanupGroupSummary {
                    index: i as u64,
                    signature: g.signature.clone(),
                    kind: g.kind.into(),
                    retained_count: g.retained.len() as u64,
                    removal_count: g.pairs.len() as u64,
                    delete_all: g.delete_all,
                })
                .collect())
        })
    }
    pub fn cleanup_items_page(
        &self,
        operation: String,
        group: u64,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreCleanupItem>, BridgeError> {
        if limit > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        let group = index(group)?;
        let offset = index(offset)?;
        self.access(|s| {
            let plan = s
                .cleanup_plan()
                .filter(|p| p.operation == operation)
                .ok_or(CoreError::StaleOperation)?;
            let selected = plan.groups.get(group).ok_or(CoreError::InvalidValue)?;
            Ok(selected
                .pairs
                .iter()
                .enumerate()
                .skip(offset)
                .take(limit as usize)
                .map(|(i, p)| CoreCleanupItem {
                    key: CoreCleanupKey {
                        group: group as u64,
                        pair: i as u64,
                    },
                    pair: p.clone().into(),
                })
                .collect())
        })
    }
    pub fn begin_cleanup_preflight(
        &self,
        operation: String,
        group: u64,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let group = index(group)?;
        self.access(|s| {
            Ok(s.begin_cleanup_preflight(&operation, group)
                .err()
                .map(Into::into))
        })
    }
    pub fn append_cleanup_preflight(
        &self,
        operation: String,
        group: u64,
        facts: Vec<CoreRemovalFacts>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        cancellation.cancellation.check()?;
        if facts.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        let group = index(group)?;
        let facts: Vec<_> = facts.into_iter().map(Into::into).collect();
        self.access(|s| {
            cancellation.cancellation.check()?;
            Ok(s.append_cleanup_preflight(&operation, group, &facts)
                .err()
                .map(Into::into))
        })
    }
    pub fn finish_cleanup_preflight(
        &self,
        operation: String,
        group: u64,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let group = index(group)?;
        self.access(|s| {
            Ok(s.finish_cleanup_preflight(&operation, group)
                .err()
                .map(Into::into))
        })
    }
    pub fn authorize_cleanup(
        &self,
        operation: String,
        items: Vec<CoreCleanupValidation>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<CoreCleanupAuthorization, BridgeError> {
        cancellation.cancellation.check()?;
        if items.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        let items = items
            .into_iter()
            .map(|i| Ok((i.key.try_into()?, i.facts.into())))
            .collect::<Result<Vec<_>, BridgeError>>()?;
        self.access(|s| {
            cancellation.cancellation.check()?;
            Ok(match s.authorize_cleanup(&operation, &items) {
                Ok(ticket) => CoreCleanupAuthorization {
                    ticket: Some(ticket.into()),
                    rejection: None,
                },
                Err(reason) => CoreCleanupAuthorization {
                    ticket: None,
                    rejection: Some(reason.into()),
                },
            })
        })
    }
    pub fn validate_cleanup_ticket(
        &self,
        ticket: CoreCleanupTicket,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let ticket = ticket.try_into()?;
        self.access(|s| Ok(s.validate_cleanup_ticket(&ticket).err().map(Into::into)))
    }
    pub fn report_cleanup(
        &self,
        ticket: CoreCleanupTicket,
        outcomes: Vec<CoreCleanupOutcome>,
    ) -> Result<CoreCleanupReport, BridgeError> {
        if outcomes.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        let ticket = ticket.try_into()?;
        let outcomes = outcomes.into_iter().map(Into::into).collect();
        let mut session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(match session.report_cleanup(&ticket, outcomes) {
            Ok(recorded) => CoreCleanupReport {
                recorded,
                rejection: None,
            },
            Err(reason) => CoreCleanupReport {
                recorded: false,
                rejection: Some(reason.into()),
            },
        })
    }
    pub fn skip_cleanup_item(
        &self,
        operation: String,
        key: CoreCleanupKey,
        reason: CoreCleanupReason,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let key = key.try_into()?;
        let mut session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(session
            .skip_cleanup_item(&operation, key, reason.into())
            .err()
            .map(Into::into))
    }
    pub fn cancel_cleanup(
        &self,
        operation: String,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let mut session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(session.cancel_cleanup(&operation).err().map(Into::into))
    }
    pub fn fail_cleanup_item(
        &self,
        operation: String,
        key: CoreCleanupKey,
    ) -> Result<Option<CoreCleanupReason>, BridgeError> {
        let key = key.try_into()?;
        let mut session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(session
            .fail_cleanup_item(&operation, key)
            .err()
            .map(Into::into))
    }
    pub fn finish_cleanup(&self, operation: String) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.finish_cleanup(&operation)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn cleanup_results_page(
        &self,
        operation: String,
        completed: bool,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreCleanupResult>, BridgeError> {
        if limit > 256 {
            return Err(BridgeError::InvalidBuffer);
        }
        let offset = index(offset)?;
        let session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        if completed {
            if session.last_cleanup_operation() != Some(operation.as_str()) {
                return Err(BridgeError::StaleOperation);
            }
            Ok(session
                .last_cleanup_results()
                .iter()
                .skip(offset)
                .take(limit as usize)
                .map(|r| CoreCleanupResult {
                    item: CoreCleanupItem {
                        key: r.key.into(),
                        pair: r.pair.clone().into(),
                    },
                    outcome: r.outcome.into(),
                })
                .collect())
        } else {
            Ok(session
                .current_cleanup_results(&operation, offset, limit as usize)
                .map_err(|_| BridgeError::StaleOperation)?
                .into_iter()
                .map(Into::into)
                .collect())
        }
    }
}
