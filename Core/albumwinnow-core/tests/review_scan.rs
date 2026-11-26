use albumwinnow_core::{
    Cancellation, CoreError,
    fingerprint::FingerprintMetrics,
    matching::{Fingerprint, MatchKind},
    model::{AssetId, SceneProvider},
    review::{ReviewAsset, ReviewCollection, ReviewEvidence, SourceKind},
    review_scan::ScanReviewAsset,
    review_session::{ReviewSession, SourceInput},
    scan::{AssetValidation, ScanItem, ScanSession, TaskResult, VerificationOutcome},
    scene::SceneQuality,
    scene_session::{SceneAsset, SceneSession},
};
use std::{path::PathBuf, sync::Arc};

struct Scratch(PathBuf);
struct Fixture {
    root: Scratch,
    session: ReviewSession,
    items: Vec<ScanItem>,
    metadata: Vec<ScanReviewAsset>,
}
impl Fixture {
    fn new(scenes: bool) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "albumwinnow-handoff-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let mut session = ReviewSession::open(&root.join("review.sqlite"), false).unwrap();
        let source = session
            .register_source(
                1,
                SourceInput {
                    kind: SourceKind::ControlledTest,
                    namespace: "native.fixture.v2".into(),
                    identity: vec![1],
                    bookmark: vec![],
                    label: "Generated".into(),
                },
            )
            .unwrap();
        if scenes {
            let mut settings = session.settings().clone();
            settings.similar_scenes_enabled = true;
            session
                .save_settings(session.metadata().revision, settings)
                .unwrap();
        }
        let items: Vec<_> = [1, 1, 2, 3]
            .into_iter()
            .enumerate()
            .map(|(index, hash)| ScanItem {
                id: AssetId {
                    source_id: source.id.clone(),
                    item_id: index.to_string(),
                },
                revision: "ns-revision".into(),
                associated_resources: false,
                native_identity: None,
                fingerprint: Fingerprint {
                    file_hash: [hash; 32],
                    width: 100,
                    height: 100,
                    bit_depth: 8,
                    wide_color: false,
                    metrics: FingerprintMetrics {
                        perceptual_hash: 0,
                        difference_hash: 0,
                        mean_rgba: [128, 128, 128, 255],
                        edge_detail: 0.1,
                    },
                },
            })
            .collect();
        let metadata = items
            .iter()
            .map(|item| ScanReviewAsset {
                asset: ReviewAsset {
                    id: item.id.clone(),
                    name: format!("{}.png", item.id.item_id),
                    revision: item.revision.clone(),
                    kind: SourceKind::ControlledTest,
                    properties: None,
                    byte_count: Some(100),
                    capture_date: None,
                    burst: None,
                    native_identity: None,
                    link_count: None,
                },
                evidence: ReviewEvidence {
                    asset: item.id.clone(),
                    width: 100,
                    height: 100,
                    bit_depth: Some(8),
                    wide_color: false,
                    edge_detail: Some(0.1),
                    capture_date: Some(10.0),
                },
            })
            .collect();
        Self {
            root: Scratch(root),
            session,
            items,
            metadata,
        }
    }
    fn stage(&mut self, operation: &str) {
        self.session
            .begin_scan(self.session.metadata().revision, operation.into())
            .unwrap();
        self.session
            .append_scan_assets(operation, self.metadata.clone(), &Cancellation::default())
            .unwrap();
    }
    fn scan(&self, operation: &str, final_check: bool) -> ScanSession {
        let cancel = Cancellation::default();
        let sources = self
            .session
            .settings()
            .sides
            .as_ref()
            .map(|s| vec![s.first.clone(), s.second.clone()])
            .unwrap_or_else(|| vec![self.items[0].id.source_id.clone()]);
        let mut scan = ScanSession::new(
            operation.into(),
            sources,
            self.session.settings().sides.clone(),
            self.session.settings().preferred_source.clone(),
        )
        .unwrap();
        scan.append_prepared(self.items.clone(), &cancel).unwrap();
        scan.complete_preparation(&cancel).unwrap();
        loop {
            let batch = scan.next_batch(16, &cancel).unwrap();
            if batch.done {
                break;
            }
            let results = batch
                .tasks
                .into_iter()
                .map(|task| TaskResult {
                    task_id: task.task_id,
                    outcome: VerificationOutcome::Matched(if task.exact_identity {
                        MatchKind::ExactDuplicate
                    } else {
                        MatchKind::Distinct
                    }),
                })
                .collect();
            scan.submit_results(operation, batch.batch_id, results, &cancel)
                .unwrap();
        }
        if final_check {
            let ids = scan.final_validation_ids(&cancel).unwrap();
            scan.submit_final_validations(
                operation,
                ids.into_iter()
                    .map(|id| AssetValidation {
                        id,
                        accessible: true,
                        revision: Some("ns-revision".into()),
                    })
                    .collect(),
                &cancel,
            )
            .unwrap();
        }
        scan
    }
    fn scene(&self, operation: &str, members: &[usize], final_check: Option<bool>) -> SceneSession {
        let provider = SceneProvider {
            provider_id: "controlled.native".into(),
            model_revision: "2".into(),
            preprocessing: "fixed".into(),
            platform_compatibility: "fixture".into(),
        };
        let mut scene = SceneSession::new(
            operation.into(),
            provider.clone(),
            self.session
                .settings()
                .sides
                .as_ref()
                .map(|s| (s.first.clone(), s.second.clone())),
            self.session.settings().preferred_source.clone(),
            Arc::new(Cancellation::default()),
        )
        .unwrap();
        scene
            .append(
                members
                    .iter()
                    .map(|index| {
                        let item = &self.items[*index];
                        SceneAsset {
                            id: item.id.clone(),
                            revision: item.revision.clone(),
                            provider: provider.clone(),
                            quality: SceneQuality {
                                mean_luminance: 0.5,
                                texture_variance: 0.01,
                                focus_energy: 0.1,
                                dark_clipping: 0.0,
                                bright_clipping: 0.0,
                            },
                            keys: [0; 4],
                            width: 100,
                            height: 100,
                            bit_depth: 8,
                            wide_color: false,
                            edge_detail: 0.1,
                            associated_resources: false,
                            native_identity: None,
                            burst: None,
                            date: Some(10.0),
                        }
                    })
                    .collect(),
            )
            .unwrap();
        scene.complete_preparation().unwrap();
        while let Some(request) = scene.next_work().unwrap().request {
            scene.submit(operation, request.task_id, 0.1).unwrap();
        }
        if let Some(valid) = final_check {
            let ids = scene.final_validation_page(0, 16).unwrap();
            scene
                .submit_final_validations(
                    operation,
                    ids.into_iter()
                        .map(|id| AssetValidation {
                            id,
                            accessible: valid,
                            revision: Some("ns-revision".into()),
                        })
                        .collect(),
                )
                .unwrap();
        }
        scene
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn detection_commits_review_groups_without_host_group_roundtrip_and_reopens() {
    let mut f = Fixture::new(false);
    f.stage("scan");
    let scan = f.scan("scan", true);
    f.session
        .finish_detected_scan("scan", &scan, None, &Cancellation::default())
        .unwrap();
    let page = f.session.query_page(0, 256).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].kind, MatchKind::ExactDuplicate);
    let signature = page[0].signature.clone();
    let group = f.session.detail(&signature).unwrap().group;
    assert_eq!(
        group.members,
        f.metadata[..2]
            .iter()
            .map(|m| m.asset.clone())
            .collect::<Vec<_>>()
    );
    assert_eq!(
        group.evidence,
        f.metadata[..2]
            .iter()
            .map(|m| m.evidence.clone())
            .collect::<Vec<_>>()
    );
    let database = f.root.0.join("review.sqlite");
    drop(f.session);
    f.session = ReviewSession::open(&database, true).unwrap();
    assert_eq!(f.session.query_page(0, 1).unwrap()[0].signature, signature);
}

