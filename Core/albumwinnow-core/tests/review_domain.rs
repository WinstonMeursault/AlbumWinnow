use albumwinnow_core::{
    CoreError,
    matching::MatchKind,
    model::AssetId,
    review::{
        ProtectionState, ReadOnlyPolicy, ReviewAsset, ReviewCollection, ReviewDecision,
        ReviewGroup, ReviewQuery, ReviewStatus, SourceKind, StatusFilter,
    },
    signature::SignatureEdge,
};
fn id(item: &str) -> AssetId {
    AssetId {
        source_id: "opaque-source".into(),
        item_id: item.into(),
    }
}
fn asset(item: &str) -> ReviewAsset {
    ReviewAsset {
        id: id(item),
        name: item.into(),
        revision: "r1".into(),
        kind: SourceKind::ControlledTest,
        properties: None,
        byte_count: Some(100),
        capture_date: None,
        burst: None,
        native_identity: None,
        link_count: None,
    }
}
fn group() -> ReviewGroup {
    ReviewGroup {
        preferred: id("a"),
        members: vec![asset("a"), asset("b"), asset("c")],
        duplicates: vec![
            (id("b"), MatchKind::ExactDuplicate),
            (id("c"), MatchKind::ExactDuplicate),
        ],
        edges: None,
        sides: None,
        scene: None,
        recommendation: None,
        has_quality_recommendation: true,
        scene_recommendation_reason: None,
        scene_quality: vec![],
        scene_matches: vec![],
        evidence: Vec::new(),
    }
}
#[test]
fn exact_groups_allow_a_manual_representative_but_never_delete_its_native_alias() {
    let mut group = group();
    group.members[0].native_identity = Some("native:one".into());
    group.members[1].native_identity = Some("native:one".into());
    group.members[2].native_identity = Some("native:two".into());
    let decision =
        ReviewDecision::confirm(&group, Some(id("b")), false, &ProtectionState::default()).unwrap();
    assert_eq!(decision.keep, Some(id("b")));
    assert_eq!(
        decision.removals.into_iter().collect::<Vec<_>>(),
        vec![id("c")]
    );
}
#[test]
fn approximate_groups_require_real_edges_to_actual_retained_members() {
    let mut group = group();
    group.members.push(asset("d"));
    group.duplicates = vec![
        (id("b"), MatchKind::SimilarPhoto),
        (id("c"), MatchKind::Distinct),
        (id("d"), MatchKind::Distinct),
    ];
    group.edges = Some(vec![
        SignatureEdge {
            first: id("a"),
            second: id("b"),
            kind: MatchKind::SimilarPhoto,
        },
        SignatureEdge {
            first: id("b"),
            second: id("c"),
            kind: MatchKind::SimilarPhoto,
        },
        SignatureEdge {
            first: id("c"),
            second: id("d"),
            kind: MatchKind::SimilarPhoto,
        },
    ]);
    let protection = ProtectionState::new(vec![asset("b")], vec![]).unwrap();
    assert_eq!(
        group.removal_pairs(&id("a"), &protection),
        vec![(id("b"), id("c"))]
    );
    let decision = ReviewDecision::confirm(&group, Some(id("a")), false, &protection).unwrap();
    assert_eq!(
        decision.removals.into_iter().collect::<Vec<_>>(),
        vec![id("c")]
    );
}
#[test]
fn lock_and_read_only_changes_trim_candidates_without_reviving_them_on_unlock() {
    let group = group();
    let base = ProtectionState::default();
    let mut decision = ReviewDecision::confirm(&group, Some(id("a")), false, &base).unwrap();
    let locked = base.setting_lock(asset("b"), true).unwrap();
    decision.prune(&group, &locked);
    assert!(!decision.removals.contains(&id("b")));
    assert!(decision.removals.contains(&id("c")));
    let unlocked = locked.setting_lock(asset("b"), false).unwrap();
    decision.prune(&group, &unlocked);
    assert!(!decision.removals.contains(&id("b")));
    let policy = ReadOnlyPolicy {
        source_id: "opaque-source".into(),
        kind: SourceKind::ControlledTest,
        snapshot_complete: true,
        members: group.members.clone(),
    };
    let read_only = unlocked
        .setting_read_only("opaque-source", Some(policy))
        .unwrap();
    decision.prune(&group, &read_only);
    assert!(decision.removals.is_empty());
    let writable = read_only.setting_read_only("opaque-source", None).unwrap();
    decision.prune(&group, &writable);
    assert!(decision.removals.is_empty());
}
#[test]
fn delete_all_is_atomic_and_associated_resources_are_protected() {
    let mut group = group();
    let base = ProtectionState::default();
    let mut decision = ReviewDecision::confirm(&group, None, true, &base).unwrap();
    assert_eq!(decision.removals.len(), 3);
    let locked = base.setting_lock(asset("b"), true).unwrap();
    decision.prune(&group, &locked);
    assert_eq!(decision, ReviewDecision::default());
    assert_eq!(
        ReviewDecision::confirm(&group, None, true, &locked),
        Err(CoreError::ProtectionUnavailable)
    );
    group.members[1].properties = Some(1);
    assert_eq!(
        ReviewDecision::confirm(&group, None, true, &base),
        Err(CoreError::ProtectionUnavailable)
    );
}
#[test]
fn native_aliases_and_unknown_filesystem_protection_fail_closed_without_path_parsing() {
    let mut original = asset("opaque|original");
    original.kind = SourceKind::FileSystem;
    original.native_identity = Some("darwin.file:opaque".into());
    original.link_count = Some(1);
    let mut alias = original.clone();
    alias.id = id("arbitrary:alias");
    alias.id.source_id = "another-opaque-source".into();
    let protection = ProtectionState::new(vec![original.clone()], vec![]).unwrap();
    assert!(protection.protected(&alias));
    assert_eq!(protection.lock_owners(&alias), vec![original.id]);
    let mut unknown = alias.clone();
    unknown.native_identity = None;
    assert!(ProtectionState::default().protected(&unknown));
    let incomplete = ReadOnlyPolicy {
        source_id: "unavailable-root".into(),
        kind: SourceKind::FileSystem,
        snapshot_complete: false,
        members: vec![],
    };
    let protection = ProtectionState::new(vec![], vec![incomplete]).unwrap();
    assert!(protection.protected(&alias));
    let mut photo = asset("photo");
    photo.kind = SourceKind::PhotoLibrary;
    assert!(!protection.protected(&photo));
}
#[test]
fn queries_preserve_collections_statuses_and_source_selection() {
    let group = group();
    let mut query = ReviewQuery::default();
    assert!(query.includes(&group, ReviewStatus::Pending));
    assert!(!query.includes(&group, ReviewStatus::Kept));
    query.status = StatusFilter::All;
    assert!(query.includes(&group, ReviewStatus::Kept));
    query.source = Some("missing".into());
    assert!(!query.includes(&group, ReviewStatus::Pending));
    query.source = None;
    query.collection = ReviewCollection::SimilarScenes;
    assert!(!query.includes(&group, ReviewStatus::Pending));
}
#[test]
fn malformed_domain_inputs_cannot_produce_a_decision() {
    let mut bad = group();
    bad.members[0].capture_date = Some(f64::NAN);
    assert_eq!(bad.validate(), Err(CoreError::InvalidValue));
    let mut bad = group();
    bad.members[0].properties = Some(8);
    assert_eq!(bad.validate(), Err(CoreError::InvalidValue));
    let group = group();
    assert_eq!(
        ReviewDecision::confirm(
            &group,
            Some(id("unknown")),
            false,
            &ProtectionState::default()
        ),
        Err(CoreError::InvalidValue)
    );
}

