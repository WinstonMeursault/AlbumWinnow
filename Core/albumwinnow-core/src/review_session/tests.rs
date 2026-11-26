use super::*;
use crate::review::{ReviewQuery, StatusFilter};
use std::path::PathBuf;
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
            "albumwinnow-v2-session-{}-{stamp}-{sequence}",
            std::process::id()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn db(&self) -> PathBuf {
        self.0.join("review.sqlite")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn group(source: &str, prefix: &str, date: Option<f64>, bytes: Option<u64>) -> ReviewGroup {
    let asset = |item: &str| ReviewAsset {
        id: AssetId {
            source_id: source.into(),
            item_id: format!("{prefix}-{item}"),
        },
        name: item.into(),
        revision: "r1".into(),
        kind: SourceKind::ControlledTest,
        properties: None,
        byte_count: bytes,
        capture_date: date,
        burst: None,
        native_identity: None,
        link_count: None,
    };
    let a = asset("a");
    let b = asset("b");
    ReviewGroup {
        preferred: a.id.clone(),
        duplicates: vec![(b.id.clone(), MatchKind::ExactDuplicate)],
        members: vec![a, b],
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
}
fn scanned() -> (Scratch, ReviewSession, Vec<ReviewGroup>) {
    let scratch = Scratch::new();
    let mut session = ReviewSession::open(&scratch.db(), false).unwrap();
    let source = session
        .register_source(
            1,
            SourceInput {
                kind: SourceKind::ControlledTest,
                namespace: "test.dir".into(),
                identity: vec![1],
                bookmark: vec![],
                label: "fixture".into(),
            },
        )
        .unwrap();
    let groups = vec![
        group(&source.id, "old", Some(1.0), Some(100)),
        group(&source.id, "new", Some(5.0), None),
        group(&source.id, "unknown", None, Some(0)),
    ];
    session
        .complete_scan(session.metadata.revision, groups.clone())
        .unwrap();
    (scratch, session, groups)
}
#[test]
fn estimates_are_not_confirmations_and_queries_are_bounded_stable_pages() {
    let (_scratch, mut session, groups) = scanned();
    assert_eq!(session.query_count().unwrap(), 3);
    let first = session.query_page(0, 1).unwrap();
    assert_eq!(first[0].preferred, groups[0].preferred);
    assert_eq!(first[0].estimate.known_bytes, 100);
    assert_eq!(first[0].confirmed_removal_count, 0);
    assert_eq!(
        session.query_page(1, 1).unwrap()[0].preferred,
        groups[1].preferred
    );
    assert!(session.query_page(usize::MAX, 256).unwrap().is_empty());
    assert!(matches!(
        session.query_page(0, 257),
        Err(CoreError::InvalidValue)
    ));
    assert!(session.healthy());
    for (sort, expected) in [
        (ReviewSort::Newest, vec![1, 0, 2]),
        (ReviewSort::Oldest, vec![0, 1, 2]),
        (ReviewSort::Bytes, vec![0, 2, 1]),
        (ReviewSort::Count, vec![0, 1, 2]),
    ] {
        let mut settings = session.settings.clone();
        settings.query.sort = sort;
        session
            .save_settings(session.metadata.revision, settings)
            .unwrap();
        let result = session.query_page(0, 256).unwrap();
        assert_eq!(
            result
                .iter()
                .map(|s| s.preferred.clone())
                .collect::<Vec<_>>(),
            expected
                .into_iter()
                .map(|i| groups[i].preferred.clone())
                .collect::<Vec<_>>()
        );
    }
}
#[test]
fn manual_confirm_defer_keep_and_pending_preserve_original_intent_rules() {
    let (scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    let initial = session.metadata.revision;
    let keep = groups[0].members[1].id.clone();
    let confirmed = session
        .apply_intent(
            initial,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep { keep: keep.clone() },
        )
        .unwrap();
    assert_eq!(confirmed.decision.keep, Some(keep.clone()));
    assert!(confirmed.decision.removals.contains(&groups[0].preferred));
    let deferred = session
        .apply_intent(
            confirmed.metadata.revision,
            &signature,
            "defer".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Deferred,
            },
        )
        .unwrap();
    assert_eq!(deferred.decision.removals, confirmed.decision.removals);
    let kept = session
        .apply_intent(
            deferred.metadata.revision,
            &signature,
            "kept".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Kept,
            },
        )
        .unwrap();
    assert!(kept.decision.removals.is_empty());
    assert!(kept.decision.keep.is_none());
    assert!(matches!(
        session.apply_intent(
            initial,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep { keep }
        ),
        Err(CoreError::StaleOperation)
    ));
    let mut settings = session.settings.clone();
    settings.query = ReviewQuery {
        status: StatusFilter::Kept,
        ..ReviewQuery::default()
    };
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    assert_eq!(session.query_count().unwrap(), 1);
    drop(session);
    let mut session = ReviewSession::open(&scratch.db(), true).unwrap();
    assert_eq!(session.query_count().unwrap(), 1);
    assert_eq!(
        session.detail(&signature).unwrap().decision.unwrap().status,
        ReviewStatus::Kept
    );
}
#[test]
fn protection_pruning_and_retry_are_owned_by_core_and_do_not_resurrect_authority() {
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    let initial = session.metadata.revision;
    session
        .apply_intent(
            initial,
            &signature,
            "all".into(),
            ReviewIntent::ConfirmDeleteAll,
        )
        .unwrap();
    session
        .set_locked(
            session.metadata.revision,
            groups[0].members[1].clone(),
            true,
        )
        .unwrap();
    let retry = session
        .apply_intent(
            initial,
            &signature,
            "all".into(),
            ReviewIntent::ConfirmDeleteAll,
        )
        .unwrap();
    assert!(retry.replayed);
    assert_eq!(retry.decision, ReviewDecision::default());
    session
        .set_locked(
            session.metadata.revision,
            groups[0].members[1].clone(),
            false,
        )
        .unwrap();
    assert!(
        session
            .detail(&signature)
            .unwrap()
            .decision
            .unwrap()
            .removals
            .is_empty()
    );
    assert!(matches!(
        session.apply_intent(
            session.metadata.revision,
            &signature,
            "all".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Deferred
            }
        ),
        Err(CoreError::InvalidValue)
    ));
}
#[test]
fn failed_storage_never_changes_live_state_and_disables_further_authority() {
    let (scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    let before = session.metadata.clone();
    session.store.testing_connection().execute_batch("CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        session.apply_intent(
            before.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmDeleteAll
        ),
        Err(CoreError::WriteFailed)
    ));
    assert!(!session.healthy());
    assert_eq!(session.metadata, before);
    assert!(session.decisions.is_empty());
    session
        .store
        .testing_connection()
        .execute_batch("DROP TRIGGER fail_write;")
        .unwrap();
    assert!(matches!(
        session.apply_intent(
            before.revision,
            &signature,
            "retry".into(),
            ReviewIntent::ConfirmDeleteAll
        ),
        Err(CoreError::ProtectionUnavailable)
    ));
    drop(session);
    let session = ReviewSession::open(&scratch.db(), true).unwrap();
    assert!(session.healthy());
    assert!(session.decisions.is_empty());
}
#[test]
fn database_loss_or_external_write_disables_even_read_query_authority() {
    for replace in [false, true] {
        let (scratch, mut session, _groups) = scanned();
        if replace {
            std::fs::rename(scratch.db(), scratch.0.join("saved.sqlite")).unwrap();
        } else {
            let connection = rusqlite::Connection::open(scratch.db()).unwrap();
            connection.execute("DELETE FROM navigation", []).unwrap();
        }
        assert!(matches!(
            session.query_count(),
            Err(CoreError::ProtectionUnavailable)
        ));
        assert!(!session.healthy());
    }
}
#[test]
fn resume_uses_anchor_then_pending_at_position_then_first_and_reset_invalidates_late_writes() {
    let (_scratch, mut session, groups) = scanned();
    let signatures = groups
        .iter()
        .map(|g| g.signature().unwrap())
        .collect::<Vec<_>>();
    session
        .save_position(
            session.metadata.revision,
            1,
            Some(signatures[1].clone()),
            Some(1),
        )
        .unwrap();
    assert_eq!(
        session.resume_signature().unwrap(),
        Some(signatures[1].clone())
    );
    session
        .apply_intent(
            session.metadata.revision,
            &signatures[1],
            "kept".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Kept,
            },
        )
        .unwrap();
    assert_eq!(
        session.resume_signature().unwrap(),
        Some(signatures[2].clone())
    );
    session
        .save_position(session.metadata.revision, 2, None, Some(100))
        .unwrap();
    assert_eq!(
        session.resume_signature().unwrap(),
        Some(signatures[0].clone())
    );
    session.reset_progress(session.metadata.revision).unwrap();
    assert_eq!(session.navigation_sequence(), 3);
    assert!(matches!(
        session.save_position(
            session.metadata.revision,
            2,
            Some(signatures[2].clone()),
            Some(2)
        ),
        Err(CoreError::StaleOperation)
    ));
    assert_eq!(
        session.resume_signature().unwrap(),
        Some(signatures[0].clone())
    );
    assert!(session.healthy());
}
#[test]
fn readonly_database_failure_leaves_navigation_unacknowledged_and_session_unhealthy() {
    let (_scratch, mut session, groups) = scanned();
    session
        .store
        .testing_connection()
        .execute_batch("PRAGMA query_only=ON")
        .unwrap();
    assert!(matches!(
        session.save_position(
            session.metadata.revision,
            1,
            Some(groups[0].signature().unwrap()),
            Some(0)
        ),
        Err(CoreError::WriteFailed)
    ));
    assert!(!session.healthy());
    assert_eq!(session.navigation_sequence(), 0);
    assert!(session.anchor.is_none());
}