#[test]
fn incomplete_cancelled_stale_or_unbound_detection_never_changes_saved_review() {
    for case in [
        "unfinished",
        "cancelled",
        "wrong-operation",
        "metadata-revision",
        "missing-metadata",
        "changed-scope",
    ] {
        let mut f = Fixture::new(false);
        if case == "metadata-revision" {
            f.metadata[0].asset.revision = "new".into();
        }
        f.stage("scan");
        if case == "missing-metadata" {
            f.session.discard_scan("scan").unwrap();
            f.session
                .begin_scan(f.session.metadata().revision, "scan".into())
                .unwrap();
        }
        if case == "changed-scope" {
            let mut settings = f.session.settings().clone();
            settings.preferred_source = Some(f.items[0].id.source_id.clone());
            f.session
                .save_settings(f.session.metadata().revision, settings)
                .unwrap();
        }
        let scan = f.scan(
            if case == "wrong-operation" {
                "other"
            } else {
                "scan"
            },
            case != "unfinished",
        );
        let before = f.session.metadata().clone();
        let cancel = Cancellation::default();
        if case == "cancelled" {
            cancel.cancel();
        }
        assert!(
            f.session
                .finish_detected_scan("scan", &scan, None, &cancel)
                .is_err(),
            "{case}"
        );
        assert_eq!(f.session.metadata(), &before, "{case}");
        assert_eq!(f.session.query_count().unwrap(), 0, "{case}");
        assert!(f.session.healthy());
    }
}