#[test]
fn date_bounds_and_nil_vs_empty_album_scope_are_preserved() {
    use albumwinnow_core::review::{CaptureRange, PhotoScope};
    use std::collections::BTreeMap;
    let range = CaptureRange {
        start: 100.0,
        end: 200.0,
        includes_unknown: false,
    };
    assert!(range.contains(Some(100.0)).unwrap());
    assert!(!range.contains(Some(200.0)).unwrap());
    assert!(!range.contains(None).unwrap());
    assert_eq!(range.contains(Some(f64::NAN)), Err(CoreError::InvalidValue));
    let empty = PhotoScope {
        albums: Some(BTreeMap::new()),
        dates: Some(range),
    };
    let all = PhotoScope::default();
    assert_ne!(
        serde_json::to_vec(&empty).unwrap(),
        serde_json::to_vec(&all).unwrap()
    );
    let restored: PhotoScope =
        serde_json::from_slice(&serde_json::to_vec(&empty).unwrap()).unwrap();
    assert_eq!(restored, empty);
}

#[test]
fn read_only_snapshots_reject_duplicate_members_and_mismatched_native_kinds() {
    let policy = ReadOnlyPolicy {
        source_id: "opaque-source".into(),
        kind: SourceKind::ControlledTest,
        snapshot_complete: true,
        members: vec![asset("a"), asset("a")],
    };
    assert!(matches!(
        ProtectionState::new(vec![], vec![policy.clone()]),
        Err(CoreError::InvalidValue)
    ));
    let mut wrong_kind = policy;
    wrong_kind.members.truncate(1);
    wrong_kind.kind = SourceKind::FileSystem;
    assert!(matches!(
        ProtectionState::new(vec![], vec![wrong_kind]),
        Err(CoreError::InvalidValue)
    ));
}

