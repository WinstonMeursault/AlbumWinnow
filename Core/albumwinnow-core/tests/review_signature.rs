use albumwinnow_core::{
    CoreError,
    matching::MatchKind,
    model::{AssetId, SceneProvider},
    scan::ComparisonSides,
    signature::{SignatureEdge, SignatureEvidence, SignatureMember},
};
fn id(item: &str) -> AssetId {
    AssetId {
        source_id: "s:\u{6e90}".into(),
        item_id: item.into(),
    }
}
fn evidence() -> SignatureEvidence {
    SignatureEvidence {
        members: vec![
            SignatureMember {
                id: id("photo|\u{e9}"),
                revision: "r:\u{e9}|\0".into(),
                properties: None,
            },
            SignatureMember {
                id: id("empty:\0"),
                revision: "".into(),
                properties: Some(0),
            },
        ],
        edges: vec![SignatureEdge {
            first: id("photo|\u{e9}"),
            second: id("empty:\0"),
            kind: MatchKind::VisualDuplicate,
        }],
        sides: None,
        scene: None,
    }
}
#[test]
fn canonical_bytes_and_sha256_match_fixed_protocol_vector() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/CoreFixtures/signature/v2.json");
    let reference: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root).unwrap()).unwrap();
    let evidence = evidence();
    let actual: String = evidence
        .canonical_bytes()
        .unwrap()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert_eq!(actual, reference["canonical_hex"].as_str().unwrap());
    assert_eq!(
        evidence.digest().unwrap(),
        reference["sha256"].as_str().unwrap()
    );
}
#[test]
fn member_display_order_edge_direction_and_duplicate_evidence_are_irrelevant() {
    let mut evidence = evidence();
    let expected = evidence.digest().unwrap();
    evidence.members.reverse();
    let edge = &mut evidence.edges[0];
    std::mem::swap(&mut edge.first, &mut edge.second);
    evidence.edges.push(evidence.edges[0].clone());
    assert_eq!(evidence.digest().unwrap(), expected);
}
#[test]
fn changed_revision_properties_scope_provider_or_match_invalidate_signature() {
    let expected = evidence().digest().unwrap();
    let mut changed = evidence();
    changed.members[0].revision.push('x');
    assert_ne!(changed.digest().unwrap(), expected);
    let mut changed = evidence();
    changed.members[0].properties = Some(0);
    assert_ne!(changed.digest().unwrap(), expected);
    let mut changed = evidence();
    changed.edges[0].kind = MatchKind::SimilarPhoto;
    assert_ne!(changed.digest().unwrap(), expected);
    let mut changed = evidence();
    changed.members[0].id.source_id = "other".into();
    changed.edges[0].first.source_id = "other".into();
    let ordinary = changed.digest().unwrap();
    changed.sides = Some(ComparisonSides {
        first: "other".into(),
        second: "s:\u{6e90}".into(),
    });
    assert_ne!(changed.digest().unwrap(), ordinary);
    let mut changed = evidence();
    changed.scene = Some(SceneProvider {
        provider_id: "controlled".into(),
        model_revision: "1".into(),
        preprocessing: "fixed".into(),
        platform_compatibility: "test-only".into(),
    });
    let scene = changed.digest().unwrap();
    assert_ne!(scene, expected);
    changed.scene.as_mut().unwrap().model_revision = "2".into();
    assert_ne!(changed.digest().unwrap(), scene);
}
#[test]
fn exact_transitive_group_representation_is_stable_but_disconnected_evidence_is_invalid() {
    let mut evidence = evidence();
    evidence.edges[0].kind = MatchKind::ExactDuplicate;
    evidence.members.push(SignatureMember {
        id: id("third"),
        revision: "r3".into(),
        properties: None,
    });
    evidence.edges.push(SignatureEdge {
        first: evidence.members[0].id.clone(),
        second: id("third"),
        kind: MatchKind::ExactDuplicate,
    });
    let expected = evidence.digest().unwrap();
    evidence.edges[1].first = evidence.members[1].id.clone();
    assert_eq!(evidence.digest().unwrap(), expected);
    evidence.edges.pop();
    assert_eq!(evidence.digest(), Err(CoreError::InvalidValue));
}
#[test]
fn opaque_delimiters_nulls_and_unicode_cannot_collide_or_bypass_validation() {
    let mut first = evidence();
    first.members[0].id.item_id = "a:b|c".into();
    first.edges[0].first = first.members[0].id.clone();
    let mut second = evidence();
    second.members[0].id.item_id = "a|b:c".into();
    second.edges[0].first = second.members[0].id.clone();
    assert_ne!(first.digest().unwrap(), second.digest().unwrap());
    let mut bad = evidence();
    bad.members.push(bad.members[0].clone());
    assert_eq!(bad.digest(), Err(CoreError::InvalidValue));
    let mut bad = evidence();
    bad.edges[0].second = id("unknown");
    assert_eq!(bad.digest(), Err(CoreError::InvalidValue));
    let mut bad = evidence();
    bad.members[0].properties = Some(8);
    assert_eq!(bad.digest(), Err(CoreError::InvalidValue));
    let mut bad = evidence();
    bad.edges[0].kind = MatchKind::SceneSimilar;
    assert_eq!(bad.digest(), Err(CoreError::InvalidValue));
}