#[test]
fn sqlite_full_is_not_acknowledged_and_does_not_publish_partial_source_state() {
    let (scratch, mut session, _groups) = scanned();
    let before = session.metadata.clone();
    let sources = session.sources.len();
    let connection = session.store.testing_connection();
    connection
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
        .unwrap();
    let pages: u64 = connection
        .pragma_query_value(None, "page_count", |row| row.get(0))
        .unwrap();
    connection
        .pragma_update(None, "max_page_count", pages)
        .unwrap();
    let result = session.register_source(
        before.revision,
        SourceInput {
            kind: SourceKind::ControlledTest,
            namespace: "test.dir".into(),
            identity: vec![2],
            bookmark: vec![42; 131072],
            label: "must not commit".into(),
        },
    );
    assert!(matches!(result, Err(CoreError::WriteFailed)));
    assert!(!session.healthy());
    assert_eq!(session.metadata, before);
    assert_eq!(session.sources.len(), sources);
    drop(session);
    let session = ReviewSession::open(&scratch.db(), true).unwrap();
    assert_eq!(session.metadata, before);
    assert_eq!(session.sources.len(), sources);
}

#[test]
fn staged_results_commit_only_as_one_current_operation_and_cancel_preserves_saved_state() {
    let (_scratch, mut session, groups) = scanned();
    let before = session.metadata.clone();
    session.begin_scan(before.revision, "first".into()).unwrap();
    session
        .append_scan_groups("first", vec![groups[0].clone()])
        .unwrap();
    assert_eq!(session.query_count().unwrap(), 3);
    session.discard_scan("first").unwrap();
    assert_eq!(session.metadata, before);
    session.begin_scan(before.revision, "next".into()).unwrap();
    assert!(matches!(
        session.append_scan_groups("first", vec![]),
        Err(CoreError::StaleOperation)
    ));
    assert!(matches!(
        session.discard_scan("first"),
        Err(CoreError::StaleOperation)
    ));
    assert!(matches!(
        session.append_scan_groups("next", vec![groups[0].clone(); 17]),
        Err(CoreError::InvalidBuffer)
    ));
    session
        .append_scan_groups("next", vec![groups[1].clone()])
        .unwrap();
    session.finish_scan("next").unwrap();
    assert_eq!(session.query_count().unwrap(), 1);
    assert_eq!(session.metadata.scan_generation, before.scan_generation + 1);
    session
        .begin_scan(session.metadata.revision, "stale".into())
        .unwrap();
    let mut settings = session.settings.clone();
    settings.similar_scenes_enabled = true;
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    assert!(matches!(
        session.finish_scan("stale"),
        Err(CoreError::StaleOperation)
    ));
    assert!(session.healthy());
}

