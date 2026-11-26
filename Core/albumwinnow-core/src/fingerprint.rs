use crate::{Cancellation, CoreError, model::NormalizedPixels};

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
pub struct FingerprintMetrics {
    pub perceptual_hash: u64,
    pub difference_hash: u64,
    pub mean_rgba: [u8; 4],
    pub edge_detail: f64,
}

pub fn fingerprint(
    pixels: &NormalizedPixels,
    cancellation: &Cancellation,
) -> Result<FingerprintMetrics, CoreError> {
    pixels.validate()?;
    if pixels.width != 128 || pixels.height != 128 {
        return Err(CoreError::InvalidPixels);
    }
    cancellation.check()?;
    let luminance = luminance_grid(pixels, 32, 32, cancellation)?;
    let perceptual_hash = phash(&luminance, cancellation)?;
    let difference = luminance_grid(pixels, 9, 8, cancellation)?;
    let mut difference_hash = 0;
    for y in 0..8 {
        for x in 0..8 {
            let index = y * 9 + x;
            difference_hash =
                (difference_hash << 1) | u64::from(difference[index] > difference[index + 1]);
        }
    }
    let mut totals = [0_u64; 4];
    for y in 0..128 {
        cancellation.check()?;
        for x in 0..128 {
            for (total, byte) in totals.iter_mut().zip(pixels.pixel(x, y)) {
                *total += u64::from(*byte);
            }
        }
    }
    let count = 128 * 128;
    let mean_rgba = totals.map(|total| ((total + count / 2) / count) as u8);
    let mut edge_detail = 0.0;
    for y in 1..31 {
        cancellation.check()?;
        for x in 1..31 {
            let index = y * 32 + x;
            let horizontal = luminance[index + 1] - luminance[index - 1];
            let vertical = luminance[index + 32] - luminance[index - 32];
            edge_detail += horizontal * horizontal + vertical * vertical;
        }
    }
    Ok(FingerprintMetrics {
        perceptual_hash,
        difference_hash,
        mean_rgba,
        edge_detail: edge_detail / 900.0,
    })
}

fn luminance_grid(
    pixels: &NormalizedPixels,
    columns: usize,
    rows: usize,
    cancellation: &Cancellation,
) -> Result<Vec<f64>, CoreError> {
    let mut values = Vec::with_capacity(columns * rows);
    for row in 0..rows {
        cancellation.check()?;
        let y_start = row * 128 / rows;
        let y_end = (row + 1) * 128 / rows;
        for column in 0..columns {
            let x_start = column * 128 / columns;
            let x_end = (column + 1) * 128 / columns;
            let mut total = 0_u64;
            for y in y_start..y_end {
                for x in x_start..x_end {
                    let p = pixels.pixel(x, y);
                    total += 77 * u64::from(p[0]) + 150 * u64::from(p[1]) + 29 * u64::from(p[2]);
                }
            }
            values.push(total as f64 / (256 * (x_end - x_start) * (y_end - y_start)) as f64);
        }
    }
    Ok(values)
}

fn phash(luminance: &[f64], cancellation: &Cancellation) -> Result<u64, CoreError> {
    let cosine: Vec<Vec<f64>> = (0..8)
        .map(|frequency| {
            (0..32)
                .map(|offset| {
                    (std::f64::consts::PI * ((2 * offset + 1) * frequency) as f64 / 64.0).cos()
                })
                .collect()
        })
        .collect();
    let mut horizontal = [0.0; 32 * 8];
    for y in 0..32 {
        cancellation.check()?;
        for u in 0..8 {
            for x in 0..32 {
                horizontal[y * 8 + u] += luminance[y * 32 + x] * cosine[u][x];
            }
        }
    }
    let mut coefficients = Vec::with_capacity(63);
    for (v, cosines) in cosine.iter().enumerate() {
        cancellation.check()?;
        for u in 0..8 {
            if u == 0 && v == 0 {
                continue;
            }
            let mut coefficient = 0.0;
            for y in 0..32 {
                coefficient += horizontal[y * 8 + u] * cosines[y];
            }
            let scale = if u == 0 || v == 0 {
                1.0 / 2_f64.sqrt()
            } else {
                1.0
            };
            coefficients.push((coefficient * scale / 16.0 * 100.0).round() / 100.0);
        }
    }
    let mut sorted = coefficients.clone();
    sorted.sort_by(f64::total_cmp);
    let median = sorted[sorted.len() / 2];
    Ok(coefficients
        .into_iter()
        .fold(0, |hash, value| (hash << 1) | u64::from(value > median)))
}
