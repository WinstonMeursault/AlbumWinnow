pub mod cache;
pub mod candidate;
pub mod cleanup;
pub mod difference;
pub mod fingerprint;
pub mod hashing;
pub mod matching;
pub mod model;
pub mod review;
pub mod review_query;
pub mod review_scan;
pub mod review_session;
pub mod review_store;
pub mod scan;
pub mod scene;
pub mod scene_session;
pub mod signature;

use std::sync::atomic::{AtomicBool, Ordering};

pub const MAX_BUFFER_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CoreError {
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

#[derive(Default, Debug)]
pub struct Cancellation(AtomicBool);

impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn check(&self) -> Result<(), CoreError> {
        if self.0.load(Ordering::Acquire) {
            Err(CoreError::Cancelled)
        } else {
            Ok(())
        }
    }
}

pub fn hash_buffer(bytes: &[u8], cancellation: &Cancellation) -> Result<String, CoreError> {
    if bytes.len() > MAX_BUFFER_BYTES {
        return Err(CoreError::InvalidBuffer);
    }
    cancellation.check()?;
    let mut hasher = blake3::Hasher::new();
    for chunk in bytes.chunks(64 * 1024) {
        cancellation.check()?;
        hasher.update(chunk);
    }
    cancellation.check()?;
    Ok(hasher.finalize().to_hex().to_string())
}

/// Verifies bundled SQLite is callable through the same library on both hosts.
/// P1 probe only: this is not the v2 review schema or its initialization path.
pub fn sqlite_probe() -> Result<String, CoreError> {
    let connection =
        rusqlite::Connection::open_in_memory().map_err(|_| CoreError::StorageUnavailable)?;
    connection
        .query_row("SELECT sqlite_version()", [], |row| row.get(0))
        .map_err(|_| CoreError::StorageUnavailable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_hash_and_invalid_length() {
        let cancel = Cancellation::default();
        assert_eq!(
            hash_buffer(b"abc", &cancel).unwrap(),
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        );
        assert_eq!(
            hash_buffer(&vec![0; MAX_BUFFER_BYTES + 1], &cancel),
            Err(CoreError::InvalidBuffer)
        );
    }

    #[test]
    fn cancellation_is_independent_and_idempotent() {
        let cancel = Cancellation::default();
        cancel.cancel();
        cancel.cancel();
        assert_eq!(hash_buffer(b"abc", &cancel), Err(CoreError::Cancelled));
        assert!(hash_buffer(b"abc", &Cancellation::default()).is_ok());
    }

    #[test]
    fn bundled_sqlite_is_available() {
        assert!(!sqlite_probe().unwrap().is_empty());
    }
}
