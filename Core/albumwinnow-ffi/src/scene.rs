use crate::{BridgeError, CancellationHandle, PixelInput};

#[derive(Clone, Copy, uniffi::Record)]
pub struct CoreSceneQuality {
    pub mean_luminance: f64,
    pub texture_variance: f64,
    pub focus_energy: f64,
    pub dark_clipping: f64,
    pub bright_clipping: f64,
}
impl From<albumwinnow_core::scene::SceneQuality> for CoreSceneQuality {
    fn from(v: albumwinnow_core::scene::SceneQuality) -> Self {
        Self {
            mean_luminance: v.mean_luminance,
            texture_variance: v.texture_variance,
            focus_energy: v.focus_energy,
            dark_clipping: v.dark_clipping,
            bright_clipping: v.bright_clipping,
        }
    }
}
impl From<CoreSceneQuality> for albumwinnow_core::scene::SceneQuality {
    fn from(v: CoreSceneQuality) -> Self {
        Self {
            mean_luminance: v.mean_luminance,
            texture_variance: v.texture_variance,
            focus_energy: v.focus_energy,
            dark_clipping: v.dark_clipping,
            bright_clipping: v.bright_clipping,
        }
    }
}
#[uniffi::export]
impl CancellationHandle {
    pub fn scene_quality(&self, pixels: PixelInput) -> Result<CoreSceneQuality, BridgeError> {
        Ok(albumwinnow_core::scene::quality(&pixels.into(), &self.cancellation)?.into())
    }
    pub fn scene_keys(&self, vector: Vec<f32>) -> Result<Vec<u16>, BridgeError> {
        Ok(albumwinnow_core::scene::keys(&vector, &self.cancellation)?.to_vec())
    }
}
#[uniffi::export]
pub fn core_scene_matches(
    first: CoreSceneQuality,
    second: CoreSceneQuality,
    shared_burst: bool,
    distance: f32,
) -> Result<bool, BridgeError> {
    Ok(albumwinnow_core::scene::matches(
        first.into(),
        second.into(),
        shared_burst,
        distance,
    )?)
}

use crate::scan::{CoreAssetKey, CoreComparisonSides};
use albumwinnow_core::{CoreError, model::SceneProvider, scene_session};
use std::sync::{Arc, Mutex};

