use crate::{Cancellation, CoreError, fingerprint::FingerprintMetrics, model::NormalizedPixels};

pub const PERCEPTUAL_RADIUS: u32 = 12;
pub const DIFFERENCE_RADIUS: u32 = 10;

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchKind {
    SceneSimilar,
    ExactDuplicate,
    SimilarPhoto,
    VisualDuplicate,
    Distinct,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Fingerprint {
    /// Canonical oriented byte identity produced by the Rust byte hasher.
    pub file_hash: [u8; 32],
    pub width: u32,
    pub height: u32,
    pub bit_depth: u16,
    pub wide_color: bool,
    pub metrics: FingerprintMetrics,
}

impl Fingerprint {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.width == 0
            || self.height == 0
            || u64::from(self.width) * u64::from(self.height) > crate::model::MAX_SOURCE_PIXELS
            || self.bit_depth == 0
            || self.bit_depth > 64
            || !self.metrics.edge_detail.is_finite()
            || self.metrics.edge_detail < 0.0
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

pub fn is_visual_candidate(a: &Fingerprint, b: &Fingerprint) -> bool {
    let first_aspect = f64::from(a.width) / f64::from(a.height);
    let second_aspect = f64::from(b.width) / f64::from(b.height);
    (first_aspect - second_aspect).abs() <= 0.006 * first_aspect.max(second_aspect)
        && ((a.metrics.perceptual_hash ^ b.metrics.perceptual_hash).count_ones()
            <= PERCEPTUAL_RADIUS
            || (a.metrics.difference_hash ^ b.metrics.difference_hash).count_ones()
                <= DIFFERENCE_RADIUS)
        && a.metrics
            .mean_rgba
            .iter()
            .zip(b.metrics.mean_rgba)
            .all(|(a, b)| a.abs_diff(b) <= 5)
}

pub fn verify_pixels(
    a: &NormalizedPixels,
    b: &NormalizedPixels,
    cancel: &Cancellation,
) -> Result<bool, CoreError> {
    a.validate()?;
    b.validate()?;
    if a.width != a.height
        || b.width != a.width
        || b.height != a.height
        || !a.width.is_multiple_of(8)
        || a.width > 1024
    {
        return Err(CoreError::InvalidPixels);
    }
    cancel.check()?;
    let size = a.width as usize;
    let block_pixels = 64.0;
    let mut total_error = 0.0;
    let mut total_ssim = 0.0;
    for y in (0..size).step_by(8) {
        cancel.check()?;
        for x in (0..size).step_by(8) {
            let mut error = 0_u32;
            let (mut sum_a, mut sum_b, mut square_a, mut square_b, mut product) =
                (0.0, 0.0, 0.0, 0.0, 0.0);
            for row in y..y + 8 {
                for column in x..x + 8 {
                    let pa = a.pixel(column, row);
                    let pb = b.pixel(column, row);
                    let pixel_error = pa
                        .iter()
                        .zip(pb)
                        .map(|(a, b)| a.abs_diff(*b))
                        .max()
                        .ok_or(CoreError::InvalidPixels)?;
                    error += u32::from(pixel_error);
                    let luma_a = luminance(pa);
                    let luma_b = luminance(pb);
                    sum_a += luma_a;
                    sum_b += luma_b;
                    square_a += luma_a * luma_a;
                    square_b += luma_b * luma_b;
                    product += luma_a * luma_b;
                }
            }
            let local_error = f64::from(error) / (255.0 * block_pixels);
            if local_error > 0.07 {
                return Ok(false);
            }
            total_error += local_error;
            let mean_a = sum_a / block_pixels;
            let mean_b = sum_b / block_pixels;
            let variance_a = (square_a / block_pixels - mean_a * mean_a).max(0.0);
            let variance_b = (square_b / block_pixels - mean_b * mean_b).max(0.0);
            let covariance = product / block_pixels - mean_a * mean_b;
            let c1 = 0.01 * 0.01;
            let c2 = 0.03 * 0.03;
            total_ssim += ((2.0 * mean_a * mean_b + c1) * (2.0 * covariance + c2))
                / ((mean_a * mean_a + mean_b * mean_b + c1) * (variance_a + variance_b + c2));
        }
    }
    let blocks = (size * size) as f64 / block_pixels;
    Ok(total_error / blocks <= 0.018 && total_ssim / blocks >= 0.97)
}

pub fn detail_match(
    a: &NormalizedPixels,
    b: &NormalizedPixels,
    cancel: &Cancellation,
) -> Result<MatchKind, CoreError> {
    Ok(if verify_pixels(a, b, cancel)? {
        MatchKind::VisualDuplicate
    } else {
        MatchKind::SimilarPhoto
    })
}

fn luminance(pixel: &[u8]) -> f64 {
    let value = 77 * u32::from(pixel[0]) + 150 * u32::from(pixel[1]) + 29 * u32::from(pixel[2]);
    f64::from(value) / (256.0 * 255.0)
}
