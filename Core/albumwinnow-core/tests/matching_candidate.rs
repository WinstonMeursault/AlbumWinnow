use albumwinnow_core::{
    Cancellation, CoreError,
    candidate::CandidateIndex,
    fingerprint::FingerprintMetrics,
    matching::{self, Fingerprint, MatchKind},
    model::NormalizedPixels,
};

fn fingerprint(index: u64, p: u64, d: u64) -> Fingerprint {
    Fingerprint {
        file_hash: *blake3::hash(&index.to_le_bytes()).as_bytes(),
        width: 1000,
        height: 1000,
        bit_depth: 8,
        wide_color: false,
        metrics: FingerprintMetrics {
            perceptual_hash: p,
            difference_hash: d,
            mean_rgba: [128, 128, 128, 255],
            edge_detail: 0.0,
        },
    }
}

fn solid(value: u8) -> NormalizedPixels {
    NormalizedPixels {
        width: 128,
        height: 128,
        stride: 512,
        rgba: [value, value, value, 255].repeat(128 * 128),
        decode_pipeline: "test.srgb.premul.v1".into(),
    }
}

#[test]
fn visual_candidate_preserves_all_existing_boundaries() {
    let a = fingerprint(0, 0, 0);
    let mut b = fingerprint(1, (1 << 12) - 1, (1 << 11) - 1);
    assert!(matching::is_visual_candidate(&a, &b));
    b.metrics.perceptual_hash = (1 << 13) - 1;
    assert!(!matching::is_visual_candidate(&a, &b));
    b.metrics.difference_hash = (1 << 10) - 1;
    assert!(matching::is_visual_candidate(&a, &b));
    b.metrics.mean_rgba[0] = 133;
    assert!(matching::is_visual_candidate(&a, &b));
    b.metrics.mean_rgba[0] = 134;
    assert!(!matching::is_visual_candidate(&a, &b));
    b.metrics.mean_rgba[0] = 128;
    b.width = 1006;
    assert!(matching::is_visual_candidate(&a, &b));
    b.width = 1007;
    assert!(!matching::is_visual_candidate(&a, &b));
}

#[test]
fn candidate_buckets_equal_exhaustive_search_and_keep_sorted_order() {
    let cancel = Cancellation::default();
    let mut seed = 123456789_u64;
    let mut items = Vec::new();
    for i in 0..768 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        items.push(fingerprint(i, seed, seed.rotate_left(23)));
    }
    // Guaranteed neighbors in both hash families, including band-boundary bits.
    for bits in 0..=13 {
        items.push(fingerprint(
            1000 + bits,
            items[0].metrics.perceptual_hash ^ ((1 << bits) - 1),
            u64::MAX,
        ));
        items.push(fingerprint(
            2000 + bits,
            u64::MAX,
            items[0].metrics.difference_hash ^ ((1 << bits) - 1),
        ));
    }
    let mut exact = fingerprint(9999, u64::MAX, 0);
    exact.file_hash = items[0].file_hash;
    items.push(exact);
    let index = CandidateIndex::new(&items, &cancel).unwrap();
    for after in [0, 13, 100, 384, 767, items.len() - 1] {
        let a = &items[after];
        let expected: Vec<_> = items
            .iter()
            .enumerate()
            .filter(|(i, b)| {
                *i > after
                    && (a.file_hash == b.file_hash
                        || (a.metrics.perceptual_hash ^ b.metrics.perceptual_hash).count_ones()
                            <= 12
                        || (a.metrics.difference_hash ^ b.metrics.difference_hash).count_ones()
                            <= 10)
            })
            .map(|(i, _)| i)
            .collect();
        assert_eq!(index.candidates(a, after, &cancel).unwrap(), expected);
    }
    cancel.cancel();
    assert_eq!(
        index.candidates(&items[0], 0, &cancel),
        Err(CoreError::Cancelled)
    );
}

#[test]
fn multiscale_verification_preserves_mean_local_and_detail_semantics() {
    let cancel = Cancellation::default();
    let a = solid(128);
    assert!(matching::verify_pixels(&a, &solid(132), &cancel).unwrap());
    assert!(!matching::verify_pixels(&a, &solid(133), &cancel).unwrap());
    let mut patch = solid(128);
    for y in 0..8 {
        for x in 0..8 {
            for c in 0..3 {
                patch.rgba[(y * 128 + x) * 4 + c] = 145;
            }
        }
    }
    assert!(matching::verify_pixels(&a, &patch, &cancel).unwrap());
    for y in 0..8 {
        for x in 0..8 {
            for c in 0..3 {
                patch.rgba[(y * 128 + x) * 4 + c] = 146;
            }
        }
    }
    assert!(!matching::verify_pixels(&a, &patch, &cancel).unwrap());
    assert_eq!(
        matching::detail_match(&a, &patch, &cancel).unwrap(),
        MatchKind::SimilarPhoto
    );
    assert_eq!(
        matching::detail_match(&a, &a, &cancel).unwrap(),
        MatchKind::VisualDuplicate
    );
    cancel.cancel();
    assert_eq!(
        matching::verify_pixels(&a, &a, &cancel),
        Err(CoreError::Cancelled)
    );
}

#[test]
fn verification_rejects_malformed_or_excessive_grids() {
    let cancel = Cancellation::default();
    let a = solid(128);
    let mut b = solid(128);
    b.rgba.pop();
    assert_eq!(
        matching::verify_pixels(&a, &b, &cancel),
        Err(CoreError::InvalidPixels)
    );
    b = NormalizedPixels {
        width: 2048,
        height: 2048,
        stride: 8192,
        rgba: vec![0; 2048 * 2048 * 4],
        decode_pipeline: "test".into(),
    };
    assert_eq!(
        matching::verify_pixels(&b, &b, &cancel),
        Err(CoreError::InvalidPixels)
    );
}