#[derive(Clone, uniffi::Record)]
pub struct CoreSceneProvider {
    pub provider_id: String,
    pub model_revision: String,
    pub preprocessing: String,
    pub platform_compatibility: String,
}
impl From<CoreSceneProvider> for SceneProvider {
    fn from(v: CoreSceneProvider) -> Self {
        Self {
            provider_id: v.provider_id,
            model_revision: v.model_revision,
            preprocessing: v.preprocessing,
            platform_compatibility: v.platform_compatibility,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreSceneAsset {
    pub asset: CoreAssetKey,
    pub revision: String,
    pub provider: CoreSceneProvider,
    pub quality: CoreSceneQuality,
    pub keys: Vec<u16>,
    pub width: u32,
    pub height: u32,
    pub bit_depth: u16,
    pub wide_color: bool,
    pub edge_detail: f64,
    pub associated_resources: bool,
    pub native_identity: Option<String>,
    pub burst: Option<String>,
    pub date: Option<f64>,
}
impl TryFrom<CoreSceneAsset> for scene_session::SceneAsset {
    type Error = BridgeError;
    fn try_from(v: CoreSceneAsset) -> Result<Self, Self::Error> {
        Ok(Self {
            id: v.asset.into(),
            revision: v.revision,
            provider: v.provider.into(),
            quality: v.quality.into(),
            keys: v.keys.try_into().map_err(|_| BridgeError::InvalidValue)?,
            width: v.width,
            height: v.height,
            bit_depth: v.bit_depth,
            wide_color: v.wide_color,
            edge_detail: v.edge_detail,
            associated_resources: v.associated_resources,
            native_identity: v.native_identity,
            burst: v.burst,
            date: v.date,
        })
    }
}
#[derive(uniffi::Record)]
pub struct CoreSceneRequest {
    pub task_id: u64,
    pub first: CoreAssetKey,
    pub first_revision: String,
    pub second: CoreAssetKey,
    pub second_revision: String,
}
#[derive(uniffi::Record)]
pub struct CoreSceneWork {
    pub request: Option<CoreSceneRequest>,
    pub completed: u64,
    pub total: u64,
}
#[derive(uniffi::Record)]
pub struct CoreSceneEdge {
    pub first: CoreAssetKey,
    pub second: CoreAssetKey,
    pub distance: f32,
    pub shared_burst: bool,
}
#[derive(uniffi::Enum)]
pub enum CoreSceneRecommendation {
    AssociatedResources,
    FocusSignal,
    ExposureSignal,
    SourcePreference,
}
#[derive(uniffi::Record)]
pub struct CoreSceneGroup {
    pub members: Vec<CoreAssetKey>,
    pub edges: Vec<CoreSceneEdge>,
    pub recommended: Option<CoreAssetKey>,
    pub reason: Option<CoreSceneRecommendation>,
}
#[derive(uniffi::Object)]
pub struct RustSceneSession {
    state: Mutex<scene_session::SceneSession>,
    pub(crate) cancellation: Arc<CancellationHandle>,
}
impl RustSceneSession {
    pub(crate) fn with_core<T>(
        &self,
        operation: impl FnOnce(&scene_session::SceneSession) -> Result<T, BridgeError>,
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
        op: impl FnOnce(&mut scene_session::SceneSession) -> Result<T, CoreError>,
    ) -> Result<T, BridgeError> {
        self.cancellation.cancellation.check()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(op(&mut state)?)
    }
}
#[uniffi::export]
impl RustSceneSession {
    #[uniffi::constructor]
    pub fn new(
        operation_id: String,
        provider: CoreSceneProvider,
        sides: Option<CoreComparisonSides>,
        preferred_source: Option<String>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<Arc<Self>, BridgeError> {
        let state = scene_session::SceneSession::new(
            operation_id,
            provider.into(),
            sides.map(|v| (v.first, v.second)),
            preferred_source,
            cancellation.cancellation.clone(),
        )?;
        Ok(Arc::new(Self {
            state: Mutex::new(state),
            cancellation,
        }))
    }
    pub fn cancel(&self) {
        self.cancellation.cancel();
    }
    pub fn final_validation_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreAssetKey>, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        Ok(self
            .access(|s| s.final_validation_page(offset, limit as usize))?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn submit_final_validations(
        &self,
        operation_id: String,
        validations: Vec<crate::scan::CoreAssetValidation>,
    ) -> Result<(), BridgeError> {
        if validations.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        self.access(|s| {
            s.submit_final_validations(
                &operation_id,
                validations.into_iter().map(Into::into).collect(),
            )
        })
    }
    pub fn append_prepared(&self, items: Vec<CoreSceneAsset>) -> Result<(), BridgeError> {
        if items.len() > 16 {
            return Err(BridgeError::InvalidValue);
        }
        let items = items
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<_>, _>>()?;
        self.access(|s| s.append(items))
    }
    pub fn complete_preparation(&self) -> Result<(), BridgeError> {
        self.access(|s| s.complete_preparation())
    }
    pub fn next_work(&self) -> Result<CoreSceneWork, BridgeError> {
        let work = self.access(|s| s.next_work())?;
        Ok(CoreSceneWork {
            completed: work.completed as u64,
            total: work.total as u64,
            request: work.request.map(|r| CoreSceneRequest {
                task_id: r.task_id,
                first: r.first.into(),
                second: r.second.into(),
                first_revision: r.first_revision,
                second_revision: r.second_revision,
            }),
        })
    }
    pub fn submit_distance(
        &self,
        operation_id: String,
        task_id: u64,
        distance: f32,
    ) -> Result<(), BridgeError> {
        self.access(|s| s.submit(&operation_id, task_id, distance))
    }
    pub fn groups(&self) -> Result<Vec<CoreSceneGroup>, BridgeError> {
        Ok(self
            .access(|s| s.groups())?
            .into_iter()
            .map(|g| CoreSceneGroup {
                members: g.members.into_iter().map(Into::into).collect(),
                edges: g
                    .edges
                    .into_iter()
                    .map(|e| CoreSceneEdge {
                        first: e.first.into(),
                        second: e.second.into(),
                        distance: e.distance,
                        shared_burst: e.shared_burst,
                    })
                    .collect(),
                recommended: g.recommended.map(Into::into),
                reason: g.reason.map(|r| match r {
                    scene_session::Recommendation::AssociatedResources => {
                        CoreSceneRecommendation::AssociatedResources
                    }
                    scene_session::Recommendation::FocusSignal => {
                        CoreSceneRecommendation::FocusSignal
                    }
                    scene_session::Recommendation::ExposureSignal => {
                        CoreSceneRecommendation::ExposureSignal
                    }
                    scene_session::Recommendation::SourcePreference => {
                        CoreSceneRecommendation::SourcePreference
                    }
                }),
            })
            .collect())
    }
}

#[derive(uniffi::Object, Default)]
pub struct RustSceneIndex {
    state: Mutex<scene_session::SceneIndex>,
}
#[uniffi::export]
impl RustSceneIndex {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn candidates(
        &self,
        keys: Vec<u16>,
        burst: Option<String>,
        date: Option<f64>,
    ) -> Result<Vec<u64>, BridgeError> {
        let keys = keys.try_into().map_err(|_| BridgeError::InvalidValue)?;
        let state = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(state
            .candidates(keys, burst.as_deref(), date)?
            .into_iter()
            .map(|i| i as u64)
            .collect())
    }
    pub fn insert(
        &self,
        keys: Vec<u16>,
        burst: Option<String>,
        date: Option<f64>,
        index: u64,
    ) -> Result<(), BridgeError> {
        let keys = keys.try_into().map_err(|_| BridgeError::InvalidValue)?;
        let index = usize::try_from(index).map_err(|_| BridgeError::InvalidValue)?;
        Ok(self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?
            .insert(keys, burst.as_deref(), date, index)?)
    }
}