#[test]
fn both_queues_preserve_native_scene_provider_quality_dates_and_real_edges() {
    let mut f = Fixture::new(true);
    f.stage("scan");
    let scan = f.scan("scan", true);
    let scenes = f.scene("scan", &[2, 3], Some(true));
    f.session
        .finish_detected_scan("scan", &scan, Some(&scenes), &Cancellation::default())
        .unwrap();
    assert_eq!(f.session.query_count().unwrap(), 1);
    let mut settings = f.session.settings().clone();
    settings.query.collection = ReviewCollection::SimilarScenes;
    f.session
        .save_settings(f.session.metadata().revision, settings)
        .unwrap();
    let page = f.session.query_page(0, 256).unwrap();
    assert_eq!(page.len(), 1);
    let group = f.session.detail(&page[0].signature).unwrap().group;
    assert_eq!(group.scene.as_ref().unwrap().model_revision, "2");
    assert_eq!(group.scene_quality.len(), 2);
    assert_eq!(group.scene_matches.len(), 1);
    assert_eq!(group.scene_matches[0].distance, 0.1);
    assert_eq!(group.evidence[0].capture_date, Some(10.0));
    assert!(!group.has_quality_recommendation);
    assert_eq!(group.actual_edges().len(), 1);
}

#[test]
fn scene_publication_requires_final_facts_and_matching_operation_with_no_duplicate_overlap() {
    for case in [
        "unvalidated",
        "changed",
        "wrong-operation",
        "duplicate-overlap",
    ] {
        let mut f = Fixture::new(true);
        f.stage("scan");
        let scan = f.scan("scan", true);
        let scenes = f.scene(
            if case == "wrong-operation" {
                "other"
            } else {
                "scan"
            },
            if case == "duplicate-overlap" {
                &[0, 1]
            } else {
                &[2, 3]
            },
            match case {
                "unvalidated" => None,
                "changed" => Some(false),
                _ => Some(true),
            },
        );
        let before = f.session.metadata().clone();
        assert!(
            f.session
                .finish_detected_scan("scan", &scan, Some(&scenes), &Cancellation::default())
                .is_err(),
            "{case}"
        );
        assert_eq!(f.session.metadata(), &before);
        assert_eq!(f.session.query_count().unwrap(), 0);
    }
}

#[test]
fn native_metadata_batches_are_bounded_atomic_and_cannot_mix_group_imports() {
    let mut f = Fixture::new(false);
    f.session
        .begin_scan(f.session.metadata().revision, "scan".into())
        .unwrap();
    let cancel = Cancellation::default();
    let cancelled = Cancellation::default();
    cancelled.cancel();
    assert_eq!(
        f.session
            .append_scan_assets("scan", f.metadata.clone(), &cancelled),
        Err(CoreError::Cancelled)
    );
    let mut wrong_kind = f.metadata[0].clone();
    wrong_kind.asset.kind = SourceKind::PhotoLibrary;
    assert_eq!(
        f.session
            .append_scan_assets("scan", vec![wrong_kind], &cancel),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        f.session
            .append_scan_assets("scan", vec![f.metadata[0].clone(); 17], &cancel),
        Err(CoreError::InvalidBuffer)
    );
    assert_eq!(
        f.session
            .append_scan_assets("scan", vec![f.metadata[0].clone(); 2], &cancel),
        Err(CoreError::InvalidValue)
    );
    f.session
        .append_scan_assets("scan", f.metadata.clone(), &cancel)
        .unwrap();
    assert_eq!(
        f.session.append_scan_groups("scan", vec![]),
        Err(CoreError::InvalidState)
    );
    assert_eq!(f.session.finish_scan("scan"), Err(CoreError::InvalidState));
    let scan = f.scan("scan", true);
    f.session
        .finish_detected_scan("scan", &scan, None, &cancel)
        .unwrap();
    assert_eq!(f.session.query_count().unwrap(), 1);
}

