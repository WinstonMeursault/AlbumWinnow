use super::*;

#[uniffi::export]
impl RustReviewSession {
    pub fn begin_read_only_snapshot(
        &self,
        expected_revision: u64,
        operation_id: String,
        source: String,
    ) -> Result<(), BridgeError> {
        self.access(|s| s.begin_read_only_snapshot(expected_revision, operation_id, &source))
    }
    pub fn append_read_only_snapshot(
        &self,
        operation_id: String,
        members: Vec<CoreReviewAsset>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<(), BridgeError> {
        cancellation.cancellation.check()?;
        if members.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        self.access(|s| {
            cancellation.cancellation.check()?;
            s.append_read_only_snapshot(
                &operation_id,
                members.into_iter().map(Into::into).collect(),
            )
        })
    }
    pub fn finish_read_only_snapshot(
        &self,
        operation_id: String,
        complete: bool,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        cancellation.cancellation.check()?;
        self.access(|s| {
            cancellation.cancellation.check()?;
            s.finish_read_only_snapshot(&operation_id, complete)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn discard_read_only_snapshot(&self, operation_id: String) -> Result<(), BridgeError> {
        self.access(|s| s.discard_read_only_snapshot(&operation_id))
    }
    pub fn remove_read_only(
        &self,
        expected_revision: u64,
        source: String,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.remove_read_only(expected_revision, &source)?;
            Ok(s.metadata().clone().into())
        })
    }
}
#[uniffi::export]
pub fn core_capture_range_contains(
    range: CoreCaptureRange,
    date: Option<f64>,
) -> Result<bool, BridgeError> {
    Ok(review::CaptureRange::from(range).contains(date)?)
}
