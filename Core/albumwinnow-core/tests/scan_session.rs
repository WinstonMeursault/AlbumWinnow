use albumwinnow_core::{
    Cancellation, CoreError,
    fingerprint::FingerprintMetrics,
    matching::{Fingerprint, MatchKind},
    model::AssetId,
    scan::{
        AssetValidation, ComparisonSides, DetectedGroup, ScanItem, ScanSession, TaskResult,
        VerificationOutcome,
    },
};

fn item(source: &str, name: &str, hash: u8) -> ScanItem {
    ScanItem {
        id: AssetId {
            source_id: source.into(),
            item_id: name.into(),
        },
        revision: "revision".into(),
        associated_resources: false,
        native_identity: None,
        fingerprint: Fingerprint {
            file_hash: [hash; 32],
            width: 1000,
            height: 1000,
            bit_depth: 8,
            wide_color: false,
            metrics: FingerprintMetrics {
                perceptual_hash: 0,
                difference_hash: 0,
                mean_rgba: [128, 128, 128, 255],
                edge_detail: 0.0,
            },
        },
    }
}

fn run(
    mut items: Vec<ScanItem>,
    sides: Option<ComparisonSides>,
    batch_size: usize,
    reverse: bool,
    preferred: Option<String>,
    compare: impl Fn(&AssetId, &AssetId) -> MatchKind,
) -> (Vec<DetectedGroup>, usize) {
    let cancel = Cancellation::default();
    let mut session = ScanSession::new(
        "operation".into(),
        vec!["left".into(), "right".into()],
        sides,
        preferred,
    )
    .unwrap();
    if reverse {
        items.reverse();
    }
    for batch in items.chunks(16) {
        session.append_prepared(batch.to_vec(), &cancel).unwrap();
    }
    session.complete_preparation(&cancel).unwrap();
    let mut requests = 0;
    loop {
        let batch = session.next_batch(batch_size, &cancel).unwrap();
        assert!(batch.tasks.len() <= batch_size);
        if batch.done {
            break;
        }
        let mut results: Vec<_> = batch
            .tasks
            .iter()
            .map(|task| TaskResult {
                task_id: task.task_id,
                outcome: VerificationOutcome::Matched(if task.exact_identity {
                    MatchKind::ExactDuplicate
                } else {
                    compare(&task.first, &task.second)
                }),
            })
            .collect();
        requests += results.len();
        if reverse {
            results.reverse();
        }
        // Report each completed worker independently, in a different order.
        for result in results {
            session
                .submit_results("operation", batch.batch_id, vec![result], &cancel)
                .unwrap();
        }
    }
    let ids = session.final_validation_ids(&cancel).unwrap();
    for batch in ids.chunks(16) {
        session
            .submit_final_validations(
                "operation",
                batch
                    .iter()
                    .cloned()
                    .map(|id| AssetValidation {
                        id,
                        accessible: true,
                        revision: Some("revision".into()),
                    })
                    .collect(),
                &cancel,
            )
            .unwrap();
    }
    (session.groups(&cancel).unwrap(), requests)
}

#[test]
fn greedy_grouping_is_stable_across_preparation_batches_and_completion_order() {
    let items = vec![
        item("left", "a", 1),
        item("left", "b", 2),
        item("left", "c", 3),
        item("left", "d", 4),
    ];
    let compare = |a: &AssetId, b: &AssetId| {
        if (a.item_id == "a" && b.item_id == "b") || (a.item_id == "b" && b.item_id == "c") {
            MatchKind::VisualDuplicate
        } else {
            MatchKind::Distinct
        }
    };
    let baseline = run(items.clone(), None, 1, false, None, compare).0;
    assert_eq!(baseline.len(), 1);
    assert_eq!(baseline[0].preferred.item_id, "a");
    assert_eq!(
        baseline[0]
            .duplicates
            .iter()
            .map(|(id, _)| id.item_id.as_str())
            .collect::<Vec<_>>(),
        vec!["b"]
    );
    for size in [1, 2, 7, 16] {
        for reverse in [false, true] {
            assert_eq!(
                run(items.clone(), None, size, reverse, None, compare).0,
                baseline
            );
        }
    }
}

