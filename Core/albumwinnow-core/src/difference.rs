use crate::{Cancellation, CoreError, model::NormalizedPixels};

const SIZE: usize = 256;
const COLUMNS: usize = 64;
const PIXELS: usize = SIZE * SIZE;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnavailableReason {
    Geometry,
    InsufficientDetail,
    Alignment,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Region {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Region {
    fn area(self) -> f64 {
        self.width * self.height
    }
    fn near(self, other: Self) -> bool {
        let gap = 2.0 / COLUMNS as f64;
        self.x - gap < other.x + other.width
            && other.x < self.x + self.width + gap
            && self.y - gap < other.y + other.height
            && other.y < self.y + self.height + gap
    }
    fn union(self, other: Self) -> Self {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Self {
            x,
            y,
            width: (self.x + self.width).max(other.x + other.width) - x,
            height: (self.y + self.height).max(other.y + other.height) - y,
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Difference {
    pub regions: Vec<Region>,
    pub unavailable: Option<UnavailableReason>,
}

fn unavailable(reason: UnavailableReason) -> Difference {
    Difference {
        regions: Vec::new(),
        unavailable: Some(reason),
    }
}

/// Pixels are resampled by the native decoder; dimensions describe its bounded preview.
/// This output is explanatory only and does not authorize cleanup.
pub fn analyze(
    first: &NormalizedPixels,
    first_dimensions: (u32, u32),
    second: &NormalizedPixels,
    second_dimensions: (u32, u32),
    cancel: &Cancellation,
) -> Result<Difference, CoreError> {
    for pixels in [first, second] {
        pixels.validate()?;
        if pixels.width != SIZE as u32 || pixels.height != SIZE as u32 {
            return Err(CoreError::InvalidPixels);
        }
    }
    let (aw, ah) = first_dimensions;
    let (bw, bh) = second_dimensions;
    if [aw, ah, bw, bh]
        .iter()
        .any(|side| *side == 0 || *side > 512)
    {
        return Err(CoreError::InvalidValue);
    }
    cancel.check()?;
    let aspect = f64::from(aw) / f64::from(ah);
    let other_aspect = f64::from(bw) / f64::from(bh);
    if (aspect - other_aspect).abs() / aspect > 0.005 {
        return Ok(unavailable(UnavailableReason::Geometry));
    }
    if aw.min(ah).min(bw).min(bh) < 64 {
        return Ok(unavailable(UnavailableReason::InsufficientDetail));
    }
    let left = smooth(&rgb(first, cancel)?, cancel)?;
    let mut right = smooth(&rgb(second, cancel)?, cancel)?;
    for channel in 0..3 {
        cancel.check()?;
        let a = quartiles(&left, channel);
        let b = quartiles(&right, channel);
        let spread = b[2] - b[0];
        let gain = if spread > 0.02 {
            (a[2] - a[0]) / spread
        } else {
            1.0
        };
        if !(0.6..=1.7).contains(&gain) {
            return Ok(unavailable(UnavailableReason::Alignment));
        }
        let offset = a[1] - gain * b[1];
        for pixel in 0..PIXELS {
            let index = pixel * 3 + channel;
            right[index] = (right[index] * gain + offset).clamp(0.0, 1.0);
        }
    }
    let count = COLUMNS * COLUMNS;
    let mut cross = vec![0.0_f64; count];
    let mut left_energy = cross.clone();
    let mut right_energy = cross.clone();
    let mut residual = vec![0.0_f32; count];
    let mut changed = vec![0_usize; count];
    let lg = luminance(&left);
    let rg = luminance(&right);
    let mut total = 0.0_f32;
    for y in 1..SIZE - 1 {
        cancel.check()?;
        for x in 1..SIZE - 1 {
            let pixel = y * SIZE + x;
            let tile = y / 4 * COLUMNS + x / 4;
            let ax = f64::from(lg[pixel + 1] - lg[pixel - 1]);
            let ay = f64::from(lg[pixel + SIZE] - lg[pixel - SIZE]);
            let bx = f64::from(rg[pixel + 1] - rg[pixel - 1]);
            let by = f64::from(rg[pixel + SIZE] - rg[pixel - SIZE]);
            cross[tile] += ax * bx + ay * by;
            left_energy[tile] += ax * ax + ay * ay;
            right_energy[tile] += bx * bx + by * by;
            let index = pixel * 3;
            let difference = (left[index] - right[index])
                .abs()
                .max((left[index + 1] - right[index + 1]).abs())
                .max((left[index + 2] - right[index + 2]).abs());
            residual[tile] += difference;
            total += difference;
            if difference >= 0.08 {
                changed[tile] += 1;
            }
        }
    }
    let mut textured = 0;
    let mut agreeing = 0;
    for tile in 0..count {
        if left_energy[tile].max(right_energy[tile]) >= 0.002 {
            textured += 1;
            let denominator = (left_energy[tile] * right_energy[tile]).sqrt();
            if denominator > 0.0 && cross[tile] / denominator >= 0.9 {
                agreeing += 1;
            }
        }
    }
    if textured < 24 {
        return Ok(unavailable(UnavailableReason::InsufficientDetail));
    }
    if f64::from(agreeing) / f64::from(textured) < 0.85 || total / PIXELS as f32 > 0.065 {
        return Ok(unavailable(UnavailableReason::Alignment));
    }
    let mut mask: Vec<bool> = (0..count)
        .map(|i| changed[i] >= 3 && residual[i] / 16.0 >= 0.035)
        .collect();
    if mask.iter().filter(|value| **value).count() > count * 15 / 100 {
        return Ok(unavailable(UnavailableReason::Alignment));
    }
    let mut regions = Vec::new();
    for start in 0..count {
        if !mask[start] {
            continue;
        }
        cancel.check()?;
        let mut members = vec![start];
        mask[start] = false;
        let mut cursor = 0;
        let (mut min_x, mut max_x, mut min_y, mut max_y) = (
            start % COLUMNS,
            start % COLUMNS,
            start / COLUMNS,
            start / COLUMNS,
        );
        while cursor < members.len() {
            let tile = members[cursor];
            cursor += 1;
            let (x, y) = (tile % COLUMNS, tile / COLUMNS);
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
            for ny in y.saturating_sub(1)..=(y + 1).min(COLUMNS - 1) {
                for nx in x.saturating_sub(1)..=(x + 1).min(COLUMNS - 1) {
                    let next = ny * COLUMNS + nx;
                    if mask[next] {
                        mask[next] = false;
                        members.push(next);
                    }
                }
            }
        }
        if members.len() < 2 {
            continue;
        }
        let rect = Region {
            x: min_x as f64 / COLUMNS as f64,
            y: min_y as f64 / COLUMNS as f64,
            width: (max_x - min_x + 1) as f64 / COLUMNS as f64,
            height: (max_y - min_y + 1) as f64 / COLUMNS as f64,
        };
        if rect.area() > 0.2 {
            return Ok(unavailable(UnavailableReason::Alignment));
        }
        regions.push(rect);
    }
    let mut merged: Vec<Region> = Vec::new();
    for mut region in regions {
        cancel.check()?;
        while let Some(index) = merged.iter().position(|other| other.near(region)) {
            region = region.union(merged.remove(index));
        }
        if region.area() > 0.2 {
            return Ok(unavailable(UnavailableReason::Alignment));
        }
        merged.push(region);
    }
    if merged.len() > 12 {
        return Ok(unavailable(UnavailableReason::Alignment));
    }
    Ok(Difference {
        regions: merged,
        unavailable: None,
    })
}

fn rgb(pixels: &NormalizedPixels, cancel: &Cancellation) -> Result<Vec<f32>, CoreError> {
    let mut result = Vec::with_capacity(PIXELS * 3);
    for y in 0..SIZE {
        cancel.check()?;
        for x in 0..SIZE {
            let p = pixels.pixel(x, y);
            let background = f32::from(255 - p[3]) / 255.0;
            for value in &p[..3] {
                result.push((f32::from(*value) / 255.0 + background).min(1.0));
            }
        }
    }
    Ok(result)
}

fn smooth(pixels: &[f32], cancel: &Cancellation) -> Result<Vec<f32>, CoreError> {
    let mut horizontal = pixels.to_vec();
    let mut result = pixels.to_vec();
    for y in 0..SIZE {
        cancel.check()?;
        for x in 0..SIZE {
            for channel in 0..3 {
                let index = (y * SIZE + x) * 3 + channel;
                let left = (y * SIZE + x.saturating_sub(1)) * 3 + channel;
                let right = (y * SIZE + (x + 1).min(SIZE - 1)) * 3 + channel;
                horizontal[index] = (pixels[left] + pixels[index] + pixels[right]) / 3.0;
            }
        }
    }
    for y in 0..SIZE {
        cancel.check()?;
        for x in 0..SIZE {
            for channel in 0..3 {
                let index = (y * SIZE + x) * 3 + channel;
                let above = (y.saturating_sub(1) * SIZE + x) * 3 + channel;
                let below = ((y + 1).min(SIZE - 1) * SIZE + x) * 3 + channel;
                result[index] = (horizontal[above] + horizontal[index] + horizontal[below]) / 3.0;
            }
        }
    }
    Ok(result)
}

fn quartiles(pixels: &[f32], channel: usize) -> [f32; 3] {
    let mut histogram = [0_usize; 256];
    for pixel in 0..PIXELS {
        histogram[(pixels[pixel * 3 + channel] * 255.0).round() as usize] += 1;
    }
    [0.1, 0.5, 0.9].map(|fraction| {
        let target = (PIXELS as f64 * fraction) as usize;
        let mut count = 0;
        for (index, value) in histogram.iter().enumerate() {
            count += value;
            if count >= target {
                return index as f32 / 255.0;
            }
        }
        1.0
    })
}

fn luminance(rgb: &[f32]) -> Vec<f32> {
    rgb.as_chunks::<3>()
        .0
        .iter()
        .map(|p| {
            let red = 0.299 * p[0];
            let green = 0.587 * p[1];
            let blue = 0.114 * p[2];
            red + green + blue
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn touching_rectangles_do_not_intersect() {
        let region = Region {
            x: 0.0,
            y: 0.0,
            width: 0.25,
            height: 0.25,
        };
        let gap = 2.0 / COLUMNS as f64;
        assert!(!region.near(Region {
            x: 0.25 + gap,
            ..region
        }));
        assert!(region.near(Region {
            x: 0.25 + gap - 1.0 / 64.0,
            ..region
        }));
    }
}
