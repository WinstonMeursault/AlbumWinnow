use crate::{Cancellation, CoreError, MAX_BUFFER_BYTES};

#[derive(Default)]
pub struct ByteHasher(blake3::Hasher);

impl ByteHasher {
    pub fn update(&mut self, bytes: &[u8], cancellation: &Cancellation) -> Result<(), CoreError> {
        if bytes.len() > MAX_BUFFER_BYTES {
            return Err(CoreError::InvalidBuffer);
        }
        cancellation.check()?;
        for chunk in bytes.chunks(64 * 1024) {
            cancellation.check()?;
            self.0.update(chunk);
        }
        cancellation.check()
    }

    pub fn digest_for_orientation(
        &self,
        orientation: u8,
        cancellation: &Cancellation,
    ) -> Result<Vec<u8>, CoreError> {
        cancellation.check()?;
        if !(1..=8).contains(&orientation) {
            return Err(CoreError::InvalidValue);
        }
        let mut identity = blake3::Hasher::new();
        identity.update(b"AlbumWinnow.v2.byte-identity\0");
        identity.update(self.0.finalize().as_bytes());
        identity.update(&[orientation]);
        Ok(identity.finalize().as_bytes().to_vec())
    }

    pub fn digest(&self, cancellation: &Cancellation) -> Result<Vec<u8>, CoreError> {
        cancellation.check()?;
        Ok(self.0.finalize().as_bytes().to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streamed_bytes_equal_one_buffer_regardless_of_chunking() {
        let cancel = Cancellation::default();
        let bytes = vec![17; 2 * 1024 * 1024 + 13];
        let expected = blake3::hash(&bytes).as_bytes().to_vec();
        for chunk_size in [1, 1023, 64 * 1024, 1024 * 1024] {
            let mut hasher = ByteHasher::default();
            for chunk in bytes.chunks(chunk_size) {
                hasher.update(chunk, &cancel).unwrap();
            }
            assert_eq!(hasher.digest(&cancel).unwrap(), expected);
        }
        let mut hasher = ByteHasher::default();
        hasher.update(b"a", &cancel).unwrap();
        cancel.cancel();
        assert_eq!(hasher.update(b"b", &cancel), Err(CoreError::Cancelled));
        assert_eq!(hasher.digest(&cancel), Err(CoreError::Cancelled));
    }
}
