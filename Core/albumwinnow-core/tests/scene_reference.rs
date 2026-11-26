use albumwinnow_core::{
    Cancellation, CoreError,
    model::NormalizedPixels,
    scene::{self, SceneQuality},
};
use serde_json::Value;
use std::{fs, path::PathBuf};
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/CoreFixtures/scene")
}
#[test]
fn frozen_scene_vectors_and_quality_match() {
    let reference: Value =
        serde_json::from_slice(&fs::read(root().join("reference.json")).unwrap()).unwrap();
    let tolerance = reference["metric_absolute_tolerance"].as_f64().unwrap();
    for item in reference["items"].as_array().unwrap() {
        let pixels = NormalizedPixels {
            width: 128,
            height: 128,
            stride: 512,
            rgba: fs::read(root().join(item["pixels"].as_str().unwrap())).unwrap(),
            decode_pipeline: "apple-reference-v1".into(),
        };
        let actual = scene::quality(&pixels, &Cancellation::default()).unwrap();
        for (key, value) in [
            ("mean_luminance", actual.mean_luminance),
            ("texture_variance", actual.texture_variance),
            ("focus_energy", actual.focus_energy),
            ("dark_clipping", actual.dark_clipping),
            ("bright_clipping", actual.bright_clipping),
        ] {
            assert!(
                (value - item["quality"][key].as_f64().unwrap()).abs() <= tolerance,
                "{} {key}: {value}",
                item["id"]
            );
        }
        let bytes = fs::read(root().join(item["vector"].as_str().unwrap())).unwrap();
        let vector: Vec<f32> = bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes(*b))
            .collect();
        let keys = scene::keys(&vector, &Cancellation::default()).unwrap();
        let expected: Vec<u16> = item["keys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap() as u16)
            .collect();
        assert_eq!(keys.as_slice(), expected, "{}", item["id"]);
    }
}
#[test]
fn match_thresholds_uniform_burst_and_invalid_values() {
    let quality = SceneQuality {
        mean_luminance: 0.5,
        texture_variance: 0.0004,
        focus_energy: 0.01,
        dark_clipping: 0.0,
        bright_clipping: 0.0,
    };
    assert!(scene::matches(quality, quality, false, 0.24).unwrap());
    assert!(
        !scene::matches(
            quality,
            quality,
            false,
            f32::from_bits(0.24_f32.to_bits() + 1)
        )
        .unwrap()
    );
    let flat = SceneQuality {
        texture_variance: 0.0,
        ..quality
    };
    assert!(!scene::matches(flat, quality, false, 0.0).unwrap());
    assert!(scene::matches(flat, flat, true, 0.32).unwrap());
    assert!(!scene::matches(flat, flat, true, f32::from_bits(0.32_f32.to_bits() + 1)).unwrap());
    assert_eq!(
        scene::matches(quality, quality, false, f32::NAN),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        scene::keys(&[0.0; 768], &Cancellation::default()),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        scene::keys(&[f32::INFINITY; 768], &Cancellation::default()),
        Err(CoreError::InvalidValue)
    );
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(scene::keys(&[1.0; 768], &cancel), Err(CoreError::Cancelled));
}

