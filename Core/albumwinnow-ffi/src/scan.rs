use crate::{
    BridgeError, CancellationHandle,
    matching::{CoreFingerprint, CoreMatch},
};
use albumwinnow_core::{Cancellation, CoreError, scan};
use std::sync::{Arc, Mutex};

#[derive(Clone, uniffi::Record)]
pub struct CoreAssetKey {
    pub source_id: String,
    pub item_id: String,
}
impl From<CoreAssetKey> for albumwinnow_core::model::AssetId {
    fn from(value: CoreAssetKey) -> Self {
        Self {
            source_id: value.source_id,
            item_id: value.item_id,
        }
    }
}
impl From<albumwinnow_core::model::AssetId> for CoreAssetKey {
    fn from(value: albumwinnow_core::model::AssetId) -> Self {
        Self {
            source_id: value.source_id,
            item_id: value.item_id,
        }
    }
}

#[derive(Clone, uniffi::Record)]
pub struct ScanItemInput {
    pub asset: CoreAssetKey,
    pub revision: String,
    pub fingerprint: CoreFingerprint,
    pub associated_resources: bool,
    pub native_identity: Option<String>,
}
impl TryFrom<ScanItemInput> for scan::ScanItem {
    type Error = BridgeError;
    fn try_from(value: ScanItemInput) -> Result<Self, Self::Error> {
        let result = Self {
            id: value.asset.into(),
            revision: value.revision,
            fingerprint: value.fingerprint.try_into()?,
            associated_resources: value.associated_resources,
            native_identity: value.native_identity,
        };
        result.validate()?;
        Ok(result)
    }
}

#[derive(uniffi::Record)]
pub struct CoreComparisonSides {
    pub first: String,
    pub second: String,
}

#[derive(uniffi::Record)]
pub struct CorePairTask {
    pub task_id: u64,
    pub first: CoreAssetKey,
    pub second: CoreAssetKey,
    pub first_revision: String,
    pub second_revision: String,
    pub exact_identity: bool,
}

#[derive(uniffi::Record)]
pub struct CoreScanBatch {
    pub batch_id: u64,
    pub tasks: Vec<CorePairTask>,
    pub completed: u64,
    pub total: u64,
    pub done: bool,
}

#[derive(uniffi::Enum)]
pub enum CoreVerification {
    Matched { kind: CoreMatch },
    Failed { asset: CoreAssetKey },
}

#[derive(uniffi::Record)]
pub struct CoreTaskResult {
    pub task_id: u64,
    pub outcome: CoreVerification,
}

