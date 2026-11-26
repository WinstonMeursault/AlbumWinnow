use crate::{BridgeError, CancellationHandle, PixelInput};

#[derive(Clone, uniffi::Record)]
pub struct CoreFingerprint {
    pub file_hash: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub bit_depth: u16,
    pub wide_color: bool,
    pub perceptual_hash: u64,
    pub difference_hash: u64,
    pub mean_rgba: Vec<u8>,
    pub edge_detail: f64,
}

impl TryFrom<CoreFingerprint> for albumwinnow_core::matching::Fingerprint {
    type Error = BridgeError;
    fn try_from(value: CoreFingerprint) -> Result<Self, Self::Error> {
        let result = Self {
            file_hash: value
                .file_hash
                .try_into()
                .map_err(|_| BridgeError::InvalidValue)?,
            width: value.width,
            height: value.height,
            bit_depth: value.bit_depth,
            wide_color: value.wide_color,
            metrics: albumwinnow_core::fingerprint::FingerprintMetrics {
                perceptual_hash: value.perceptual_hash,
                difference_hash: value.difference_hash,
                mean_rgba: value
                    .mean_rgba
                    .try_into()
                    .map_err(|_| BridgeError::InvalidValue)?,
                edge_detail: value.edge_detail,
            },
        };
        result.validate()?;
        Ok(result)
    }
}

#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreMatch {
    SceneSimilar,
    ExactDuplicate,
    SimilarPhoto,
    VisualDuplicate,
    Distinct,
}

impl From<CoreMatch> for albumwinnow_core::matching::MatchKind {
    fn from(value: CoreMatch) -> Self {
        match value {
            CoreMatch::SceneSimilar => Self::SceneSimilar,
            CoreMatch::ExactDuplicate => Self::ExactDuplicate,
            CoreMatch::SimilarPhoto => Self::SimilarPhoto,
            CoreMatch::VisualDuplicate => Self::VisualDuplicate,
            CoreMatch::Distinct => Self::Distinct,
        }
    }
}

impl From<albumwinnow_core::matching::MatchKind> for CoreMatch {
    fn from(value: albumwinnow_core::matching::MatchKind) -> Self {
        use albumwinnow_core::matching::MatchKind;
        match value {
            MatchKind::SceneSimilar => Self::SceneSimilar,
            MatchKind::ExactDuplicate => Self::ExactDuplicate,
            MatchKind::SimilarPhoto => Self::SimilarPhoto,
            MatchKind::VisualDuplicate => Self::VisualDuplicate,
            MatchKind::Distinct => Self::Distinct,
        }
    }
}

#[uniffi::export]
pub fn core_visual_candidate(
    first: CoreFingerprint,
    second: CoreFingerprint,
) -> Result<bool, BridgeError> {
    Ok(albumwinnow_core::matching::is_visual_candidate(
        &first.try_into()?,
        &second.try_into()?,
    ))
}

#[uniffi::export]
pub fn core_byte_identities_match(first: Vec<u8>, second: Vec<u8>) -> Result<bool, BridgeError> {
    if first.len() != 32 || second.len() != 32 {
        return Err(BridgeError::InvalidValue);
    }
    Ok(first == second)
}

#[uniffi::export]
pub fn core_quality_tied(
    first: crate::scan::ScanItemInput,
    second: crate::scan::ScanItemInput,
) -> Result<bool, BridgeError> {
    Ok(albumwinnow_core::scan::quality_tied(
        &first.try_into()?,
        &second.try_into()?,
    ))
}

#[uniffi::export]
impl CancellationHandle {
    pub fn verify_pixels(
        &self,
        first: PixelInput,
        second: PixelInput,
    ) -> Result<bool, BridgeError> {
        Ok(albumwinnow_core::matching::verify_pixels(
            &first.into(),
            &second.into(),
            &self.cancellation,
        )?)
    }

    pub fn detail_match(
        &self,
        first: PixelInput,
        second: PixelInput,
    ) -> Result<CoreMatch, BridgeError> {
        Ok(albumwinnow_core::matching::detail_match(
            &first.into(),
            &second.into(),
            &self.cancellation,
        )?
        .into())
    }
}

impl From<albumwinnow_core::matching::Fingerprint> for CoreFingerprint {
    fn from(v: albumwinnow_core::matching::Fingerprint) -> Self {
        Self {
            file_hash: v.file_hash.to_vec(),
            width: v.width,
            height: v.height,
            bit_depth: v.bit_depth,
            wide_color: v.wide_color,
            perceptual_hash: v.metrics.perceptual_hash,
            difference_hash: v.metrics.difference_hash,
            mean_rgba: v.metrics.mean_rgba.to_vec(),
            edge_detail: v.metrics.edge_detail,
        }
    }
}
