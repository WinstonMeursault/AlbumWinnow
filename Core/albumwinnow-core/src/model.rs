use crate::CoreError;

pub const MAX_SOURCE_PIXELS: u64 = 150_000_000;
pub const MAX_PIXEL_SIDE: u32 = 2048;
pub const MAX_PIXEL_BYTES: usize = 2048 * 2048 * 4;

#[derive(
    serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord,
)]
pub struct AssetId {
    pub source_id: String,
    pub item_id: String,
}

impl AssetId {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.source_id.is_empty()
            || self.item_id.is_empty()
            || self.source_id.len() > 4096
            || self.item_id.len() > 65536
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

/// Values are opaque to the core. A host must retain native nanosecond identity
/// evidence rather than reducing a revision to a floating-point timestamp.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetRevision {
    pub revision: String,
    pub identity_namespace: String,
    pub identity: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageMetadata {
    pub width: u32,
    pub height: u32,
    pub bit_depth: u16,
    pub wide_color: bool,
    pub effective_orientation: u8,
}

impl ImageMetadata {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.width == 0
            || self.height == 0
            || u64::from(self.width) * u64::from(self.height) > MAX_SOURCE_PIXELS
            || self.bit_depth == 0
            || self.bit_depth > 64
            || !(1..=8).contains(&self.effective_orientation)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

/// RGBA8, sRGB, premultiplied alpha, rows from top to bottom, orientation applied.
/// Decode and resample in the host; no compressed image bytes or platform objects.
#[derive(Clone, Debug)]
pub struct NormalizedPixels {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub rgba: Vec<u8>,
    pub decode_pipeline: String,
}

impl NormalizedPixels {
    pub fn validate(&self) -> Result<(), CoreError> {
        let expected = u64::from(self.stride) * u64::from(self.height);
        if self.width == 0
            || self.height == 0
            || self.width > MAX_PIXEL_SIDE
            || self.height > MAX_PIXEL_SIDE
            || u64::from(self.stride) < u64::from(self.width) * 4
            || expected > MAX_PIXEL_BYTES as u64
            || expected != self.rgba.len() as u64
            || self.decode_pipeline.is_empty()
            || self.decode_pipeline.len() > 128
        {
            return Err(CoreError::InvalidPixels);
        }
        Ok(())
    }

    pub(crate) fn pixel(&self, x: usize, y: usize) -> &[u8] {
        let index = y * self.stride as usize + x * 4;
        &self.rgba[index..index + 4]
    }
}

pub fn validate_date(date: Option<f64>) -> Result<(), CoreError> {
    if date.is_some_and(|date| !date.is_finite()) {
        Err(CoreError::InvalidValue)
    } else {
        Ok(())
    }
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SceneProvider {
    pub provider_id: String,
    pub model_revision: String,
    pub preprocessing: String,
    pub platform_compatibility: String,
}

impl SceneProvider {
    pub fn validate(&self) -> Result<(), CoreError> {
        if [
            &self.provider_id,
            &self.model_revision,
            &self.preprocessing,
            &self.platform_compatibility,
        ]
        .iter()
        .any(|value| value.is_empty() || value.len() > 256)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetCapabilities {
    pub comparable: bool,
    pub scene_provider: Option<SceneProvider>,
    pub recoverable_removal: bool,
}