#[derive(uniffi::Record)]
pub struct CoreAssetValidation {
    pub asset: CoreAssetKey,
    pub revision: Option<String>,
    pub accessible: bool,
}
impl From<CoreAssetValidation> for scan::AssetValidation {
    fn from(v: CoreAssetValidation) -> Self {
        Self {
            id: v.asset.into(),
            revision: v.revision,
            accessible: v.accessible,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreScanMember {
    pub asset: CoreAssetKey,
    pub kind: CoreMatch,
}

#[derive(uniffi::Record)]
pub struct CoreMatchEdge {
    pub first: CoreAssetKey,
    pub second: CoreAssetKey,
    pub kind: CoreMatch,
}

#[derive(uniffi::Record)]
pub struct CoreScanGroup {
    pub preferred: CoreAssetKey,
    pub duplicates: Vec<CoreScanMember>,
    pub edges: Option<Vec<CoreMatchEdge>>,
    pub recommended: Option<CoreAssetKey>,
}

#[derive(uniffi::Object)]
pub struct RustScanSession {
    state: Mutex<scan::ScanSession>,
    pub(crate) cancellation: Arc<CancellationHandle>,
}

impl RustScanSession {
    // Cross-session handoff locks detection -> scene -> review, never the reverse.
    pub(crate) fn with_core<T>(
        &self,
        operation: impl FnOnce(&scan::ScanSession) -> Result<T, BridgeError>,
    ) -> Result<T, BridgeError> {
        self.cancellation.cancellation.check()?;
        let state = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        operation(&state)
    }
    fn access<T>(
        &self,
        operation: impl FnOnce(&mut scan::ScanSession, &Cancellation) -> Result<T, CoreError>,
    ) -> Result<T, BridgeError> {
        self.cancellation.cancellation.check()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(operation(&mut state, &self.cancellation.cancellation)?)
    }
}

#[uniffi::export]
impl RustScanSession {
    #[uniffi::constructor]
    pub fn new(
        operation_id: String,
        source_ids: Vec<String>,
        sides: Option<CoreComparisonSides>,
        preferred_source: Option<String>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<Arc<Self>, BridgeError> {
        cancellation.cancellation.check()?;
        let sides = sides.map(|value| scan::ComparisonSides {
            first: value.first,
            second: value.second,
        });
        let state = scan::ScanSession::new(operation_id, source_ids, sides, preferred_source)?;
        Ok(Arc::new(Self {
            state: Mutex::new(state),
            cancellation,
        }))
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub fn append_prepared(&self, items: Vec<ScanItemInput>) -> Result<(), BridgeError> {
        if items.len() > scan::MAX_BATCH_SIZE {
            return Err(BridgeError::InvalidValue);
        }
        let items: Result<Vec<_>, _> = items.into_iter().map(TryInto::try_into).collect();
        let items = items?;
        self.access(|state, cancel| state.append_prepared(items, cancel))
    }

    pub fn complete_preparation(&self) -> Result<(), BridgeError> {
        self.access(|state, cancel| state.complete_preparation(cancel))
    }

    pub fn next_batch(&self, maximum: u32) -> Result<CoreScanBatch, BridgeError> {
        let batch = self.access(|state, cancel| state.next_batch(maximum as usize, cancel))?;
        Ok(CoreScanBatch {
            batch_id: batch.batch_id,
            completed: batch.completed as u64,
            total: batch.total as u64,
            done: batch.done,
            tasks: batch
                .tasks
                .into_iter()
                .map(|task| CorePairTask {
                    task_id: task.task_id,
                    first: task.first.into(),
                    second: task.second.into(),
                    first_revision: task.first_revision,
                    second_revision: task.second_revision,
                    exact_identity: task.exact_identity,
                })
                .collect(),
        })
    }

    pub fn submit_results(
        &self,
        operation_id: String,
        batch_id: u64,
        results: Vec<CoreTaskResult>,
    ) -> Result<(), BridgeError> {
        if results.len() > scan::MAX_BATCH_SIZE {
            return Err(BridgeError::InvalidValue);
        }
        let results = results
            .into_iter()
            .map(|result| scan::TaskResult {
                task_id: result.task_id,
                outcome: match result.outcome {
                    CoreVerification::Matched { kind } => {
                        scan::VerificationOutcome::Matched(kind.into())
                    }
                    CoreVerification::Failed { asset } => {
                        scan::VerificationOutcome::Failed(asset.into())
                    }
                },
            })
            .collect();
        self.access(|state, cancel| state.submit_results(&operation_id, batch_id, results, cancel))
    }

    pub fn final_validation_ids(&self) -> Result<Vec<CoreAssetKey>, BridgeError> {
        Ok(self
            .access(|state, cancel| state.final_validation_ids(cancel))?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn final_validation_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreAssetKey>, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        Ok(self
            .access(|s, c| s.final_validation_page(offset, limit as usize, c))?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn scene_candidate_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreAssetKey>, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        Ok(self
            .access(|s, c| s.scene_candidate_page(offset, limit as usize, c))?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn submit_final_validations(
        &self,
        operation_id: String,
        validations: Vec<CoreAssetValidation>,
    ) -> Result<(), BridgeError> {
        if validations.len() > scan::MAX_BATCH_SIZE {
            return Err(BridgeError::InvalidValue);
        }
        let validations = validations.into_iter().map(Into::into).collect();
        self.access(|state, cancel| {
            state.submit_final_validations(&operation_id, validations, cancel)
        })
    }

    pub fn groups(&self) -> Result<Vec<CoreScanGroup>, BridgeError> {
        Ok(self
            .access(|state, cancel| state.groups(cancel))?
            .into_iter()
            .map(|group| CoreScanGroup {
                preferred: group.preferred.into(),
                duplicates: group
                    .duplicates
                    .into_iter()
                    .map(|(asset, kind)| CoreScanMember {
                        asset: asset.into(),
                        kind: kind.into(),
                    })
                    .collect(),
                edges: group.edges.map(|edges| {
                    edges
                        .into_iter()
                        .map(|edge| CoreMatchEdge {
                            first: edge.first.into(),
                            second: edge.second.into(),
                            kind: edge.kind.into(),
                        })
                        .collect()
                }),
                recommended: group.recommended.map(Into::into),
            })
            .collect())
    }
}
