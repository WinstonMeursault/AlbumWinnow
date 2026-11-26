use super::*;
use crate::{scan::RustScanSession, scene::RustSceneSession};

#[derive(uniffi::Record)]
pub struct CoreScanReviewAsset {
    pub asset: CoreReviewAsset,
    pub evidence: CoreReviewEvidence,
}
impl From<CoreScanReviewAsset> for albumwinnow_core::review_scan::ScanReviewAsset {
    fn from(v: CoreScanReviewAsset) -> Self {
        Self {
            asset: v.asset.into(),
            evidence: v.evidence.into(),
        }
    }
}

#[uniffi::export]
impl RustReviewSession {
    pub fn append_scan_assets(
        &self,
        operation_id: String,
        assets: Vec<CoreScanReviewAsset>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<(), BridgeError> {
        cancellation.cancellation.check()?;
        if assets.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        self.access(|s| {
            s.append_scan_assets(
                &operation_id,
                assets.into_iter().map(Into::into).collect(),
                &cancellation.cancellation,
            )
        })
    }

    pub fn finish_detected_scan(
        &self,
        operation_id: String,
        detection: Arc<RustScanSession>,
        scenes: Option<Arc<RustSceneSession>>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        cancellation.cancellation.check()?;
        if !Arc::ptr_eq(&detection.cancellation, &cancellation)
            || scenes
                .as_ref()
                .is_some_and(|s| !Arc::ptr_eq(&s.cancellation, &cancellation))
        {
            return Err(BridgeError::InvalidValue);
        }
        let finish = |scan: &scan::ScanSession, scene: Option<&scene_session::SceneSession>| {
            self.access(|s| {
                s.finish_detected_scan(&operation_id, scan, scene, &cancellation.cancellation)?;
                Ok(s.metadata().clone().into())
            })
        };
        detection.with_core(|scan| match scenes {
            Some(scenes) => scenes.with_core(|scene| finish(scan, Some(scene))),
            None => finish(scan, None),
        })
    }
}
