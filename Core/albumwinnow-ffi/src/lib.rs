mod cache;
mod difference;
mod matching;
mod review;
mod scan;
mod scene;
mod signature;

use albumwinnow_core::{Cancellation, CoreError};
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("invalid_state")]
    InvalidState,
    #[error("stale_operation")]
    StaleOperation,
    #[error("internal_failure")]
    InternalFailure,
    #[error("invalid_pixels")]
    InvalidPixels,
    #[error("invalid_value")]
    InvalidValue,
    #[error("invalid_buffer")]
    InvalidBuffer,
    #[error("cancelled")]
    Cancelled,
    #[error("storage_corrupt")]
    StorageCorrupt,
    #[error("unsupported_schema")]
    UnsupportedSchema,
    #[error("protection_unavailable")]
    ProtectionUnavailable,
    #[error("write_failed")]
    WriteFailed,
    #[error("storage_unavailable")]
    StorageUnavailable,
}

impl From<CoreError> for BridgeError {
    fn from(value: CoreError) -> Self {
        match value {
            CoreError::InvalidState => Self::InvalidState,
            CoreError::StaleOperation => Self::StaleOperation,
            CoreError::InternalFailure => Self::InternalFailure,
            CoreError::InvalidPixels => Self::InvalidPixels,
            CoreError::InvalidValue => Self::InvalidValue,
            CoreError::InvalidBuffer => Self::InvalidBuffer,
            CoreError::Cancelled => Self::Cancelled,
            CoreError::StorageUnavailable => Self::StorageUnavailable,
            CoreError::StorageCorrupt => Self::StorageCorrupt,
            CoreError::UnsupportedSchema => Self::UnsupportedSchema,
            CoreError::ProtectionUnavailable => Self::ProtectionUnavailable,
            CoreError::WriteFailed => Self::WriteFailed,
        }
    }
}

#[derive(uniffi::Record)]
pub struct BridgeIdentity {
    pub source_id: String,
    pub item_id: String,
    pub revision: Option<String>,
}

#[derive(uniffi::Record)]
pub struct BridgeProbe {
    pub value: u64,
    pub date: Option<f64>,
    pub identity: BridgeIdentity,
}

#[derive(uniffi::Object, Default)]
pub struct CancellationHandle {
    cancellation: Arc<Cancellation>,
}

#[uniffi::export]
impl CancellationHandle {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub fn check(&self) -> Result<(), BridgeError> {
        Ok(self.cancellation.check()?)
    }

    pub fn hash_buffer(&self, bytes: Vec<u8>) -> Result<String, BridgeError> {
        Ok(albumwinnow_core::hash_buffer(&bytes, &self.cancellation)?)
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[uniffi::export]
pub fn round_trip(probe: BridgeProbe) -> Result<BridgeProbe, BridgeError> {
    albumwinnow_core::model::validate_date(probe.date)?;
    Ok(probe)
}

#[uniffi::export]
pub fn sqlite_probe() -> Result<String, BridgeError> {
    Ok(albumwinnow_core::sqlite_probe()?)
}

#[derive(uniffi::Record)]
pub struct PixelInput {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub rgba: Vec<u8>,
    pub decode_pipeline: String,
}

impl From<PixelInput> for albumwinnow_core::model::NormalizedPixels {
    fn from(value: PixelInput) -> Self {
        Self {
            width: value.width,
            height: value.height,
            stride: value.stride,
            rgba: value.rgba,
            decode_pipeline: value.decode_pipeline,
        }
    }
}

#[derive(uniffi::Record)]
pub struct PixelFingerprint {
    pub perceptual_hash: u64,
    pub difference_hash: u64,
    pub mean_rgba: Vec<u8>,
    pub edge_detail: f64,
}

#[uniffi::export]
impl CancellationHandle {
    pub fn fingerprint_pixels(&self, pixels: PixelInput) -> Result<PixelFingerprint, BridgeError> {
        let metrics =
            albumwinnow_core::fingerprint::fingerprint(&pixels.into(), &self.cancellation)?;
        Ok(PixelFingerprint {
            perceptual_hash: metrics.perceptual_hash,
            difference_hash: metrics.difference_hash,
            mean_rgba: metrics.mean_rgba.to_vec(),
            edge_detail: metrics.edge_detail,
        })
    }
}

#[derive(uniffi::Object)]
pub struct ByteHasher {
    hasher: Mutex<albumwinnow_core::hashing::ByteHasher>,
    cancellation: Arc<CancellationHandle>,
}

#[uniffi::export]
impl ByteHasher {
    #[uniffi::constructor]
    pub fn new(cancellation: Arc<CancellationHandle>) -> Arc<Self> {
        Arc::new(Self {
            hasher: Mutex::new(Default::default()),
            cancellation,
        })
    }

    pub fn update(&self, bytes: Vec<u8>) -> Result<(), BridgeError> {
        self.cancellation.cancellation.check()?;
        self.hasher
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?
            .update(&bytes, &self.cancellation.cancellation)?;
        Ok(())
    }

    pub fn digest_for_orientation(&self, orientation: u8) -> Result<Vec<u8>, BridgeError> {
        self.cancellation.cancellation.check()?;
        Ok(self
            .hasher
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?
            .digest_for_orientation(orientation, &self.cancellation.cancellation)?)
    }

    pub fn digest(&self) -> Result<Vec<u8>, BridgeError> {
        self.cancellation.cancellation.check()?;
        Ok(self
            .hasher
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?
            .digest(&self.cancellation.cancellation)?)
    }
}
