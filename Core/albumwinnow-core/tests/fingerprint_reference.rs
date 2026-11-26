use albumwinnow_core::{
    Cancellation, CoreError, fingerprint::fingerprint, model::NormalizedPixels,
};
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/CoreFixtures")
}

#[test]
fn same_pixels_match_the_frozen_swift_reference() {
    let root = fixtures();
    let reference: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.join("swift-v1-fingerprints.json")).unwrap())
            .unwrap();
    let tolerance = reference["metric_absolute_tolerance"].as_f64().unwrap();
    for row in reference["images"].as_array().unwrap() {
        let name = row["name"].as_str().unwrap();
        let pixels = NormalizedPixels {
            width: 128,
            height: 128,
            stride: 512,
            rgba: std::fs::read(root.join(row["pixels"].as_str().unwrap())).unwrap(),
            decode_pipeline: "apple.imageio.v1.reference".into(),
        };
        let result = fingerprint(&pixels, &Cancellation::default()).unwrap();
        assert_eq!(
            result.perceptual_hash.to_string(),
            row["phash"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(
            result.difference_hash.to_string(),
            row["dhash"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(
            serde_json::json!(result.mean_rgba),
            row["mean_rgba"],
            "{name}"
        );
        assert!(
            (result.edge_detail - row["edge_detail"].as_f64().unwrap()).abs() <= tolerance,
            "{name}"
        );
    }
}

#[test]
fn invalid_pixels_are_rejected_before_accessing_buffers() {
    let cancel = Cancellation::default();
    for (width, height, stride, length) in [
        (0, 128, 512, 0),
        (128, 0, 512, 0),
        (128, 128, 511, 128 * 511),
        (128, 128, 512, 65535),
        (u32::MAX, u32::MAX, u32::MAX, 4),
        (2049, 1, 8196, 8196),
        (128, 128, u32::MAX, 4),
    ] {
        let pixels = NormalizedPixels {
            width,
            height,
            stride,
            rgba: vec![0; length],
            decode_pipeline: "reference".into(),
        };
        assert_eq!(fingerprint(&pixels, &cancel), Err(CoreError::InvalidPixels));
    }
}

#[test]
fn row_padding_is_excluded_and_cancellation_is_checked() {
    let packed = NormalizedPixels {
        width: 128,
        height: 128,
        stride: 512,
        rgba: std::fs::read(fixtures().join("scene.png.rgba")).unwrap(),
        decode_pipeline: "reference".into(),
    };
    let mut padded = NormalizedPixels {
        width: 128,
        height: 128,
        stride: 528,
        rgba: Vec::with_capacity(128 * 528),
        decode_pipeline: "reference".into(),
    };
    for row in packed.rgba.as_chunks::<512>().0 {
        padded.rgba.extend_from_slice(row);
        padded.rgba.extend_from_slice(&[199; 16]);
    }
    let cancel = Cancellation::default();
    assert_eq!(fingerprint(&packed, &cancel), fingerprint(&padded, &cancel));
    cancel.cancel();
    assert_eq!(fingerprint(&padded, &cancel), Err(CoreError::Cancelled));
}

#[test]
fn identity_metadata_and_date_validation_are_platform_independent() {
    use albumwinnow_core::model::{AssetId, ImageMetadata, validate_date};
    assert!(
        AssetId {
            source_id: "v2-source".into(),
            item_id: "opaque:照片/é".into()
        }
        .validate()
        .is_ok()
    );
    assert_eq!(
        AssetId {
            source_id: "".into(),
            item_id: "a".into()
        }
        .validate(),
        Err(CoreError::InvalidValue)
    );
    let valid = ImageMetadata {
        width: 15000,
        height: 10000,
        bit_depth: 16,
        wide_color: true,
        effective_orientation: 8,
    };
    assert!(valid.validate().is_ok());
    assert_eq!(
        ImageMetadata {
            width: 15001,
            ..valid.clone()
        }
        .validate(),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        ImageMetadata {
            effective_orientation: 0,
            ..valid
        }
        .validate(),
        Err(CoreError::InvalidValue)
    );
    for value in [None, Some(-0.25), Some(0.0)] {
        assert!(validate_date(value).is_ok());
    }
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(validate_date(Some(value)), Err(CoreError::InvalidValue));
    }
}

#[test]
fn scene_providers_require_complete_compatibility_namespaces() {
    use albumwinnow_core::model::SceneProvider;
    let apple = SceneProvider {
        provider_id: "apple.vision".into(),
        model_revision: "2".into(),
        preprocessing: "imageio.v1".into(),
        platform_compatibility: "ios26.arm64".into(),
    };
    assert!(apple.validate().is_ok());
    assert_eq!(
        SceneProvider {
            platform_compatibility: String::new(),
            ..apple
        }
        .validate(),
        Err(CoreError::InvalidValue)
    );
}
