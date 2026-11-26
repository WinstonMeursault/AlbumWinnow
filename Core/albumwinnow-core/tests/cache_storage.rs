use albumwinnow_core::{
    Cancellation, CoreError,
    cache::{CacheStore, CachedFingerprint, CachedScene, PreparedCacheEntry},
    fingerprint::FingerprintMetrics,
    matching::Fingerprint,
    model::{AssetId, SceneProvider},
    scene::SceneQuality,
};
use rusqlite::{Connection, params};
use std::{collections::HashSet, path::PathBuf};
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "albumwinnow-v2-cache-{}-{stamp}-{sequence}",
            std::process::id()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn cache(&self) -> PathBuf {
        self.0.join("v2/scan.sqlite")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn id(item: &str) -> AssetId {
    AssetId {
        source_id: "opaque-source".into(),
        item_id: item.into(),
    }
}
fn entry(item: &str) -> PreparedCacheEntry {
    PreparedCacheEntry {
        metadata: CachedFingerprint {
            id: id(item),
            revision: "nanosecond-revision".into(),
            fingerprint: Fingerprint {
                file_hash: [7; 32],
                width: 512,
                height: 384,
                bit_depth: 8,
                wide_color: false,
                metrics: FingerprintMetrics {
                    perceptual_hash: 42,
                    difference_hash: 123,
                    mean_rgba: [1, 2, 3, 255],
                    edge_detail: 0.2,
                },
            },
            observed_bit_depth: Some(8),
            capture_date: Some(1795000000.123),
        },
        sample: (0..65536).map(|i| (i % 251) as u8).collect(),
    }
}
fn provider() -> SceneProvider {
    SceneProvider {
        provider_id: "controlled".into(),
        model_revision: "1".into(),
        preprocessing: "fixed".into(),
        platform_compatibility: "test-only".into(),
    }
}
fn scene() -> CachedScene {
    CachedScene {
        provider: provider(),
        quality: SceneQuality {
            mean_luminance: 0.5,
            texture_variance: 0.1,
            focus_energy: 0.01,
            dark_clipping: 0.0,
            bright_clipping: 0.0,
        },
        archive: vec![1, 2, 3],
    }
}
const PIPELINE: &str = "test-decode.1";
#[test]
fn v2_cache_roundtrip_checks_revision_pipeline_and_provider() {
    let scratch = Scratch::new();
    let cancel = Cancellation::default();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    cache.store(vec![entry("a")], PIPELINE, &cancel).unwrap();
    cache
        .store_scene(&id("a"), "nanosecond-revision", scene())
        .unwrap();
    drop(cache);
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let values = cache
        .signatures("opaque-source", PIPELINE, &cancel)
        .unwrap();
    assert_eq!(values.len(), 1);
    assert_eq!(values[0].capture_date, entry("a").metadata.capture_date);
    assert_eq!(
        values[0].fingerprint.metrics,
        entry("a").metadata.fingerprint.metrics
    );
    assert_eq!(
        cache
            .sample(&id("a"), "nanosecond-revision", PIPELINE)
            .unwrap(),
        Some(entry("a").sample)
    );
    assert!(
        cache
            .sample(&id("a"), "changed", PIPELINE)
            .unwrap()
            .is_none()
    );
    assert!(
        cache
            .signatures("opaque-source", "other-decode", &cancel)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        cache
            .scene(&id("a"), "nanosecond-revision", &provider())
            .unwrap()
            .unwrap()
            .archive,
        vec![1, 2, 3]
    );
    let mut incompatible = provider();
    incompatible.platform_compatibility = "other-os".into();
    assert!(
        cache
            .scene(&id("a"), "nanosecond-revision", &incompatible)
            .unwrap()
            .is_none()
    );
    assert!(
        cache
            .scene(&id("a"), "nanosecond-revision", &provider())
            .unwrap()
            .is_some()
    );
}
#[test]
fn corrupted_records_are_dropped_without_reusing_or_erasing_good_entries() {
    let scratch = Scratch::new();
    let cancel = Cancellation::default();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    cache
        .store(
            vec![entry("good"), entry("bad"), entry("oversized")],
            PIPELINE,
            &cancel,
        )
        .unwrap();
    assert_eq!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        3
    );
    let db = Connection::open(scratch.cache()).unwrap();
    db.execute(
        "UPDATE fingerprints SET sample=?1 WHERE item='bad'",
        params![vec![255_u8; 32]],
    )
    .unwrap();
    db.execute(
        "UPDATE fingerprints SET sample=zeroblob(1000000) WHERE item='oversized'",
        [],
    )
    .unwrap();
    let values = cache
        .signatures("opaque-source", PIPELINE, &cancel)
        .unwrap();
    assert_eq!(values.len(), 1);
    assert_eq!(values[0].id, id("good"));
    assert_eq!(
        db.query_row::<i64, _, _>("SELECT count(*) FROM fingerprints", [], |r| r.get(0))
            .unwrap(),
        1
    );
    cache
        .store_scene(&id("good"), "nanosecond-revision", scene())
        .unwrap();
    db.execute("UPDATE scene_features SET revision='other'", [])
        .unwrap();
    assert!(
        cache
            .scene(&id("good"), "other", &provider())
            .unwrap()
            .is_none()
    );
    assert!(
        cache
            .sample(&id("good"), "nanosecond-revision", PIPELINE)
            .unwrap()
            .is_some()
    );
}
#[test]
fn invalid_and_cancelled_batches_never_leave_partial_entries() {
    let scratch = Scratch::new();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let cancel = Cancellation::default();
    let mut invalid = entry("bad");
    invalid.sample.pop();
    assert_eq!(
        cache.store(vec![entry("good"), invalid], PIPELINE, &cancel),
        Err(CoreError::InvalidPixels)
    );
    let mut invalid = entry("bad");
    invalid.metadata.capture_date = Some(f64::NAN);
    assert_eq!(
        cache.store(vec![invalid], PIPELINE, &cancel),
        Err(CoreError::InvalidValue)
    );
    assert!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .is_empty()
    );
    let db = Connection::open(scratch.cache()).unwrap();
    db.execute_batch("CREATE TRIGGER injected_write_failure BEFORE INSERT ON fingerprints WHEN NEW.item='fail' BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert_eq!(
        cache.store(vec![entry("good"), entry("fail")], PIPELINE, &cancel),
        Err(CoreError::WriteFailed)
    );
    assert!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .is_empty()
    );
    let cancelled = Cancellation::default();
    cancelled.cancel();
    assert_eq!(
        cache.store(vec![entry("good")], PIPELINE, &cancelled),
        Err(CoreError::Cancelled)
    );
}
#[test]
fn only_successful_finish_prunes_and_clear_does_not_touch_review_database() {
    let scratch = Scratch::new();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let cancel = Cancellation::default();
    let review = scratch.0.join("v2/review.sqlite");
    std::fs::write(&review, b"independent protection data").unwrap();
    cache
        .store(vec![entry("keep"), entry("gone")], PIPELINE, &cancel)
        .unwrap();
    cache
        .store_scene(&id("gone"), "nanosecond-revision", scene())
        .unwrap();
    let cancelled = Cancellation::default();
    cancelled.cancel();
    assert_eq!(
        cache.finish(&HashSet::new(), &HashSet::new(), &cancelled),
        Err(CoreError::Cancelled)
    );
    assert_eq!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        2
    );
    cache
        .finish(
            &HashSet::from([id("keep")]),
            &HashSet::from(["opaque-source".into()]),
            &cancel,
        )
        .unwrap();
    assert_eq!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        1
    );
    assert!(
        cache
            .scene(&id("gone"), "nanosecond-revision", &provider())
            .unwrap()
            .is_none()
    );
    cache.clear().unwrap();
    assert!(
        cache
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        std::fs::read(review).unwrap(),
        b"independent protection data"
    );
}
#[test]
fn corrupt_cache_rebuilds_but_foreign_and_unknown_schemas_are_preserved() {
    let scratch = Scratch::new();
    std::fs::create_dir_all(scratch.cache().parent().unwrap()).unwrap();
    std::fs::write(scratch.cache(), b"not a sqlite database").unwrap();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    assert!(
        cache
            .signatures("opaque-source", PIPELINE, &Cancellation::default())
            .unwrap()
            .is_empty()
    );
    drop(cache);
    let quarantined = std::fs::read_dir(scratch.cache().parent().unwrap())
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("scan.sqlite.corrupt-")
        })
        .unwrap();
    assert_eq!(
        std::fs::read(quarantined.path()).unwrap(),
        b"not a sqlite database"
    );
    let foreign = scratch.0.join("v1.sqlite");
    let db = Connection::open(&foreign).unwrap();
    db.execute_batch(
        "CREATE TABLE old_only(value TEXT); INSERT INTO old_only VALUES ('untouched');",
    )
    .unwrap();
    drop(db);
    let before = std::fs::read(&foreign).unwrap();
    assert!(matches!(
        CacheStore::open(&foreign),
        Err(CoreError::UnsupportedSchema)
    ));
    assert_eq!(std::fs::read(&foreign).unwrap(), before);
    let db = Connection::open(scratch.cache()).unwrap();
    db.pragma_update(None, "user_version", 999).unwrap();
    drop(db);
    assert!(matches!(
        CacheStore::open(&scratch.cache()),
        Err(CoreError::UnsupportedSchema)
    ));
    let db = Connection::open(scratch.cache()).unwrap();
    assert_eq!(
        db.pragma_query_value::<i32, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        999
    );
}

