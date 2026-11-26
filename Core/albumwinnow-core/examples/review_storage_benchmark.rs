//! Run explicitly against a newly created scratch directory, outside other builds.
use albumwinnow_core::{
    matching::MatchKind,
    model::AssetId,
    review::{ReviewAsset, ReviewGroup, ReviewStatus, SourceKind},
    review_session::{ReviewIntent, ReviewSession, SourceInput},
};
use std::{path::PathBuf, time::Instant};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = PathBuf::from(
        std::env::args_os()
            .nth(1)
            .ok_or("provide a new scratch directory")?,
    );
    // Refuse an existing path: this benchmark never clears user data.
    std::fs::create_dir(&root)?;
    let mut report = Vec::new();
    for count in [100, 1000, 10000] {
        let mut session = ReviewSession::open(&root.join(format!("review-{count}.sqlite")), false)?;
        let source = session.register_source(
            1,
            SourceInput {
                kind: SourceKind::ControlledTest,
                namespace: "benchmark.v2".into(),
                identity: vec![1],
                bookmark: vec![],
                label: "Synthetic benchmark".into(),
            },
        )?;
        let groups: Vec<_> = (0..count)
            .map(|i| {
                let asset = |suffix: &str| ReviewAsset {
                    id: AssetId {
                        source_id: source.id.clone(),
                        item_id: format!("{i}-{suffix}"),
                    },
                    name: suffix.into(),
                    revision: "r1".into(),
                    kind: SourceKind::ControlledTest,
                    properties: None,
                    byte_count: Some(100),
                    capture_date: None,
                    burst: None,
                    native_identity: None,
                    link_count: None,
                };
                let a = asset("a");
                let b = asset("b");
                ReviewGroup {
                    preferred: a.id.clone(),
                    members: vec![a, b.clone()],
                    duplicates: vec![(b.id, MatchKind::ExactDuplicate)],
                    edges: None,
                    sides: None,
                    scene: None,
                    recommendation: None,
                    has_quality_recommendation: true,
                    scene_recommendation_reason: None,
                    scene_quality: vec![],
                    scene_matches: vec![],
                    evidence: vec![],
                }
            })
            .collect();
        let choices = groups
            .iter()
            .map(|group| Ok((group.signature()?, group.preferred.clone())))
            .collect::<Result<Vec<_>, albumwinnow_core::CoreError>>()?;
        session.complete_scan(session.metadata().revision, groups)?;
        for (index, (signature, keep)) in choices.iter().enumerate() {
            session.apply_intent(
                session.metadata().revision,
                signature,
                format!("seed-{index}"),
                ReviewIntent::ConfirmKeep { keep: keep.clone() },
            )?;
        }
        assert_eq!(session.metadata().decision_count, count);
        let mut navigation = Vec::new();
        let mut decision = Vec::new();
        for sample in 0..5 {
            let signature = &choices[sample as usize].0;
            let start = Instant::now();
            session.save_position(
                session.metadata().revision,
                sample + 1,
                Some(signature.clone()),
                Some(sample),
            )?;
            navigation.push(start.elapsed().as_secs_f64() * 1000.0);
            let start = Instant::now();
            session.apply_intent(
                session.metadata().revision,
                signature,
                format!("command-{sample}"),
                ReviewIntent::SetStatus {
                    status: ReviewStatus::Deferred,
                },
            )?;
            decision.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        let median = |values: &[f64]| {
            let mut sorted = values.to_vec();
            sorted.sort_by(f64::total_cmp);
            sorted[sorted.len() / 2]
        };
        report.push(serde_json::json!({ "groups":count, "samples":5, "navigation_ms":navigation,"decision_ms":decision,"navigation_median_ms":median(&navigation),"decision_median_ms":median(&decision) }));
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}
