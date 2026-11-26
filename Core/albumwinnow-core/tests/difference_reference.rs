use albumwinnow_core::{
    Cancellation, CoreError,
    difference::{self, Region, UnavailableReason},
    model::NormalizedPixels,
};
use serde_json::Value;
use std::{fs, path::PathBuf};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/CoreFixtures/difference")
}
fn pixels(name: &str) -> NormalizedPixels {
    NormalizedPixels {
        width: 256,
        height: 256,
        stride: 1024,
        rgba: fs::read(root().join(name)).unwrap(),
        decode_pipeline: "apple-reference-v1".into(),
    }
}
#[test]
fn matches_frozen_native_difference_results() {
    let reference: Value =
        serde_json::from_slice(&fs::read(root().join("reference.json")).unwrap()).unwrap();
    for case in reference["cases"].as_array().unwrap() {
        let dimensions = |prefix: &str| {
            (
                case[format!("{prefix}_width")].as_u64().unwrap() as u32,
                case[format!("{prefix}_height")].as_u64().unwrap() as u32,
            )
        };
        let result = difference::analyze(
            &pixels(case["first"].as_str().unwrap()),
            dimensions("first"),
            &pixels(case["second"].as_str().unwrap()),
            dimensions("second"),
            &Cancellation::default(),
        )
        .unwrap();
        let expected = match case["unavailable"].as_str() {
            Some("geometry") => Some(UnavailableReason::Geometry),
            Some("insufficientDetail") => Some(UnavailableReason::InsufficientDetail),
            Some("alignment") => Some(UnavailableReason::Alignment),
            None => None,
            _ => panic!("unexpected reference reason"),
        };
        assert_eq!(result.unavailable, expected, "{case}");
        let regions: Vec<Region> = case["regions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| Region {
                x: r["x"].as_f64().unwrap(),
                y: r["y"].as_f64().unwrap(),
                width: r["width"].as_f64().unwrap(),
                height: r["height"].as_f64().unwrap(),
            })
            .collect();
        assert_eq!(result.regions, regions, "{case}");
    }
}
#[test]
fn geometry_detail_invalid_input_and_cancel_are_distinct() {
    let valid = pixels("scene.png.rgba");
    let cancel = Cancellation::default();
    assert_eq!(
        difference::analyze(&valid, (512, 384), &valid, (512, 300), &cancel)
            .unwrap()
            .unavailable,
        Some(UnavailableReason::Geometry)
    );
    assert_eq!(
        difference::analyze(&valid, (32, 32), &valid, (32, 32), &cancel)
            .unwrap()
            .unavailable,
        Some(UnavailableReason::InsufficientDetail)
    );
    assert_eq!(
        difference::analyze(&valid, (0, 32), &valid, (32, 32), &cancel),
        Err(CoreError::InvalidValue)
    );
    let mut invalid = pixels("scene.png.rgba");
    invalid.rgba.pop();
    assert_eq!(
        difference::analyze(&invalid, (512, 384), &valid, (512, 384), &cancel),
        Err(CoreError::InvalidPixels)
    );
    cancel.cancel();
    assert_eq!(
        difference::analyze(&valid, (512, 384), &valid, (512, 384), &cancel),
        Err(CoreError::Cancelled)
    );
}

#[test]
fn active_difference_work_stops_within_cancellation_budget() {
    use std::{
        sync::{Arc, Barrier},
        time::{Duration, Instant},
    };
    let cancel = Arc::new(Cancellation::default());
    let barrier = Arc::new(Barrier::new(2));
    let pixels = pixels("detail-a.png.rgba");
    let worker_cancel = cancel.clone();
    let worker_barrier = barrier.clone();
    let worker = std::thread::spawn(move || {
        worker_barrier.wait();
        loop {
            match difference::analyze(&pixels, (512, 384), &pixels, (512, 384), &worker_cancel) {
                Err(CoreError::Cancelled) => break,
                Ok(_) => {}
                other => panic!("unexpected worker result: {other:?}"),
            }
        }
    });
    barrier.wait();
    std::thread::sleep(Duration::from_millis(2));
    let start = Instant::now();
    cancel.cancel();
    worker.join().unwrap();
    let latency = start.elapsed();
    println!("DIFFERENCE_CANCEL latency_us={}", latency.as_micros());
    assert!(latency < Duration::from_millis(500), "{latency:?}");
}
