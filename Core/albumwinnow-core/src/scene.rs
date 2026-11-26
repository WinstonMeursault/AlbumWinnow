use crate::{Cancellation, CoreError, model::NormalizedPixels};

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug, PartialEq)]
pub struct SceneQuality {
    pub mean_luminance: f64,
    pub texture_variance: f64,
    pub focus_energy: f64,
    pub dark_clipping: f64,
    pub bright_clipping: f64,
}

impl SceneQuality {
    pub fn validate(&self) -> Result<(), CoreError> {
        if [
            self.mean_luminance,
            self.texture_variance,
            self.dark_clipping,
            self.bright_clipping,
        ]
        .iter()
        .any(|value| !value.is_finite() || !(0.0..=1.0).contains(value))
            || !self.focus_energy.is_finite()
            || !(0.0..=16.0).contains(&self.focus_energy)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

pub fn quality(
    pixels: &NormalizedPixels,
    cancel: &Cancellation,
) -> Result<SceneQuality, CoreError> {
    pixels.validate()?;
    let size = pixels.width as usize;
    if !(3..=1024).contains(&size) || pixels.height != pixels.width {
        return Err(CoreError::InvalidPixels);
    }
    let mut luminance = Vec::with_capacity(size * size);
    for y in 0..size {
        cancel.check()?;
        for x in 0..size {
            let p = pixels.pixel(x, y);
            let red = 0.299 * f64::from(p[0]);
            let green = 0.587 * f64::from(p[1]);
            let blue = 0.114 * f64::from(p[2]);
            luminance.push((red + green + blue) / 255.0);
        }
    }
    let count = luminance.len() as f64;
    let mean = luminance.iter().sum::<f64>() / count;
    let variance = luminance
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / count;
    let dark = luminance.iter().filter(|value| **value <= 0.02).count() as f64 / count;
    let bright = luminance.iter().filter(|value| **value >= 0.98).count() as f64 / count;
    let mut energy = 0.0;
    for y in 1..size - 1 {
        cancel.check()?;
        for x in 1..size - 1 {
            let i = y * size + x;
            let horizontal = 4.0 * luminance[i] - luminance[i - 1] - luminance[i + 1];
            let laplacian = horizontal - luminance[i - size] - luminance[i + size];
            energy += laplacian * laplacian;
        }
    }
    Ok(SceneQuality {
        mean_luminance: mean,
        texture_variance: variance,
        focus_energy: energy / ((size - 2) * (size - 2)) as f64,
        dark_clipping: dark,
        bright_clipping: bright,
    })
}

/// Deterministic projections of a provider-specific 768-element feature vector.
/// Keys are only comparable within the same complete provider namespace.
pub fn keys(vector: &[f32], cancel: &Cancellation) -> Result<[u16; 4], CoreError> {
    if vector.len() != 768
        || vector.iter().any(|v| !v.is_finite())
        || !vector.iter().any(|v| *v != 0.0)
    {
        return Err(CoreError::InvalidValue);
    }
    let mut seed = 0xA1B0_2026_u64;
    let mut keys = [0_u16; 4];
    for key in &mut keys {
        cancel.check()?;
        for _ in 0..16 {
            let mut value = 0.0_f32;
            for _ in 0..16 {
                seed = seed
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let index = ((seed >> 32) % 768) as usize;
                let sign = if seed & 1 == 0 { 1.0 } else { -1.0 };
                value += vector[index] * sign;
            }
            *key = (*key << 1) | u16::from(value >= 0.0);
        }
    }
    Ok(keys)
}

pub fn matches(
    first: SceneQuality,
    second: SceneQuality,
    shared_burst: bool,
    distance: f32,
) -> Result<bool, CoreError> {
    first.validate()?;
    second.validate()?;
    if !distance.is_finite() || distance < 0.0 {
        return Err(CoreError::InvalidValue);
    }
    Ok(
        (shared_burst || (first.texture_variance >= 0.0004 && second.texture_variance >= 0.0004))
            && distance <= if shared_burst { 0.32 } else { 0.24 },
    )
}