#[test]
fn unavailable_active_source_can_be_absent_but_unregistered_source_cannot_publish() {
    let mut f = Fixture::new(false);
    f.session
        .register_source(
            f.session.metadata().revision,
            SourceInput {
                kind: SourceKind::ControlledTest,
                namespace: "native.fixture.v2".into(),
                identity: vec![2],
                bookmark: vec![],
                label: "Unavailable".into(),
            },
        )
        .unwrap();
    f.stage("scan");
    let scan = f.scan("scan", true);
    f.session
        .finish_detected_scan("scan", &scan, None, &Cancellation::default())
        .unwrap();
    assert_eq!(f.session.query_count().unwrap(), 1);
    f.session
        .begin_scan(f.session.metadata().revision, "new".into())
        .unwrap();
    let mut foreign =
        ScanSession::new("new".into(), vec!["unregistered".into()], None, None).unwrap();
    foreign
        .complete_preparation(&Cancellation::default())
        .unwrap();
    foreign.next_batch(16, &Cancellation::default()).unwrap();
    assert_eq!(
        f.session
            .finish_detected_scan("new", &foreign, None, &Cancellation::default()),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(f.session.query_count().unwrap(), 1);
}

#[test]
fn scene_final_fact_batches_are_atomic_bounded_and_replays_cannot_repair_a_failed_check() {
    let f = Fixture::new(true);
    let mut scenes = f.scene("scan", &[2, 3], None);
    assert_eq!(
        scenes.final_validation_page(0, 17),
        Err(CoreError::InvalidBuffer)
    );
    let ids = scenes.final_validation_page(0, 16).unwrap();
    assert_eq!(ids.len(), 2);
    let fact = |id, accessible| AssetValidation {
        id,
        accessible,
        revision: Some("ns-revision".into()),
    };
    let mut foreign = ids[0].clone();
    foreign.item_id = "foreign".into();
    assert_eq!(
        scenes.submit_final_validations(
            "scan",
            vec![fact(ids[0].clone(), true), fact(foreign, true)]
        ),
        Err(CoreError::InvalidValue)
    );
    scenes
        .submit_final_validations(
            "scan",
            vec![fact(ids[0].clone(), false), fact(ids[1].clone(), true)],
        )
        .unwrap();
    assert_eq!(
        scenes.submit_final_validations("scan", vec![fact(ids[0].clone(), true)]),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        scenes.submit_final_validations("late", vec![]),
        Err(CoreError::StaleOperation)
    );
}

#[test]
fn cross_side_handoff_keeps_only_real_cross_edges_in_both_queues() {
    for scenes_enabled in [false, true] {
        let mut f = Fixture::new(scenes_enabled);
        let right = f
            .session
            .register_source(
                f.session.metadata().revision,
                SourceInput {
                    kind: SourceKind::ControlledTest,
                    namespace: "native.fixture.v2".into(),
                    identity: vec![2],
                    bookmark: vec![],
                    label: "Right".into(),
                },
            )
            .unwrap();
        for index in 0..4 {
            f.items[index].fingerprint.file_hash =
                [if scenes_enabled { index as u8 } else { 1 }; 32];
            if index >= 2 {
                f.items[index].id.source_id = right.id.clone();
                f.metadata[index].asset.id = f.items[index].id.clone();
                f.metadata[index].evidence.asset = f.items[index].id.clone();
            }
        }
        let sides = albumwinnow_core::scan::ComparisonSides {
            first: f.items[0].id.source_id.clone(),
            second: right.id.clone(),
        };
        let mut settings = f.session.settings().clone();
        settings.sides = Some(sides.clone());
        settings.preferred_source = Some(right.id);
        if scenes_enabled {
            settings.query.collection = ReviewCollection::SimilarScenes;
        }
        f.session
            .save_settings(f.session.metadata().revision, settings)
            .unwrap();
        f.stage("scan");
        let scan = f.scan("scan", true);
        let scenes = scenes_enabled.then(|| f.scene("scan", &[0, 1, 2, 3], Some(true)));
        f.session
            .finish_detected_scan("scan", &scan, scenes.as_ref(), &Cancellation::default())
            .unwrap();
        let page = f.session.query_page(0, 256).unwrap();
        assert_eq!(page.len(), 1);
        let group = f.session.detail(&page[0].signature).unwrap().group;
        assert_eq!(group.sides, Some(sides));
        assert_eq!(group.members.len(), if scenes_enabled { 3 } else { 4 });
        assert_eq!(
            group.actual_edges().len(),
            if scenes_enabled { 2 } else { 3 }
        );
        assert!(
            group
                .actual_edges()
                .iter()
                .all(|e| e.first.source_id != e.second.source_id)
        );
        assert_eq!(
            group
                .duplicates
                .iter()
                .any(|(_, kind)| *kind == MatchKind::Distinct),
            !scenes_enabled
        );
        assert_eq!(
            group.scene_matches.len(),
            if scenes_enabled { 2 } else { 0 }
        );
    }
}