fn cleanup_facts(session: &ReviewSession, asset: &ReviewAsset) -> crate::cleanup::RemovalFacts {
    let source = &session.sources[&asset.id.source_id];
    crate::cleanup::RemovalFacts {
        asset: asset.clone(),
        source_namespace: source.native_namespace.clone(),
        source_identity: source.native_identity.clone(),
        accessible: true,
        in_scan_scope: true,
        independently_removable: true,
        inside_read_only_root: false,
        matches_saved_lock: false,
        protection_complete: true,
    }
}
fn cleanup_input(
    session: &ReviewSession,
    group: &ReviewGroup,
) -> (
    crate::cleanup::run::CleanupItemKey,
    crate::cleanup::PairFacts,
) {
    (
        crate::cleanup::run::CleanupItemKey { group: 0, pair: 0 },
        crate::cleanup::PairFacts {
            keep: Some(cleanup_facts(session, &group.members[0])),
            remove: cleanup_facts(session, &group.members[1]),
            proof: crate::cleanup::ComparisonProof::Pixels {
                kind: MatchKind::ExactDuplicate,
            },
        },
    )
}
#[test]
fn cleanup_is_derived_from_manual_decisions_and_lock_or_keep_changes_invalidate_a_plan() {
    use crate::cleanup::CleanupReason;
    for lock in [false, true] {
        let (_scratch, mut session, groups) = scanned();
        assert!(matches!(
            session.start_cleanup(session.metadata.revision),
            Err(CoreError::InvalidValue)
        ));
        let signature = groups[0].signature().unwrap();
        session
            .apply_intent(
                session.metadata.revision,
                &signature,
                "confirm".into(),
                ReviewIntent::ConfirmKeep {
                    keep: groups[0].preferred.clone(),
                },
            )
            .unwrap();
        let operation = session.start_cleanup(session.metadata.revision).unwrap();
        let input = cleanup_input(&session, &groups[0]);
        if lock {
            session
                .set_locked(
                    session.metadata.revision,
                    groups[0].members[1].clone(),
                    true,
                )
                .unwrap();
        } else {
            session
                .apply_intent(
                    session.metadata.revision,
                    &signature,
                    "new-keep".into(),
                    ReviewIntent::ConfirmKeep {
                        keep: groups[0].members[1].id.clone(),
                    },
                )
                .unwrap();
        }
        assert_eq!(
            session.authorize_cleanup(&operation, &[input]),
            Err(CleanupReason::StalePlan)
        );
        assert!(session.healthy());
    }
}
#[test]
fn an_inflight_native_ticket_blocks_acknowledged_edits_but_navigation_remains_independent() {
    use crate::cleanup::{CleanupReason, run::CleanupOutcome};
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep {
                keep: groups[0].preferred.clone(),
            },
        )
        .unwrap();
    let operation = session.start_cleanup(session.metadata.revision).unwrap();
    let mut settings = session.settings.clone();
    settings.query.sort = crate::review::ReviewSort::Newest;
    session
        .save_settings(session.metadata.revision, settings.clone())
        .unwrap();
    let input = cleanup_input(&session, &groups[0]);
    let ticket = session.authorize_cleanup(&operation, &[input]).unwrap();
    assert!(matches!(
        session.set_locked(
            session.metadata.revision,
            groups[0].members[1].clone(),
            true
        ),
        Err(CoreError::InvalidState)
    ));
    assert!(matches!(
        session.apply_intent(
            session.metadata.revision,
            &signature,
            "late".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Pending
            }
        ),
        Err(CoreError::InvalidState)
    ));
    assert!(matches!(
        session.reset_progress(session.metadata.revision),
        Err(CoreError::InvalidState)
    ));
    settings.similar_scenes_enabled = true;
    assert!(matches!(
        session.save_settings(session.metadata.revision, settings),
        Err(CoreError::InvalidState)
    ));
    session
        .save_position(
            session.metadata.revision,
            1,
            Some(signature.clone()),
            Some(0),
        )
        .unwrap();
    assert_eq!(session.validate_cleanup_ticket(&ticket), Ok(()));
    assert_eq!(
        session.report_cleanup(
            &ticket,
            vec![CleanupOutcome::Skipped(CleanupReason::Inaccessible)]
        ),
        Ok(true)
    );
    let before = session.metadata.clone();
    session.finish_cleanup(&operation).unwrap();
    assert_eq!(session.metadata, before);
    assert_eq!(session.query_count().unwrap(), 3);
    assert_eq!(session.decisions.len(), 1);
}
#[test]
fn partial_cleanup_commit_invalidates_results_and_only_affected_choices_durably() {
    use crate::cleanup::run::CleanupOutcome;
    let (scratch, mut session, groups) = scanned();
    for (index, group) in groups.iter().enumerate() {
        session
            .apply_intent(
                session.metadata.revision,
                &group.signature().unwrap(),
                format!("confirm-{index}"),
                ReviewIntent::ConfirmKeep {
                    keep: group.preferred.clone(),
                },
            )
            .unwrap();
    }
    let operation = session.start_cleanup(session.metadata.revision).unwrap();
    let input = cleanup_input(&session, &groups[0]);
    let ticket = session.authorize_cleanup(&operation, &[input]).unwrap();
    session
        .report_cleanup(&ticket, vec![CleanupOutcome::MovedToTrash])
        .unwrap();
    session.cancel_cleanup(&operation).unwrap();
    let results = session.finish_cleanup(&operation).unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results.iter().filter(|r| r.outcome.moved()).count(), 1);
    assert_eq!(session.decisions.len(), 2);
    assert_eq!(session.query_count().unwrap(), 0);
    let stale = ticket;
    assert_eq!(
        session.validate_cleanup_ticket(&stale),
        Err(crate::cleanup::CleanupReason::StalePlan)
    );
    drop(session);
    let mut session = ReviewSession::open(&scratch.db(), true).unwrap();
    assert_eq!(session.decisions.len(), 2);
    assert_eq!(session.query_count().unwrap(), 0);
    assert!(matches!(
        session.start_cleanup(session.metadata.revision),
        Err(CoreError::InvalidValue)
    ));
}
#[test]
fn failed_cleanup_completion_keeps_committed_choices_and_retains_actual_outcomes_for_display() {
    use crate::cleanup::run::CleanupOutcome;
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep {
                keep: groups[0].preferred.clone(),
            },
        )
        .unwrap();
    let before = session.metadata.clone();
    let operation = session.start_cleanup(before.revision).unwrap();
    let input = cleanup_input(&session, &groups[0]);
    let ticket = session.authorize_cleanup(&operation, &[input]).unwrap();
    session
        .report_cleanup(&ticket, vec![CleanupOutcome::MovedToTrash])
        .unwrap();
    session.store.testing_connection().execute_batch("CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        session.finish_cleanup(&operation),
        Err(CoreError::WriteFailed)
    ));
    assert!(!session.healthy());
    assert_eq!(session.metadata, before);
    assert_eq!(session.decisions.len(), 1);
    assert_eq!(session.cleanup.as_ref().unwrap().outcomes().len(), 1);
    let loaded = session.store.load().unwrap();
    assert_eq!(loaded.metadata, before);
    assert_eq!(loaded.decisions.len(), 1);
    assert!(loaded.groups.iter().all(|g| g.active));
}
#[test]
fn cancelled_cleanup_reports_actual_os_completion_and_cannot_authorize_more_items() {
    use crate::cleanup::{CleanupReason, run::CleanupOutcome};
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep {
                keep: groups[0].preferred.clone(),
            },
        )
        .unwrap();
    let operation = session.start_cleanup(session.metadata.revision).unwrap();
    let input = cleanup_input(&session, &groups[0]);
    let ticket = session
        .authorize_cleanup(&operation, std::slice::from_ref(&input))
        .unwrap();
    session.cancel_cleanup(&operation).unwrap();
    assert_eq!(
        session.validate_cleanup_ticket(&ticket),
        Err(CleanupReason::Cancelled)
    );
    assert!(matches!(
        session.finish_cleanup(&operation),
        Err(CoreError::InvalidState)
    ));
    session
        .report_cleanup(&ticket, vec![CleanupOutcome::MovedToTrash])
        .unwrap();
    assert_eq!(
        session.authorize_cleanup(&operation, &[input]),
        Err(CleanupReason::Cancelled)
    );
    let results = session.finish_cleanup(&operation).unwrap();
    assert_eq!(results[0].outcome, CleanupOutcome::MovedToTrash);
    assert!(session.decisions.is_empty());
}

