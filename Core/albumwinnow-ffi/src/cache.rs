use crate::{
    BridgeError, CancellationHandle,
    matching::CoreFingerprint,
    scan::CoreAssetKey,
    scene::{CoreSceneProvider, CoreSceneQuality},
};
use albumwinnow_core::{
    CoreError,
    cache::{CacheStore, CachedFingerprint, CachedScene, PreparedCacheEntry},
};
use std::{
    collections::HashSet,
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(uniffi::Record)]
pub struct CoreCachedFingerprint {
    pub asset: CoreAssetKey,
    pub revision: String,
    pub fingerprint: CoreFingerprint,
    pub observed_bit_depth: Option<u16>,
    pub capture_date: Option<f64>,
}
impl TryFrom<CoreCachedFingerprint> for CachedFingerprint {
    type Error = BridgeError;
    fn try_from(v: CoreCachedFingerprint) -> Result<Self, Self::Error> {
        Ok(Self {
            id: v.asset.into(),
            revision: v.revision,
            fingerprint: v.fingerprint.try_into()?,
            observed_bit_depth: v.observed_bit_depth,
            capture_date: v.capture_date,
        })
    }
}
impl From<CachedFingerprint> for CoreCachedFingerprint {
    fn from(v: CachedFingerprint) -> Self {
        Self {
            asset: v.id.into(),
            revision: v.revision,
            fingerprint: v.fingerprint.into(),
            observed_bit_depth: v.observed_bit_depth,
            capture_date: v.capture_date,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CorePreparedCacheEntry {
    pub metadata: CoreCachedFingerprint,
    pub sample: Vec<u8>,
}
#[derive(uniffi::Record)]
pub struct CoreCachedScene {
    pub provider: CoreSceneProvider,
    pub quality: CoreSceneQuality,
    pub archive: Vec<u8>,
}
#[derive(uniffi::Object)]
pub struct RustCacheStore {
    state: Mutex<CacheStore>,
}
impl RustCacheStore {
    fn access<T>(
        &self,
        op: impl FnOnce(&mut CacheStore) -> Result<T, CoreError>,
    ) -> Result<T, BridgeError> {
        let mut store = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        Ok(op(&mut store)?)
    }
}
#[uniffi::export]
impl RustCacheStore {
    #[uniffi::constructor]
    pub fn new(database_path: String) -> Result<Arc<Self>, BridgeError> {
        if database_path.is_empty() || database_path.len() > 32768 || database_path.contains('\0') {
            return Err(BridgeError::InvalidValue);
        }
        Ok(Arc::new(Self {
            state: Mutex::new(CacheStore::open(Path::new(&database_path))?),
        }))
    }
    pub fn store(
        &self,
        entries: Vec<CorePreparedCacheEntry>,
        pipeline: String,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<(), BridgeError> {
        if entries.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        let entries = entries
            .into_iter()
            .map(|e| {
                Ok(PreparedCacheEntry {
                    metadata: e.metadata.try_into()?,
                    sample: e.sample,
                })
            })
            .collect::<Result<Vec<_>, BridgeError>>()?;
        self.access(|store| store.store(entries, &pipeline, &cancellation.cancellation))
    }
    pub fn signatures_page(
        &self,
        source: String,
        pipeline: String,
        offset: u64,
        limit: u32,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<Vec<CoreCachedFingerprint>, BridgeError> {
        Ok(self
            .access(|store| {
                store.signatures_page(
                    &source,
                    &pipeline,
                    offset,
                    limit,
                    &cancellation.cancellation,
                )
            })?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn sample(
        &self,
        asset: CoreAssetKey,
        revision: String,
        pipeline: String,
    ) -> Result<Option<Vec<u8>>, BridgeError> {
        self.access(|store| store.sample(&asset.into(), &revision, &pipeline))
    }
    pub fn store_scene(
        &self,
        asset: CoreAssetKey,
        revision: String,
        scene: CoreCachedScene,
    ) -> Result<(), BridgeError> {
        self.access(|store| {
            store.store_scene(
                &asset.into(),
                &revision,
                CachedScene {
                    provider: scene.provider.into(),
                    quality: scene.quality.into(),
                    archive: scene.archive,
                },
            )
        })
    }
    pub fn scene(
        &self,
        asset: CoreAssetKey,
        revision: String,
        provider: CoreSceneProvider,
    ) -> Result<Option<CoreCachedScene>, BridgeError> {
        Ok(self
            .access(|store| store.scene(&asset.into(), &revision, &provider.into()))?
            .map(|scene| CoreCachedScene {
                provider: CoreSceneProvider {
                    provider_id: scene.provider.provider_id,
                    model_revision: scene.provider.model_revision,
                    preprocessing: scene.provider.preprocessing,
                    platform_compatibility: scene.provider.platform_compatibility,
                },
                quality: scene.quality.into(),
                archive: scene.archive,
            }))
    }
    pub fn remove_scene(&self, asset: CoreAssetKey) -> Result<(), BridgeError> {
        self.access(|store| store.remove_scene(&asset.into()))
    }
    pub fn finish(
        &self,
        assets: Vec<CoreAssetKey>,
        sources: Vec<String>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<(), BridgeError> {
        if assets.len() > 100000 || sources.len() > 4096 {
            return Err(BridgeError::InvalidBuffer);
        }
        let assets = assets.into_iter().map(Into::into).collect::<HashSet<_>>();
        let sources = sources.into_iter().collect::<HashSet<_>>();
        self.access(|store| store.finish(&assets, &sources, &cancellation.cancellation))
    }
    pub fn clear(&self) -> Result<(), BridgeError> {
        self.access(|store| store.clear())
    }
}