#[test]
fn exact_cohorts_keep_linear_cross_side_evidence_without_cartesian_expansion() {
    let mut items = Vec::new();
    for i in 0..200 {
        items.push(item("left", &format!("l{i:04}"), 8));
    }
    for i in 0..160 {
        items.push(item("right", &format!("r{i:04}"), 8));
    }
    let sides = Some(ComparisonSides {
        first: "left".into(),
        second: "right".into(),
    });
    let (groups, requests) = run(
        items.clone(),
        sides.clone(),
        16,
        false,
        Some("right".into()),
        |_, _| panic!("Exact pairs must not need pixels"),
    );
    assert_eq!(requests, 1);
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].duplicates.len(), 359);
    assert_eq!(groups[0].edges.as_ref().unwrap().len(), 359);
    assert!(
        groups[0]
            .edges
            .as_ref()
            .unwrap()
            .iter()
            .all(|edge| edge.first.source_id != edge.second.source_id)
    );
    assert_eq!(groups[0].recommended.as_ref().unwrap().source_id, "right");
    assert_eq!(
        run(
            items,
            sides,
            1,
            true,
            Some("right".into()),
            |_, _| unreachable!()
        )
        .0,
        groups
    );
}

#[test]
fn ordinary_exact_groups_only_request_one_representative_star() {
    let items = (0..1000)
        .map(|i| item("left", &format!("item{i:04}"), 4))
        .collect();
    let (groups, requests) = run(items, None, 16, true, None, |_, _| unreachable!());
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].duplicates.len(), 999);
    assert_eq!(requests, 999);
}

#[test]
fn aliases_are_native_facts_and_quality_outranks_source_preference() {
    let mut left = item("left", "a", 3);
    let mut right = item("right", "b", 3);
    left.native_identity = Some("darwin.file:device=1,inode=2".into());
    right.native_identity = left.native_identity.clone();
    assert!(
        run(
            vec![left.clone(), right.clone()],
            Some(ComparisonSides {
                first: "left".into(),
                second: "right".into()
            }),
            1,
            false,
            None,
            |_, _| unreachable!()
        )
        .0
        .is_empty()
    );
    right.native_identity = None;
    right.fingerprint.bit_depth = 16;
    let (groups, _) = run(
        vec![left, right],
        None,
        16,
        false,
        Some("left".into()),
        |_, _| unreachable!(),
    );
    assert_eq!(groups[0].preferred.source_id, "right");
    assert!(groups[0].recommended.is_none());
}