#[test]
fn late_native_callbacks_cannot_match_a_later_cleanup_run_even_when_item_indices_repeat() {
    use crate::cleanup::{CleanupReason, run::CleanupOutcome};
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep {
                keep: groups[0].preferred.clone(),
            },
        )
        .unwrap();
    let first = session.start_cleanup(session.metadata.revision).unwrap();
    let input = cleanup_input(&session, &groups[0]);
    let old = session
        .authorize_cleanup(&first, std::slice::from_ref(&input))
        .unwrap();
    session
        .report_cleanup(&old, vec![CleanupOutcome::Failed])
        .unwrap();
    session.finish_cleanup(&first).unwrap();
    let second = session.start_cleanup(session.metadata.revision).unwrap();
    assert_ne!(first, second);
    let current = session.authorize_cleanup(&second, &[input]).unwrap();
    assert_eq!(
        session.report_cleanup(&old, vec![CleanupOutcome::MovedToTrash]),
        Err(CleanupReason::StalePlan)
    );
    assert_eq!(session.validate_cleanup_ticket(&current), Ok(()));
    session
        .report_cleanup(&current, vec![CleanupOutcome::Failed])
        .unwrap();
    session.finish_cleanup(&second).unwrap();
}

#[test]
fn bounded_read_only_snapshots_are_atomic_and_late_or_duplicate_batches_do_not_apply() {
    let (_scratch, mut session, groups) = scanned();
    let source = groups[0].preferred.source_id.clone();
    let before = session.metadata.clone();
    session
        .begin_read_only_snapshot(before.revision, "policy".into(), &source)
        .unwrap();
    assert!(matches!(
        session.append_read_only_snapshot("policy", vec![groups[0].members[0].clone(); 17]),
        Err(CoreError::InvalidBuffer)
    ));
    session
        .append_read_only_snapshot("policy", groups[0].members.clone())
        .unwrap();
    assert_eq!(session.protection.policies().count(), 0);
    assert!(matches!(
        session.append_read_only_snapshot("policy", vec![groups[0].members[0].clone()]),
        Err(CoreError::InvalidValue)
    ));
    assert!(matches!(
        session.discard_read_only_snapshot("old"),
        Err(CoreError::StaleOperation)
    ));
    assert_eq!(session.metadata, before);
    session.finish_read_only_snapshot("policy", true).unwrap();
    assert_eq!(
        session.protection.policies().next().unwrap().members,
        groups[0].members
    );
    let current = session.metadata.clone();
    session
        .begin_read_only_snapshot(current.revision, "cancel".into(), &source)
        .unwrap();
    session
        .append_read_only_snapshot("cancel", groups[1].members.clone())
        .unwrap();
    session.discard_read_only_snapshot("cancel").unwrap();
    assert_eq!(session.metadata, current);
    assert_eq!(
        session.protection.policies().next().unwrap().members,
        groups[0].members
    );
    session
        .begin_read_only_snapshot(current.revision, "late".into(), &source)
        .unwrap();
    let mut settings = session.settings.clone();
    settings.similar_scenes_enabled = true;
    session.save_settings(current.revision, settings).unwrap();
    assert!(matches!(
        session.finish_read_only_snapshot("late", true),
        Err(CoreError::StaleOperation)
    ));
}
#[test]
fn cancelled_or_failed_read_only_snapshot_keeps_old_policy_and_choices() {
    let (_scratch, mut session, groups) = scanned();
    let source = groups[0].preferred.source_id.clone();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "confirm".into(),
            ReviewIntent::ConfirmKeep {
                keep: groups[0].preferred.clone(),
            },
        )
        .unwrap();
    let before = session.metadata.clone();
    session
        .begin_read_only_snapshot(before.revision, "policy".into(), &source)
        .unwrap();
    session
        .append_read_only_snapshot("policy", groups[0].members.clone())
        .unwrap();
    session.store.testing_connection().execute_batch("CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        session.finish_read_only_snapshot("policy", true),
        Err(CoreError::WriteFailed)
    ));
    assert!(!session.healthy());
    assert_eq!(session.metadata, before);
    assert_eq!(session.protection.policies().count(), 0);
    assert!(!session.decisions[&signature].decision.removals.is_empty());
    let loaded = session.store.load().unwrap();
    assert_eq!(loaded.protection.policies().count(), 0);
    assert!(!loaded.decisions[0].decision.removals.is_empty());
}