#[test]
fn cached_continuous_metrics_preserve_float_bits_at_native_scene_values() {
    let scratch = Scratch::new();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let mut original = scene();
    original.quality = SceneQuality {
        mean_luminance: 0.4545033492742781,
        texture_variance: 0.00894679079938009,
        focus_energy: 0.0009076552903882263,
        dark_clipping: 0.0003662109375,
        bright_clipping: 0.0,
    };
    cache
        .store_scene(&id("native"), "r", original.clone())
        .unwrap();
    let restored = cache
        .scene(&id("native"), "r", &provider())
        .unwrap()
        .unwrap();
    assert_eq!(restored.quality, original.quality);
    let mut fingerprint = entry("native");
    fingerprint.metadata.fingerprint.metrics.edge_detail = 429.4753860339191;
    let expected = fingerprint
        .metadata
        .fingerprint
        .metrics
        .edge_detail
        .to_bits();
    cache
        .store(vec![fingerprint], PIPELINE, &Cancellation::default())
        .unwrap();
    assert_eq!(
        cache
            .signatures("opaque-source", PIPELINE, &Cancellation::default())
            .unwrap()[0]
            .fingerprint
            .metrics
            .edge_detail
            .to_bits(),
        expected
    );
}

#[test]
fn validated_metadata_observes_external_commits_and_pipeline_replacement() {
    let scratch = Scratch::new();
    let cancel = Cancellation::default();
    let mut first = CacheStore::open(&scratch.cache()).unwrap();
    assert!(
        first
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .is_empty()
    );
    first.store(vec![entry("a")], PIPELINE, &cancel).unwrap();
    assert_eq!(
        first
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        1
    );
    let mut second = CacheStore::open(&scratch.cache()).unwrap();
    second.store(vec![entry("b")], PIPELINE, &cancel).unwrap();
    assert_eq!(
        first
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        2
    );
    first
        .store(vec![entry("a")], "other-pipeline", &cancel)
        .unwrap();
    assert_eq!(
        first
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        first
            .signatures("opaque-source", "other-pipeline", &cancel)
            .unwrap()
            .len(),
        1
    );
    let db = Connection::open(scratch.cache()).unwrap();
    db.execute("UPDATE fingerprints SET metadata=X'00' WHERE item='b'", [])
        .unwrap();
    assert!(
        first
            .signatures("opaque-source", PIPELINE, &cancel)
            .unwrap()
            .is_empty()
    );
    first.clear().unwrap();
    assert!(
        first
            .signatures("opaque-source", "other-pipeline", &cancel)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn signature_pages_are_bounded_complete_ordered_and_cancellable() {
    let scratch = Scratch::new();
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let cancel = Cancellation::default();
    for start in (0..273).step_by(16) {
        cache
            .store(
                (start..(start + 16).min(273))
                    .map(|i| entry(&format!("{i:04}")))
                    .collect(),
                PIPELINE,
                &cancel,
            )
            .unwrap();
    }
    // Reopen so the first page must validate the on-disk records too.
    drop(cache);
    let mut cache = CacheStore::open(&scratch.cache()).unwrap();
    let first = cache
        .signatures_page("opaque-source", PIPELINE, 0, 256, &cancel)
        .unwrap();
    let last = cache
        .signatures_page("opaque-source", PIPELINE, 256, 256, &cancel)
        .unwrap();
    assert_eq!(first.len(), 256);
    assert_eq!(last.len(), 17);
    let actual: Vec<_> = first
        .into_iter()
        .chain(last)
        .map(|e| e.id.item_id)
        .collect();
    assert_eq!(
        actual,
        (0..273).map(|i| format!("{i:04}")).collect::<Vec<_>>()
    );
    assert!(
        cache
            .signatures_page("opaque-source", PIPELINE, u64::MAX, 256, &cancel)
            .unwrap()
            .is_empty()
    );
    for limit in [0, 257, u32::MAX] {
        assert!(matches!(
            cache.signatures_page("opaque-source", PIPELINE, 0, limit, &cancel),
            Err(CoreError::InvalidBuffer)
        ));
    }
    cancel.cancel();
    assert!(matches!(
        cache.signatures_page("opaque-source", PIPELINE, 256, 16, &cancel),
        Err(CoreError::Cancelled)
    ));
}