use albumwinnow_core::{
    model::{AssetId, SceneProvider},
    scene_session::{MEMBER_LIMIT, Recommendation, SceneAsset, SceneIndex, SceneSession},
};
use std::{collections::HashMap, sync::Arc};
fn provider() -> SceneProvider {
    SceneProvider {
        provider_id: "apple.vision".into(),
        model_revision: "2".into(),
        preprocessing: "scaleFill512".into(),
        platform_compatibility: "frozen-reference".into(),
    }
}
fn fixture_items(reference: &Value, cross: bool) -> Vec<SceneAsset> {
    reference["items"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let q = &row["quality"];
            SceneAsset {
                id: AssetId {
                    source_id: if cross {
                        if i < 8 { "left" } else { "right" }
                    } else {
                        "fixture"
                    }
                    .into(),
                    item_id: row["id"].as_str().unwrap().into(),
                },
                revision: "reference".into(),
                provider: provider(),
                quality: SceneQuality {
                    mean_luminance: q["mean_luminance"].as_f64().unwrap(),
                    texture_variance: q["texture_variance"].as_f64().unwrap(),
                    focus_energy: q["focus_energy"].as_f64().unwrap(),
                    dark_clipping: q["dark_clipping"].as_f64().unwrap(),
                    bright_clipping: q["bright_clipping"].as_f64().unwrap(),
                },
                keys: row["keys"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_u64().unwrap() as u16)
                    .collect::<Vec<_>>()
                    .try_into()
                    .unwrap(),
                width: row["width"].as_u64().unwrap() as u32,
                height: row["height"].as_u64().unwrap() as u32,
                bit_depth: row["bit_depth"].as_u64().unwrap() as u16,
                wide_color: row["wide_color"].as_bool().unwrap(),
                edge_detail: row["edge_detail"].as_f64().unwrap(),
                associated_resources: false,
                native_identity: None,
                burst: None,
                date: row["capture_date"].as_f64(),
            }
        })
        .collect()
}
#[test]
fn frozen_scene_groups_edges_and_recommendations_are_order_independent() {
    let reference: Value =
        serde_json::from_slice(&fs::read(root().join("reference.json")).unwrap()).unwrap();
    let mut distances = HashMap::new();
    for row in reference["distances"].as_array().unwrap() {
        let a = row["first"].as_str().unwrap().to_owned();
        let b = row["second"].as_str().unwrap().to_owned();
        let value = row["distance"].as_f64().unwrap() as f32;
        distances.insert((a.clone(), b.clone()), value);
        distances.insert((b, a), value);
    }
    for cross in [false, true] {
        for batch in [1, 7, 16] {
            let mut items = fixture_items(&reference, cross);
            items.reverse();
            let mut session = SceneSession::new(
                "op".into(),
                provider(),
                cross.then(|| ("left".into(), "right".into())),
                None,
                Arc::default(),
            )
            .unwrap();
            for chunk in items.chunks(batch) {
                session.append(chunk.to_vec()).unwrap();
            }
            session.complete_preparation().unwrap();
            while let Some(request) = session.next_work().unwrap().request {
                session
                    .submit(
                        "op",
                        request.task_id,
                        distances[&(request.first.item_id, request.second.item_id)],
                    )
                    .unwrap();
            }
            let actual = session.groups().unwrap();
            let expected = reference[if cross { "cross_groups" } else { "groups" }]
                .as_array()
                .unwrap();
            assert_eq!(actual.len(), expected.len());
            for (group, row) in actual.iter().zip(expected) {
                assert_eq!(
                    group
                        .members
                        .iter()
                        .map(|id| id.item_id.as_str())
                        .collect::<Vec<_>>(),
                    row["members"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_str().unwrap())
                        .collect::<Vec<_>>()
                );
                assert_eq!(
                    group.recommended.as_ref().map(|id| id.item_id.as_str()),
                    row["recommended"].as_str()
                );
                assert!(group.reason.is_none());
                assert_eq!(group.edges.len(), row["edges"].as_array().unwrap().len());
                for (edge, row) in group.edges.iter().zip(row["edges"].as_array().unwrap()) {
                    assert_eq!(edge.first.item_id, row["first"].as_str().unwrap());
                    assert_eq!(edge.second.item_id, row["second"].as_str().unwrap());
                    assert_eq!(edge.distance, row["distance"].as_f64().unwrap() as f32);
                    assert_eq!(edge.shared_burst, row["shared_burst"].as_bool().unwrap());
                }
            }
        }
    }
}
fn synthetic(id: usize) -> SceneAsset {
    SceneAsset {
        id: AssetId {
            source_id: "source".into(),
            item_id: format!("{id:06}"),
        },
        revision: "r1".into(),
        provider: provider(),
        quality: SceneQuality {
            mean_luminance: 0.5,
            texture_variance: 0.1,
            focus_energy: 0.01,
            dark_clipping: 0.0,
            bright_clipping: 0.0,
        },
        keys: [1, 2, 3, 4],
        width: 512,
        height: 384,
        bit_depth: 8,
        wide_color: false,
        edge_detail: 1.0,
        associated_resources: false,
        native_identity: None,
        burst: None,
        date: None,
    }
}
#[test]
fn scene_session_rejects_stale_invalid_provider_and_cancelled_work() {
    let cancel = Arc::new(Cancellation::default());
    let mut session =
        SceneSession::new("op".into(), provider(), None, None, cancel.clone()).unwrap();
    let mut incompatible = synthetic(0);
    incompatible.provider.model_revision = "different".into();
    assert_eq!(
        session.append(vec![incompatible]),
        Err(CoreError::InvalidValue)
    );
    assert_eq!(
        session.append(vec![synthetic(0), synthetic(0)]),
        Err(CoreError::InvalidValue)
    );
    session.append(vec![synthetic(0), synthetic(1)]).unwrap();
    session.complete_preparation().unwrap();
    assert_eq!(session.groups(), Err(CoreError::InvalidState));
    let task = session.next_work().unwrap().request.unwrap().task_id;
    assert_eq!(
        session.submit("old", task, 0.1),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(
        session.submit("op", task, f32::NAN),
        Err(CoreError::InvalidValue)
    );
    session.submit("op", task, 0.1).unwrap();
    assert_eq!(
        session.submit("op", task, 0.1),
        Err(CoreError::StaleOperation)
    );
    assert!(session.next_work().unwrap().request.is_none());
    assert_eq!(session.groups().unwrap().len(), 1);
    cancel.cancel();
    assert!(matches!(session.next_work(), Err(CoreError::Cancelled)));
}
#[test]
fn scene_chain_group_limit_candidates_dates_and_aliases_preserve_rules() {
    let mut session =
        SceneSession::new("op".into(), provider(), None, None, Arc::default()).unwrap();
    session.append((0..3).map(synthetic).collect()).unwrap();
    session.complete_preparation().unwrap();
    while let Some(r) = session.next_work().unwrap().request {
        let distance = if r.first.item_id == "000002" && r.second.item_id == "000000" {
            0.25
        } else {
            0.1
        };
        session.submit("op", r.task_id, distance).unwrap();
    }
    assert_eq!(session.groups().unwrap()[0].members.len(), 2);
    let mut index = SceneIndex::default();
    for i in 0..1000 {
        let candidates = index
            .candidates([1, 2, 3, 4], Some("burst"), Some(i as f64))
            .unwrap();
        assert!(candidates.len() <= 64);
        if i > 0 {
            assert_eq!(candidates[0], i - 1);
        }
        index
            .insert([1, 2, 3, 4], Some("burst"), Some(i as f64), i)
            .unwrap();
    }
    assert_eq!(
        index.candidates([65535; 4], None, None).unwrap(),
        Vec::<usize>::new()
    );
    let mut session =
        SceneSession::new("op".into(), provider(), None, None, Arc::default()).unwrap();
    let mut a = synthetic(0);
    let mut b = synthetic(1);
    a.native_identity = Some("native:same".into());
    b.native_identity = a.native_identity.clone();
    session.append(vec![a, b]).unwrap();
    session.complete_preparation().unwrap();
    assert!(session.next_work().unwrap().request.is_none());
    assert!(session.groups().unwrap().is_empty());
    let mut session =
        SceneSession::new("op".into(), provider(), None, None, Arc::default()).unwrap();
    for chunk in (0..1000).map(synthetic).collect::<Vec<_>>().chunks(16) {
        session.append(chunk.to_vec()).unwrap();
    }
    session.complete_preparation().unwrap();
    let mut requests = 0;
    while let Some(r) = session.next_work().unwrap().request {
        requests += 1;
        session.submit("op", r.task_id, 0.0).unwrap();
    }
    let groups = session.groups().unwrap();
    assert!(groups.iter().all(|g| g.members.len() <= MEMBER_LIMIT));
    assert_eq!(groups.iter().map(|g| g.members.len()).sum::<usize>(), 1000);
    assert!(requests < 1000 * 64, "bounded requests: {requests}");
}
#[test]
fn recommendation_requires_quality_signal_before_source_preference() {
    for (associated, focus, clipping, expected) in [
        (true, 0.01, 0.0, Recommendation::AssociatedResources),
        (false, 0.03, 0.0, Recommendation::FocusSignal),
        (false, 0.01, 0.2, Recommendation::ExposureSignal),
        (false, 0.01, 0.0, Recommendation::SourcePreference),
    ] {
        let mut a = synthetic(0);
        let mut b = synthetic(1);
        b.id.source_id = "preferred".into();
        b.associated_resources = associated;
        b.quality.focus_energy = focus;
        a.quality.dark_clipping = clipping;
        let mut session = SceneSession::new(
            "op".into(),
            provider(),
            None,
            Some("preferred".into()),
            Arc::default(),
        )
        .unwrap();
        session.append(vec![a, b.clone()]).unwrap();
        session.complete_preparation().unwrap();
        while let Some(r) = session.next_work().unwrap().request {
            session.submit("op", r.task_id, 0.0).unwrap();
        }
        let group = session.groups().unwrap().remove(0);
        assert_eq!(group.reason, Some(expected));
        assert_eq!(group.recommended, Some(b.id));
    }
}