#[test]
fn current_photokit_capture_dates_are_checked_by_core_even_when_native_scope_flag_is_true() {
    use crate::{
        cleanup::{CleanupReason, ComparisonProof, PairFacts, run::CleanupItemKey},
        review::CaptureRange,
    };
    let scratch = Scratch::new();
    let mut session = ReviewSession::open(&scratch.db(), false).unwrap();
    let source = session
        .register_source(
            1,
            SourceInput {
                kind: SourceKind::PhotoLibrary,
                namespace: "test.photos".into(),
                identity: vec![1],
                bookmark: vec![],
                label: "Photos".into(),
            },
        )
        .unwrap();
    let mut settings = session.settings.clone();
    settings.photo_scope.dates = Some(CaptureRange {
        start: 0.0,
        end: 10.0,
        includes_unknown: false,
    });
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    let mut group = group(&source.id, "photos", Some(5.0), Some(100));
    for asset in &mut group.members {
        asset.kind = SourceKind::PhotoLibrary;
    }
    session
        .complete_scan(session.metadata.revision, vec![group.clone()])
        .unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &group.signature().unwrap(),
            "all".into(),
            ReviewIntent::ConfirmDeleteAll,
        )
        .unwrap();
    let operation = session.start_cleanup(session.metadata.revision).unwrap();
    let mut facts = group
        .members
        .iter()
        .map(|a| cleanup_facts(&session, a))
        .collect::<Vec<_>>();
    session.begin_cleanup_preflight(&operation, 0).unwrap();
    facts[1].asset.capture_date = Some(20.0);
    assert_eq!(
        session.append_cleanup_preflight(&operation, 0, &facts),
        Err(CleanupReason::ChangedAsset)
    );
    facts[1].asset.capture_date = Some(5.0);
    session
        .append_cleanup_preflight(&operation, 0, &facts)
        .unwrap();
    session.finish_cleanup_preflight(&operation, 0).unwrap();
    facts[1].asset.capture_date = Some(20.0);
    assert_eq!(
        session.preflight_cleanup_group(&operation, 0, &facts),
        Err(CleanupReason::ChangedAsset)
    );
    assert_eq!(
        session.authorize_cleanup(
            &operation,
            &[(
                CleanupItemKey { group: 0, pair: 0 },
                PairFacts {
                    keep: None,
                    remove: facts[0].clone(),
                    proof: ComparisonProof::WholeGroup
                }
            )]
        ),
        Err(CleanupReason::InvalidSelection)
    );
    facts[1].asset.capture_date = Some(5.0);
    session
        .preflight_cleanup_group(&operation, 0, &facts)
        .unwrap();
    for date in [None, Some(20.0)] {
        let mut changed = facts[0].clone();
        changed.asset.capture_date = date;
        assert_eq!(
            session.authorize_cleanup(
                &operation,
                &[(
                    CleanupItemKey { group: 0, pair: 0 },
                    PairFacts {
                        keep: None,
                        remove: changed,
                        proof: ComparisonProof::WholeGroup
                    }
                )]
            ),
            Err(CleanupReason::ChangedAsset)
        );
    }
    assert_eq!(
        session.authorize_cleanup("old", &[]),
        Err(CleanupReason::StalePlan)
    );
}

