use crate::{
    Cancellation, CoreError,
    matching::{DIFFERENCE_RADIUS, Fingerprint, PERCEPTUAL_RADIUS},
};
use std::collections::{BTreeSet, HashMap};

pub struct CandidateIndex {
    files: HashMap<[u8; 32], Vec<usize>>,
    perceptual: HammingBuckets,
    difference: HammingBuckets,
}

impl CandidateIndex {
    pub fn new(fingerprints: &[Fingerprint], cancel: &Cancellation) -> Result<Self, CoreError> {
        let mut files = HashMap::<_, Vec<_>>::new();
        for (index, value) in fingerprints.iter().enumerate() {
            cancel.check()?;
            value.validate()?;
            files.entry(value.file_hash).or_default().push(index);
        }
        Ok(Self {
            files,
            perceptual: HammingBuckets::new(
                fingerprints
                    .iter()
                    .map(|f| f.metrics.perceptual_hash)
                    .collect(),
                PERCEPTUAL_RADIUS,
                cancel,
            )?,
            difference: HammingBuckets::new(
                fingerprints
                    .iter()
                    .map(|f| f.metrics.difference_hash)
                    .collect(),
                DIFFERENCE_RADIUS,
                cancel,
            )?,
        })
    }

    pub fn candidates(
        &self,
        fingerprint: &Fingerprint,
        after: usize,
        cancel: &Cancellation,
    ) -> Result<Vec<usize>, CoreError> {
        cancel.check()?;
        let mut matches = BTreeSet::new();
        if let Some(files) = self.files.get(&fingerprint.file_hash) {
            for candidate in files.iter().copied().filter(|index| *index > after) {
                cancel.check()?;
                matches.insert(candidate);
            }
        }
        self.perceptual.collect(
            fingerprint.metrics.perceptual_hash,
            after,
            &mut matches,
            cancel,
        )?;
        self.difference.collect(
            fingerprint.metrics.difference_hash,
            after,
            &mut matches,
            cancel,
        )?;
        Ok(matches.into_iter().collect())
    }
}

struct HammingBuckets {
    hashes: Vec<u64>,
    radius: u32,
    buckets: [HashMap<u16, Vec<usize>>; 4],
    flip_masks: Vec<Vec<u16>>,
}

impl HammingBuckets {
    fn new(hashes: Vec<u64>, radius: u32, cancel: &Cancellation) -> Result<Self, CoreError> {
        let mut buckets: [HashMap<_, Vec<_>>; 4] = Default::default();
        for (index, hash) in hashes.iter().enumerate() {
            cancel.check()?;
            for (band, bucket) in buckets.iter_mut().enumerate() {
                bucket
                    .entry((hash >> (band * 16)) as u16)
                    .or_default()
                    .push(index);
            }
        }
        let mut flip_masks = vec![Vec::new(); 4];
        for mask in 0..=u16::MAX {
            if mask % 1024 == 0 {
                cancel.check()?;
            }
            for (radius, masks) in flip_masks.iter_mut().enumerate() {
                if mask.count_ones() <= radius as u32 {
                    masks.push(mask);
                }
            }
        }
        Ok(Self {
            hashes,
            radius,
            buckets,
            flip_masks,
        })
    }

    fn collect(
        &self,
        hash: u64,
        after: usize,
        matches: &mut BTreeSet<usize>,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        let minimum_misses = self.radius + 1;
        for (band, bucket) in self.buckets.iter().enumerate() {
            let band_radius =
                minimum_misses / 4 + u32::from((band as u32) < minimum_misses % 4) - 1;
            let key = (hash >> (band * 16)) as u16;
            for mask in &self.flip_masks[band_radius as usize] {
                cancel.check()?;
                if let Some(candidates) = bucket.get(&(key ^ mask)) {
                    for candidate in candidates.iter().copied().filter(|index| *index > after) {
                        cancel.check()?;
                        if (self.hashes[candidate] ^ hash).count_ones() <= self.radius {
                            matches.insert(candidate);
                        }
                    }
                }
            }
        }
        Ok(())
    }
}