#[test]
fn size_estimates_distinguish_unknown_zero_overflow_and_manual_authority() {
    let mut group = group();
    group.members[1].byte_count = None;
    group.members[2].byte_count = Some(i64::MAX as u64);
    let protection = ProtectionState::default();
    let estimate = group.size_estimate(&group.estimated_removals(None, &protection));
    assert_eq!(estimate.known_count, 1);
    assert_eq!(estimate.unknown_count, 1);
    assert_eq!(estimate.known_bytes, i64::MAX as u64);
    assert!(!estimate.overflowed);
    let mut pending = ReviewDecision::default();
    assert_eq!(
        group.estimated_removals(Some(&pending), &protection).len(),
        2
    );
    pending.status = ReviewStatus::Kept;
    assert!(
        group
            .estimated_removals(Some(&pending), &protection)
            .is_empty()
    );
    pending = ReviewDecision::confirm(&group, None, true, &protection).unwrap();
    let total = group.size_estimate(&pending.removals);
    assert!(total.overflowed);
    assert_eq!(total.known_bytes, i64::MAX as u64);
    assert_eq!(pending.removals.len(), 3);
    group.has_quality_recommendation = false;
    assert!(group.estimated_removals(None, &protection).is_empty());
    assert_eq!(
        group.estimated_removals(Some(&pending), &protection).len(),
        3
    );
}
#[test]
fn reasons_preserve_evidence_precedence_and_partial_metadata_rules() {
    use albumwinnow_core::review::{RecommendationReason::*, ReviewEvidence};
    let mut group = group();
    assert_eq!(group.recommendation_reasons(), vec![NoQualityAdvantage]);
    group.evidence = group
        .members
        .iter()
        .enumerate()
        .map(|(i, asset)| ReviewEvidence {
            asset: asset.id.clone(),
            width: if i == 0 { 200 } else { 100 },
            height: 100,
            bit_depth: Some(if i == 0 { 10 } else { 8 }),
            wide_color: i == 0,
            edge_detail: Some(if i == 0 { 0.8 } else { 0.2 }),
            capture_date: None,
        })
        .collect();
    assert_eq!(
        group.recommendation_reasons(),
        vec![HigherResolution, HigherBitDepth, WideColor]
    );
    for e in &mut group.evidence {
        e.width = 100;
        e.bit_depth = None;
        e.wide_color = false;
    }
    assert_eq!(group.recommendation_reasons(), vec![EdgeContrast]);
    group.evidence[1].edge_detail = None;
    assert_eq!(group.recommendation_reasons(), vec![NoQualityAdvantage]);
    group.recommendation = Some(id("a"));
    group.members[0].properties = Some(1);
    assert_eq!(
        group.recommendation_reasons(),
        vec![SourcePreference, AssociatedResources]
    );
}
#[test]
fn latest_date_falls_back_to_evidence_and_keeps_unknown_explicit() {
    use albumwinnow_core::review::ReviewEvidence;
    let mut group = group();
    assert_eq!(group.latest_date(), None);
    group.members[0].capture_date = Some(5.0);
    group.evidence = vec![
        ReviewEvidence {
            asset: id("a"),
            width: 1,
            height: 1,
            bit_depth: None,
            wide_color: false,
            edge_detail: None,
            capture_date: Some(100.0),
        },
        ReviewEvidence {
            asset: id("b"),
            width: 1,
            height: 1,
            bit_depth: None,
            wide_color: false,
            edge_detail: None,
            capture_date: Some(7.0),
        },
    ];
    assert_eq!(group.latest_date(), Some(7.0));
}