#[test]
fn presentation_large_group_has_only_preferred_and_saved_keeper_previews() {
    let (_scratch, mut session, groups) = scanned();
    let mut large = groups[0].clone();
    for index in 2..1000 {
        let mut asset = large.members[1].clone();
        asset.id.item_id = format!("large-{index}");
        asset.name = format!("{index}.png");
        large
            .duplicates
            .push((asset.id.clone(), MatchKind::ExactDuplicate));
        large.members.push(asset);
    }
    large.evidence.push(crate::review::ReviewEvidence {
        asset: large.preferred.clone(),
        width: 120,
        height: 80,
        bit_depth: Some(8),
        wide_color: false,
        edge_detail: Some(0.1),
        capture_date: Some(1.0),
    });
    session
        .complete_scan(session.metadata.revision, vec![large.clone()])
        .unwrap();
    let (_, total, page) = session
        .presentation_page(ReviewPageMode::Visible, 0, 256)
        .unwrap();
    assert_eq!(total, 1);
    assert_eq!(page[0].member_count, 1000);
    assert_eq!(page[0].preview_assets, vec![large.members[0].clone()]);
    assert_eq!(page[0].preferred_evidence, Some(large.evidence[0].clone()));
    assert_eq!(page[0].saved_removal_count, 0);
    let signature = page[0].signature.clone();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "large-keep".into(),
            ReviewIntent::ConfirmKeep {
                keep: large.members[999].id.clone(),
            },
        )
        .unwrap();
    let (_, _, page) = session
        .presentation_page(ReviewPageMode::Visible, 0, 1)
        .unwrap();
    assert_eq!(
        page[0].preview_assets,
        vec![large.members[0].clone(), large.members[999].clone()]
    );
    assert_eq!(page[0].saved_removal_count, 999);
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "clear".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Pending,
            },
        )
        .unwrap();
    let (_, _, page) = session
        .presentation_page(ReviewPageMode::Visible, 0, 1)
        .unwrap();
    assert_eq!(page[0].preview_assets.len(), 1);
    assert_eq!(page[0].saved_removal_count, 0);
}