#[test]
fn stale_callbacks_and_invalid_batches_cannot_mutate_session_state() {
    let cancel = Cancellation::default();
    let mut session =
        ScanSession::new("new-operation".into(), vec!["left".into()], None, None).unwrap();
    let a = item("left", "a", 1);
    assert_eq!(
        session.append_prepared(vec![a.clone(), a.clone()], &cancel),
        Err(CoreError::InvalidValue)
    );
    session
        .append_prepared(vec![a, item("left", "b", 1)], &cancel)
        .unwrap();
    session.complete_preparation(&cancel).unwrap();
    let batch = session.next_batch(16, &cancel).unwrap();
    assert_eq!(batch.tasks.len(), 1);
    assert!(matches!(
        session.next_batch(16, &cancel),
        Err(CoreError::InvalidState)
    ));
    let result = TaskResult {
        task_id: batch.tasks[0].task_id,
        outcome: VerificationOutcome::Matched(MatchKind::ExactDuplicate),
    };
    assert_eq!(
        session.submit_results(
            "old-operation",
            batch.batch_id,
            vec![result.clone()],
            &cancel
        ),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(
        session.submit_results(
            "new-operation",
            batch.batch_id + 1,
            vec![result.clone()],
            &cancel
        ),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(
        session.submit_results(
            "new-operation",
            batch.batch_id,
            vec![result.clone(), result.clone()],
            &cancel
        ),
        Err(CoreError::StaleOperation)
    );
    session
        .submit_results(
            "new-operation",
            batch.batch_id,
            vec![result.clone()],
            &cancel,
        )
        .unwrap();
    assert_eq!(
        session.submit_results("new-operation", batch.batch_id, vec![result], &cancel),
        Err(CoreError::StaleOperation)
    );
    assert!(session.next_batch(16, &cancel).unwrap().done);
    assert_eq!(session.groups(&cancel), Err(CoreError::InvalidState));
    let validations = session
        .final_validation_ids(&cancel)
        .unwrap()
        .into_iter()
        .map(|id| AssetValidation {
            id,
            accessible: true,
            revision: Some("revision".into()),
        })
        .collect();
    session
        .submit_final_validations("new-operation", validations, &cancel)
        .unwrap();
    assert_eq!(session.groups(&cancel).unwrap().len(), 1);
    cancel.cancel();
    cancel.cancel();
    assert_eq!(session.groups(&cancel), Err(CoreError::Cancelled));
}

#[test]
fn failure_attribution_is_limited_to_the_actual_pair_and_partial_results_stay_unapplied() {
    let cancel = Cancellation::default();
    let mut session =
        ScanSession::new("operation".into(), vec!["left".into()], None, None).unwrap();
    session
        .append_prepared(
            vec![
                item("left", "a", 1),
                item("left", "b", 2),
                item("left", "c", 3),
            ],
            &cancel,
        )
        .unwrap();
    session.complete_preparation(&cancel).unwrap();
    let batch = session.next_batch(16, &cancel).unwrap();
    let unrelated = AssetId {
        source_id: "left".into(),
        item_id: "not-in-pair".into(),
    };
    assert_eq!(
        session.submit_results(
            "operation",
            batch.batch_id,
            vec![TaskResult {
                task_id: batch.tasks[0].task_id,
                outcome: VerificationOutcome::Failed(unrelated)
            }],
            &cancel
        ),
        Err(CoreError::InvalidValue)
    );
    session
        .submit_results(
            "operation",
            batch.batch_id,
            vec![TaskResult {
                task_id: batch.tasks[1].task_id,
                outcome: VerificationOutcome::Matched(MatchKind::VisualDuplicate),
            }],
            &cancel,
        )
        .unwrap();
    assert_eq!(session.groups(&cancel), Err(CoreError::InvalidState));
    session
        .submit_results(
            "operation",
            batch.batch_id,
            vec![TaskResult {
                task_id: batch.tasks[0].task_id,
                outcome: VerificationOutcome::Failed(batch.tasks[0].first.clone()),
            }],
            &cancel,
        )
        .unwrap();
    loop {
        let remaining = session.next_batch(16, &cancel).unwrap();
        if remaining.done {
            break;
        }
        assert!(
            remaining
                .tasks
                .iter()
                .all(|task| task.first.item_id != "a" && task.second.item_id != "a")
        );
        let results = remaining
            .tasks
            .iter()
            .map(|task| TaskResult {
                task_id: task.task_id,
                outcome: VerificationOutcome::Matched(MatchKind::Distinct),
            })
            .collect();
        session
            .submit_results("operation", remaining.batch_id, results, &cancel)
            .unwrap();
    }
    assert!(session.groups(&cancel).unwrap().is_empty());
}

#[test]
fn final_revision_change_or_missing_member_never_survives_into_groups() {
    let cancel = Cancellation::default();
    let mut session =
        ScanSession::new("operation".into(), vec!["left".into()], None, None).unwrap();
    session
        .append_prepared(
            vec![
                item("left", "a", 1),
                item("left", "b", 1),
                item("left", "c", 1),
            ],
            &cancel,
        )
        .unwrap();
    session.complete_preparation(&cancel).unwrap();
    let batch = session.next_batch(16, &cancel).unwrap();
    assert!(
        batch
            .tasks
            .iter()
            .all(|task| task.first_revision == "revision" && task.second_revision == "revision")
    );
    session
        .submit_results(
            "operation",
            batch.batch_id,
            batch
                .tasks
                .iter()
                .map(|task| TaskResult {
                    task_id: task.task_id,
                    outcome: VerificationOutcome::Matched(MatchKind::ExactDuplicate),
                })
                .collect(),
            &cancel,
        )
        .unwrap();
    assert!(session.next_batch(16, &cancel).unwrap().done);
    let validations = session
        .final_validation_ids(&cancel)
        .unwrap()
        .into_iter()
        .map(|id| {
            let revision = Some(
                if id.item_id == "b" {
                    "changed"
                } else {
                    "revision"
                }
                .to_owned(),
            );
            AssetValidation {
                id,
                revision,
                accessible: true,
            }
        })
        .collect();
    session
        .submit_final_validations("operation", validations, &cancel)
        .unwrap();
    let groups = session.groups(&cancel).unwrap();
    assert_eq!(
        groups[0]
            .duplicates
            .iter()
            .map(|(id, _)| id.item_id.as_str())
            .collect::<Vec<_>>(),
        vec!["c"]
    );
}

#[test]
fn signed_zero_is_a_quality_tie_and_inactive_source_preference_is_ignored() {
    let a = item("left", "a", 1);
    let mut b = item("right", "b", 1);
    b.fingerprint.metrics.edge_detail = -0.0;
    let (groups, _) = run(
        vec![b, a],
        None,
        16,
        true,
        Some("inactive-source".into()),
        |_, _| unreachable!(),
    );
    assert_eq!(groups[0].preferred.source_id, "left");
    assert!(groups[0].recommended.is_none());
}

#[test]
fn a_running_candidate_session_can_be_cancelled_without_waiting_for_a_state_lock() {
    use std::sync::{Arc, mpsc};
    use std::time::{Duration, Instant};
    let cancel = Arc::new(Cancellation::default());
    let worker_cancel = cancel.clone();
    let (sender, receiver) = mpsc::channel();
    let worker = std::thread::spawn(move || -> Result<(), CoreError> {
        let mut session = ScanSession::new("operation".into(), vec!["left".into()], None, None)?;
        for start in (0..10_000).step_by(16) {
            let batch = (start..(start + 16).min(10_000))
                .map(|i| item("left", &format!("item{i:05}"), i as u8))
                .collect();
            session.append_prepared(batch, &worker_cancel)?;
        }
        session.complete_preparation(&worker_cancel)?;
        let mut first = true;
        loop {
            let batch = session.next_batch(16, &worker_cancel)?;
            if batch.done {
                return Ok(());
            }
            let results = batch
                .tasks
                .iter()
                .map(|task| TaskResult {
                    task_id: task.task_id,
                    outcome: VerificationOutcome::Matched(if task.exact_identity {
                        MatchKind::ExactDuplicate
                    } else {
                        MatchKind::Distinct
                    }),
                })
                .collect();
            session.submit_results("operation", batch.batch_id, results, &worker_cancel)?;
            if first {
                sender.send(()).unwrap();
                first = false;
            }
        }
    });
    receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    let start = Instant::now();
    cancel.cancel();
    assert_eq!(worker.join().unwrap(), Err(CoreError::Cancelled));
    assert!(start.elapsed() < Duration::from_millis(500));
}

#[test]
fn scene_candidates_are_bounded_and_derive_from_final_groups_in_both_scan_modes() {
    for cross_side in [false, true] {
        let cancel = Cancellation::default();
        let mut session = ScanSession::new(
            "operation".into(),
            vec!["left".into(), "right".into()],
            cross_side.then(|| ComparisonSides {
                first: "left".into(),
                second: "right".into(),
            }),
            None,
        )
        .unwrap();
        assert_eq!(
            session.scene_candidate_page(0, 16, &cancel),
            Err(CoreError::InvalidState)
        );
        let items: Vec<_> = (0..40)
            .map(|index| {
                item(
                    if cross_side && index % 2 == 1 {
                        "right"
                    } else {
                        "left"
                    },
                    &format!("item{index:02}"),
                    if index < 2 { 1 } else { index as u8 },
                )
            })
            .collect();
        for batch in items.chunks(16) {
            session.append_prepared(batch.to_vec(), &cancel).unwrap();
        }
        session.complete_preparation(&cancel).unwrap();
        loop {
            let batch = session.next_batch(16, &cancel).unwrap();
            if batch.done {
                break;
            }
            session
                .submit_results(
                    "operation",
                    batch.batch_id,
                    batch
                        .tasks
                        .iter()
                        .map(|task| TaskResult {
                            task_id: task.task_id,
                            outcome: VerificationOutcome::Matched(if task.exact_identity {
                                MatchKind::ExactDuplicate
                            } else {
                                MatchKind::Distinct
                            }),
                        })
                        .collect(),
                    &cancel,
                )
                .unwrap();
        }
        assert_eq!(
            session.scene_candidate_page(0, 16, &cancel),
            Err(CoreError::InvalidState)
        );
        let validations = session.final_validation_ids(&cancel).unwrap();
        assert_eq!(validations.len(), 2);
        session
            .submit_final_validations(
                "operation",
                validations
                    .iter()
                    .map(|id| AssetValidation {
                        id: id.clone(),
                        revision: Some("revision".into()),
                        accessible: true,
                    })
                    .collect(),
                &cancel,
            )
            .unwrap();
        for limit in [0, 17] {
            assert_eq!(
                session.scene_candidate_page(0, limit, &cancel),
                Err(CoreError::InvalidBuffer)
            );
        }
        let mut candidates = Vec::new();
        loop {
            let page = session
                .scene_candidate_page(candidates.len(), 16, &cancel)
                .unwrap();
            assert!(page.len() <= 16);
            if page.is_empty() {
                break;
            }
            candidates.extend(page);
        }
        assert_eq!(candidates.len(), 38);
        assert_eq!(
            candidates
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            38
        );
        assert!(
            candidates
                .iter()
                .all(|id| id.item_id != "item00" && id.item_id != "item01")
        );
        assert_eq!(
            session.scene_candidate_page(0, 16, &cancel).unwrap(),
            candidates[..16]
        );
        assert!(
            session
                .scene_candidate_page(usize::MAX, 16, &cancel)
                .unwrap()
                .is_empty()
        );
        // A late failing final fact invalidates the cached exclusion; no stale page survives.
        session
            .submit_final_validations(
                "operation",
                vec![AssetValidation {
                    id: items[0].id.clone(),
                    revision: None,
                    accessible: false,
                }],
                &cancel,
            )
            .unwrap();
        let mut refreshed = Vec::new();
        loop {
            let page = session
                .scene_candidate_page(refreshed.len(), 16, &cancel)
                .unwrap();
            if page.is_empty() {
                break;
            }
            refreshed.extend(page);
        }
        assert_eq!(refreshed.len(), 40);
        cancel.cancel();
        assert_eq!(
            session.scene_candidate_page(0, 16, &cancel),
            Err(CoreError::Cancelled)
        );
    }
}
