use crate::{BridgeError, CancellationHandle, PixelInput};

#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreDifferenceUnavailable {
    Geometry,
    InsufficientDetail,
    Alignment,
}

#[derive(Clone, uniffi::Record)]
pub struct CoreDifferenceRegion {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, uniffi::Record)]
pub struct CoreDifference {
    pub regions: Vec<CoreDifferenceRegion>,
    pub unavailable: Option<CoreDifferenceUnavailable>,
}

#[uniffi::export]
impl CancellationHandle {
    pub fn photo_difference(
        &self,
        first: PixelInput,
        first_width: u32,
        first_height: u32,
        second: PixelInput,
        second_width: u32,
        second_height: u32,
    ) -> Result<CoreDifference, BridgeError> {
        let result = albumwinnow_core::difference::analyze(
            &first.into(),
            (first_width, first_height),
            &second.into(),
            (second_width, second_height),
            &self.cancellation,
        )?;
        Ok(CoreDifference {
            regions: result
                .regions
                .into_iter()
                .map(|r| CoreDifferenceRegion {
                    x: r.x,
                    y: r.y,
                    width: r.width,
                    height: r.height,
                })
                .collect(),
            unavailable: result.unavailable.map(|reason| match reason {
                albumwinnow_core::difference::UnavailableReason::Geometry => {
                    CoreDifferenceUnavailable::Geometry
                }
                albumwinnow_core::difference::UnavailableReason::InsufficientDetail => {
                    CoreDifferenceUnavailable::InsufficientDetail
                }
                albumwinnow_core::difference::UnavailableReason::Alignment => {
                    CoreDifferenceUnavailable::Alignment
                }
            }),
        })
    }
}