#[test]
fn presentation_estimates_and_skipped_groups_do_not_become_cleanup_candidates() {
    let (_scratch, mut session, groups) = scanned();
    let signature = groups[0].signature().unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &signature,
            "skip-without-keep".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Deferred,
            },
        )
        .unwrap();
    let (overview, total, page) = session
        .presentation_page(ReviewPageMode::CleanupCandidates, 0, 256)
        .unwrap();
    assert_eq!(overview.duplicate_groups, 3);
    assert_eq!(overview.pending_groups, 3);
    assert_eq!(overview.saved_removals, 0);
    assert_eq!(total, 0);
    assert!(page.is_empty());
    let (_, _, page) = session
        .presentation_page(ReviewPageMode::Visible, 0, 1)
        .unwrap();
    assert_eq!(page[0].estimate.known_bytes, 100);
    assert_eq!(page[0].saved_removal_count, 0);
}

#[test]
fn presentation_saved_deferred_choices_and_hidden_filters_follow_cleanup_semantics() {
    let (_scratch, mut session, groups) = scanned();
    for (index, group) in groups.iter().take(2).enumerate() {
        session
            .apply_intent(
                session.metadata.revision,
                &group.signature().unwrap(),
                format!("confirm-{index}"),
                ReviewIntent::ConfirmKeep {
                    keep: group.members[1].id.clone(),
                },
            )
            .unwrap();
    }
    session
        .apply_intent(
            session.metadata.revision,
            &groups[1].signature().unwrap(),
            "saved-defer".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Deferred,
            },
        )
        .unwrap();
    session
        .apply_intent(
            session.metadata.revision,
            &groups[2].signature().unwrap(),
            "keep-all".into(),
            ReviewIntent::SetStatus {
                status: ReviewStatus::Kept,
            },
        )
        .unwrap();
    let (overview, total, page) = session
        .presentation_page(ReviewPageMode::Pending, 0, 256)
        .unwrap();
    assert_eq!(overview.saved_removals, 2);
    assert_eq!(overview.candidate_groups, 2);
    assert_eq!(overview.visible_groups, 2);
    assert_eq!(total, 1);
    assert_eq!(page[0].preferred, groups[1].preferred);
    assert_eq!(page[0].saved_removal_count, 1);
    assert_eq!(page[0].confirmed_removal_count, 0);
    let mut settings = session.settings.clone();
    settings.query.status = StatusFilter::Confirmed;
    settings.query.sort = ReviewSort::Newest;
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    let (overview, total, _) = session
        .presentation_page(ReviewPageMode::Visible, 0, 256)
        .unwrap();
    assert_eq!(overview.visible_groups, 1);
    assert_eq!(overview.hidden_saved_removals, 1);
    assert_eq!(total, 1);
    assert_eq!(
        session
            .presentation_page(ReviewPageMode::Pending, 0, 256)
            .unwrap()
            .1,
        0
    );
    let (_, total, page) = session
        .presentation_page(ReviewPageMode::CleanupCandidates, 0, 1)
        .unwrap();
    assert_eq!(total, 2);
    assert_eq!(page[0].preferred, groups[0].preferred);
    assert_eq!(
        session
            .presentation_page(ReviewPageMode::CleanupCandidates, 1, 1)
            .unwrap()
            .2[0]
            .preferred,
        groups[1].preferred
    );
}

#[test]
fn presentation_scene_counts_and_lock_provenance_remain_core_owned_and_paged() {
    let (_scratch, mut session, mut groups) = scanned();
    groups[1].scene = Some(crate::model::SceneProvider {
        provider_id: "fixture".into(),
        model_revision: "2".into(),
        preprocessing: "fixed".into(),
        platform_compatibility: "test".into(),
    });
    groups[1].duplicates[0].1 = MatchKind::SceneSimilar;
    let scene_edge = crate::scene_session::SceneEdge {
        first: groups[1].members[0].id.clone(),
        second: groups[1].members[1].id.clone(),
        distance: 0.1,
        shared_burst: false,
    };
    groups[1].scene_matches.push(scene_edge);
    let mut settings = session.settings.clone();
    settings.similar_scenes_enabled = true;
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    groups[0].members[0].native_identity = Some("opaque.alias.fixture".into());
    groups[0].members[1].native_identity = Some("opaque.alias.fixture".into());
    session
        .complete_scan(session.metadata.revision, groups.clone())
        .unwrap();
    session
        .set_locked(
            session.metadata.revision,
            groups[0].members[0].clone(),
            true,
        )
        .unwrap();
    let (overview, total, _) = session
        .presentation_page(ReviewPageMode::Visible, 0, 256)
        .unwrap();
    assert_eq!(overview.duplicate_groups, 2);
    assert_eq!(overview.scene_groups, 1);
    assert_eq!(total, 2);
    assert!(session.protection.locked(&groups[0].members[1]));
    assert_eq!(
        session
            .lock_owners_page(&groups[0].members[1], 0, 1)
            .unwrap(),
        vec![groups[0].members[0].id.clone()]
    );
    assert!(
        session
            .lock_owners_page(&groups[0].members[1], usize::MAX, 256)
            .unwrap()
            .is_empty()
    );
    let mut settings = session.settings.clone();
    settings.query.collection = crate::review::ReviewCollection::SimilarScenes;
    session
        .save_settings(session.metadata.revision, settings)
        .unwrap();
    let (_, total, page) = session
        .presentation_page(ReviewPageMode::Visible, 0, 256)
        .unwrap();
    assert_eq!(total, 1);
    assert_eq!(page[0].kind, MatchKind::SceneSimilar);
}

#[test]
fn presentation_page_limits_offsets_and_read_only_navigation_do_not_mutate_state() {
    let (_scratch, mut session, groups) = scanned();
    let before = session.metadata.clone();
    for mode in [
        ReviewPageMode::Visible,
        ReviewPageMode::Pending,
        ReviewPageMode::CleanupCandidates,
    ] {
        for limit in [0, 257] {
            assert!(matches!(
                session.presentation_page(mode, 0, limit),
                Err(CoreError::InvalidBuffer)
            ));
        }
        assert!(
            session
                .presentation_page(mode, usize::MAX, 256)
                .unwrap()
                .2
                .is_empty()
        );
    }
    for limit in [0, 257] {
        assert!(matches!(
            session.lock_owners_page(&groups[0].members[0], 0, limit),
            Err(CoreError::InvalidBuffer)
        ));
    }
    assert_eq!(session.metadata, before);
    assert_eq!(session.navigation_sequence, 0);
    assert_eq!(session.query_count().unwrap(), 3);
}
