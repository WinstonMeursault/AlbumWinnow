use super::*;
use crate::{model::AssetId, review::SourceKind};
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
            "albumwinnow-v2-review-{}-{stamp}-{sequence}",
            std::process::id()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn db(&self) -> PathBuf {
        self.0.join("v2/review.sqlite")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[test]
fn first_install_and_v2_restart_have_explicit_complete_state() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    let first = store.load().unwrap();
    assert_eq!(first.metadata.revision, 1);
    assert_eq!(first.metadata.scan_generation, 0);
    assert!(first.sources.is_empty() && first.groups.is_empty() && first.decisions.is_empty());
    assert_eq!(first.protection.locks().count(), 0);
    assert_eq!(first.protection.policies().count(), 0);
    assert_eq!(first.settings, ReviewSettings::default());
    assert!(first.anchor.is_none() && first.position.is_none());
    drop(store);
    let mut store = ReviewStore::open(&scratch.db(), true).unwrap();
    assert_eq!(store.load().unwrap().metadata, first.metadata);
    assert_eq!(
        store
            .connection
            .pragma_query_value::<i32, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        1
    );
}
#[test]
fn initialized_but_missing_or_empty_database_never_becomes_empty_protection() {
    let scratch = Scratch::new();
    assert!(matches!(
        ReviewStore::open(&scratch.db(), true),
        Err(CoreError::ProtectionUnavailable)
    ));
    assert!(!scratch.db().exists());
    std::fs::create_dir_all(scratch.db().parent().unwrap()).unwrap();
    std::fs::write(scratch.db(), []).unwrap();
    assert!(matches!(
        ReviewStore::open(&scratch.db(), true),
        Err(CoreError::ProtectionUnavailable)
    ));
    assert_eq!(std::fs::metadata(scratch.db()).unwrap().len(), 0);
}
#[test]
fn corrupt_foreign_and_unknown_schemas_are_neither_repaired_nor_deleted() {
    let scratch = Scratch::new();
    std::fs::create_dir_all(scratch.db().parent().unwrap()).unwrap();
    let bytes = b"corrupt protection must not be reset";
    std::fs::write(scratch.db(), bytes).unwrap();
    assert!(matches!(
        ReviewStore::open(&scratch.db(), false),
        Err(CoreError::StorageCorrupt)
    ));
    assert_eq!(std::fs::read(scratch.db()).unwrap(), bytes);
    let foreign = scratch.0.join("old.sqlite");
    let db = Connection::open(&foreign).unwrap();
    db.execute_batch(
        "CREATE TABLE old_data(value TEXT); INSERT INTO old_data VALUES('untouched');",
    )
    .unwrap();
    drop(db);
    let bytes = std::fs::read(&foreign).unwrap();
    assert!(matches!(
        ReviewStore::open(&foreign, false),
        Err(CoreError::UnsupportedSchema)
    ));
    assert_eq!(std::fs::read(&foreign).unwrap(), bytes);
    let fresh = scratch.0.join("fresh.sqlite");
    let store = ReviewStore::open(&fresh, false).unwrap();
    drop(store);
    let db = Connection::open(&fresh).unwrap();
    db.pragma_update(None, "user_version", 999).unwrap();
    drop(db);
    assert!(matches!(
        ReviewStore::open(&fresh, true),
        Err(CoreError::UnsupportedSchema)
    ));
    let db = Connection::open(fresh).unwrap();
    assert_eq!(
        db.pragma_query_value::<i32, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        999
    );
}
#[test]
fn missing_required_rows_fail_closed_and_a_replaced_live_file_is_detected() {
    for table in ["meta", "settings", "navigation"] {
        let scratch = Scratch::new();
        let store = ReviewStore::open(&scratch.db(), false).unwrap();
        drop(store);
        let db = Connection::open(scratch.db()).unwrap();
        db.execute(&format!("DELETE FROM {table}"), []).unwrap();
        drop(db);
        assert!(ReviewStore::open(&scratch.db(), true).is_err());
    }
    let scratch = Scratch::new();
    let store = ReviewStore::open(&scratch.db(), false).unwrap();
    let moved = scratch.0.join("moved-review.sqlite");
    std::fs::rename(scratch.db(), moved).unwrap();
    assert_eq!(
        store.verify_current(),
        Err(CoreError::ProtectionUnavailable)
    );
    std::fs::write(scratch.db(), []).unwrap();
    assert_eq!(
        store.verify_current(),
        Err(CoreError::ProtectionUnavailable)
    );
}
#[test]
fn deleting_saved_protection_is_detected_in_live_and_reopened_sessions() {
    let scratch = Scratch::new();
    drop(ReviewStore::open(&scratch.db(), false).unwrap());
    let source = SourceRecord {
        id: "opaque-source".into(),
        kind: SourceKind::ControlledTest,
        native_namespace: "controlled".into(),
        native_identity: vec![1],
        bookmark: vec![],
        label: "Fixture".into(),
        active: true,
    };
    let asset = ReviewAsset {
        id: AssetId {
            source_id: source.id.clone(),
            item_id: "locked".into(),
        },
        name: "Locked".into(),
        revision: "r1".into(),
        kind: source.kind,
        properties: None,
        byte_count: None,
        capture_date: None,
        burst: None,
        native_identity: None,
        link_count: None,
    };
    let db = Connection::open(scratch.db()).unwrap();
    db.execute(
        "INSERT INTO sources VALUES(?1,?2)",
        params![source.id, encode(&source).unwrap()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO locks VALUES(?1,?2,?3)",
        params![
            asset.id.source_id,
            asset.id.item_id,
            encode(&asset).unwrap()
        ],
    )
    .unwrap();
    db.execute(
        "UPDATE meta SET source_count=1,protection_hash=?1",
        params![protection_digest(&db).unwrap().as_slice()],
    )
    .unwrap();
    drop(db);
    let mut store = ReviewStore::open(&scratch.db(), true).unwrap();
    assert_eq!(store.load().unwrap().protection.locks().count(), 1);
    let db = Connection::open(scratch.db()).unwrap();
    db.execute("DELETE FROM locks", []).unwrap();
    drop(db);
    assert_eq!(
        store.verify_current(),
        Err(CoreError::ProtectionUnavailable)
    );
    drop(store);
    assert!(matches!(
        ReviewStore::open(&scratch.db(), true),
        Err(CoreError::ProtectionUnavailable)
    ));
}
#[test]
fn integrity_keys_are_length_prefixed_even_with_embedded_nul() {
    let scratch = Scratch::new();
    let store = ReviewStore::open(&scratch.db(), false).unwrap();
    let db = &store.connection;
    db.execute("INSERT INTO locks VALUES(?1,?2,X'00')", params!["a\0", "b"])
        .unwrap();
    let first = protection_digest(db).unwrap();
    db.execute("DELETE FROM locks", []).unwrap();
    db.execute("INSERT INTO locks VALUES(?1,?2,X'00')", params!["a", "\0b"])
        .unwrap();
    assert_ne!(first, protection_digest(db).unwrap());
}
#[test]
fn source_registration_reuses_native_identity_and_persists_new_v2_ids() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    let first = store
        .register_source(
            1,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![0, 1, 0],
            vec![1],
            "Display path A".into(),
        )
        .unwrap();
    assert!(first.source.id.starts_with("source.v2."));
    assert_eq!(first.metadata.source_count, 1);
    let id = first.source.id.clone();
    let second = store
        .register_source(
            first.metadata.revision,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![0, 1, 0],
            vec![2],
            "Display path B".into(),
        )
        .unwrap();
    assert_eq!(second.source.id, id);
    assert_eq!(second.metadata.source_count, 1);
    assert!(second.metadata.scope_epoch > first.metadata.scope_epoch);
    let same = store
        .register_source(
            second.metadata.revision,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![0, 1, 0],
            vec![2],
            "Display path B".into(),
        )
        .unwrap();
    assert_eq!(same.metadata, second.metadata);
    let inactive = store
        .set_source_active(same.metadata.revision, &id, false)
        .unwrap();
    assert!(!inactive.source.active);
    let restored = store
        .register_source(
            inactive.metadata.revision,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![0, 1, 0],
            vec![3],
            "Reconnected".into(),
        )
        .unwrap();
    assert_eq!(restored.source.id, id);
    assert!(restored.source.active);
    drop(store);
    let mut store = ReviewStore::open(&scratch.db(), true).unwrap();
    let snapshot = store.load().unwrap();
    assert_eq!(snapshot.sources.len(), 1);
    assert_eq!(snapshot.sources[0].id, id);
    assert_eq!(snapshot.sources[0].bookmark, vec![3]);
}
#[test]
fn source_display_names_do_not_merge_distinct_native_directories() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    let first = store
        .register_source(
            1,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![1],
            vec![],
            "Same name".into(),
        )
        .unwrap();
    let second = store
        .register_source(
            first.metadata.revision,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![2],
            vec![],
            "Same name".into(),
        )
        .unwrap();
    assert_ne!(first.source.id, second.source.id);
    assert_eq!(second.metadata.source_count, 2);
    assert!(matches!(
        store.register_source(
            1,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![3],
            vec![],
            "Late".into()
        ),
        Err(CoreError::StaleOperation)
    ));
    assert_eq!(store.load().unwrap().sources.len(), 2);
}
#[test]
fn invalid_source_registration_and_transaction_failure_leave_no_partial_state() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    assert!(matches!(
        store.register_source(
            1,
            SourceKind::ControlledTest,
            "".into(),
            vec![1],
            vec![],
            "Bad".into()
        ),
        Err(CoreError::InvalidValue)
    ));
    assert!(store.load().unwrap().sources.is_empty());
    store.connection.execute_batch("CREATE TRIGGER fail_source BEFORE INSERT ON sources BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        store.register_source(
            1,
            SourceKind::ControlledTest,
            "controlled".into(),
            vec![1],
            vec![],
            "Failure".into()
        ),
        Err(CoreError::WriteFailed)
    ));
    let snapshot = store.load().unwrap();
    assert_eq!(snapshot.metadata.revision, 1);
    assert_eq!(snapshot.metadata.source_count, 0);
    assert!(snapshot.sources.is_empty());
}
#[test]
fn navigation_only_writes_its_row_and_rejects_late_or_conflicting_callbacks() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    let before = store.load().unwrap();
    let changes = store.connection.total_changes();
    store
        .save_position(before.metadata.revision, 1, Some("anchor".into()), Some(3))
        .unwrap();
    assert_eq!(store.connection.total_changes() - changes, 1);
    let after = store.load().unwrap();
    assert_eq!(after.metadata, before.metadata);
    assert_eq!(after.anchor.as_deref(), Some("anchor"));
    assert_eq!(after.position, Some(3));
    assert_eq!(after.navigation_sequence, 1);
    let changes = store.connection.total_changes();
    store
        .save_position(1, 1, Some("anchor".into()), Some(3))
        .unwrap();
    assert_eq!(store.connection.total_changes(), changes);
    assert_eq!(
        store.save_position(1, 0, Some("old".into()), None),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(
        store.save_position(1, 1, Some("conflict".into()), None),
        Err(CoreError::StaleOperation)
    );
    assert_eq!(store.load().unwrap().anchor.as_deref(), Some("anchor"));
}
#[test]
fn navigation_cannot_initialize_or_repair_missing_protection_state() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    store.connection.execute("DELETE FROM meta", []).unwrap();
    assert_eq!(
        store.save_position(1, 1, Some("anchor".into()), None),
        Err(CoreError::ProtectionUnavailable)
    );
    assert_eq!(
        store
            .connection
            .query_row::<i64, _, _>("SELECT count(*) FROM meta", [], |r| r.get(0))
            .unwrap(),
        0
    );
}
#[test]
fn failed_navigation_is_not_acknowledged_as_committed() {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    store
        .connection
        .execute_batch("PRAGMA query_only=ON;")
        .unwrap();
    assert_eq!(
        store.save_position(1, 1, Some("anchor".into()), None),
        Err(CoreError::WriteFailed)
    );
    let snapshot = store.load().unwrap();
    assert!(snapshot.anchor.is_none());
    assert_eq!(snapshot.navigation_sequence, 0);
}
fn sample_group(source: &str, a: &str, b: &str) -> ReviewGroup {
    use crate::{matching::MatchKind, review::ReviewAsset};
    let asset = |item: &str| ReviewAsset {
        id: AssetId {
            source_id: source.into(),
            item_id: item.into(),
        },
        name: item.into(),
        revision: "r1".into(),
        kind: SourceKind::ControlledTest,
        properties: None,
        byte_count: Some(100),
        capture_date: None,
        burst: None,
        native_identity: None,
        link_count: None,
    };
    let a = asset(a);
    let b = asset(b);
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
fn scanned_store() -> (Scratch, ReviewStore, ReviewGroup, String, ReviewMetadata) {
    let scratch = Scratch::new();
    let mut store = ReviewStore::open(&scratch.db(), false).unwrap();
    let source = store
        .register_source(
            1,
            SourceKind::ControlledTest,
            "controlled.dir".into(),
            vec![1],
            vec![],
            "Fixture".into(),
        )
        .unwrap();
    let group = sample_group(&source.source.id, "a", "b");
    let signature = group.signature().unwrap();
    let metadata = store
        .complete_scan(source.metadata.revision, vec![group.clone()])
        .unwrap();
    (scratch, store, group, signature, metadata)
}
#[test]
fn decision_commit_is_incremental_durable_and_exact_retries_are_idempotent() {
    let (scratch, mut store, group, signature, before) = scanned_store();
    let decision = ReviewDecision::confirm(
        &group,
        Some(group.preferred.clone()),
        false,
        &ProtectionState::default(),
    )
    .unwrap();
    let changes = store.connection.total_changes();
    let committed = store
        .save_decision(
            before.revision,
            &signature,
            decision.clone(),
            "confirm-1".into(),
            [1; 32],
        )
        .unwrap();
    assert!(!committed.replayed);
    assert_eq!(committed.metadata.decision_count, 1);
    assert_eq!(store.connection.total_changes() - changes, 2);
    let changes = store.connection.total_changes();
    let retry = store
        .save_decision(
            before.revision,
            &signature,
            decision.clone(),
            "confirm-1".into(),
            [1; 32],
        )
        .unwrap();
    assert!(retry.replayed);
    assert_eq!(retry.metadata, committed.metadata);
    assert_eq!(store.connection.total_changes(), changes);
    assert!(matches!(
        store.save_decision(
            committed.metadata.revision,
            &signature,
            decision.clone(),
            "confirm-1".into(),
            [2; 32]
        ),
        Err(CoreError::InvalidValue)
    ));
    drop(store);
    let mut store = ReviewStore::open(&scratch.db(), true).unwrap();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.decisions.len(), 1);
    assert_eq!(loaded.decisions[0].decision, decision);
    assert_eq!(loaded.decisions[0].command_id.as_deref(), Some("confirm-1"));
}
#[test]
fn obsolete_decision_retries_cannot_overwrite_a_new_manual_keep() {
    let (_scratch, mut store, group, signature, before) = scanned_store();
    let first = ReviewDecision::confirm(
        &group,
        Some(group.preferred.clone()),
        false,
        &ProtectionState::default(),
    )
    .unwrap();
    let committed = store
        .save_decision(
            before.revision,
            &signature,
            first.clone(),
            "first".into(),
            [1; 32],
        )
        .unwrap();
    let keep = group.duplicates[0].0.clone();
    let next = ReviewDecision::confirm(
        &group,
        Some(keep.clone()),
        false,
        &ProtectionState::default(),
    )
    .unwrap();
    store
        .save_decision(
            committed.metadata.revision,
            &signature,
            next,
            "next".into(),
            [2; 32],
        )
        .unwrap();
    assert!(matches!(
        store.save_decision(before.revision, &signature, first, "first".into(), [1; 32]),
        Err(CoreError::StaleOperation)
    ));
    assert_eq!(store.load().unwrap().decisions[0].decision.keep, Some(keep));
}
#[test]
fn rescans_preserve_manual_choices_but_changed_evidence_stays_invalidated() {
    use crate::matching::MatchKind;
    let (_scratch, mut store, group, signature, before) = scanned_store();
    let decision = ReviewDecision::confirm(
        &group,
        Some(group.preferred.clone()),
        false,
        &ProtectionState::default(),
    )
    .unwrap();
    let committed = store
        .save_decision(
            before.revision,
            &signature,
            decision.clone(),
            "confirm".into(),
            [1; 32],
        )
        .unwrap();
    let mut reordered = group.clone();
    reordered.preferred = group.duplicates[0].0.clone();
    reordered.duplicates = vec![(group.preferred.clone(), MatchKind::ExactDuplicate)];
    assert_eq!(reordered.signature().unwrap(), signature);
    let metadata = store
        .complete_scan(committed.metadata.revision, vec![reordered])
        .unwrap();
    assert_eq!(store.load().unwrap().decisions[0].decision, decision);
    let mut changed = group.clone();
    changed.members[1].revision = "r2".into();
    let metadata = store
        .complete_scan(metadata.revision, vec![changed])
        .unwrap();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.groups.len(), 2);
    assert!(loaded.decisions[0].decision.invalidated);
    store.complete_scan(metadata.revision, vec![group]).unwrap();
    assert!(
        store.load().unwrap().decisions[0].decision.invalidated,
        "Returning old revisions must not revive an invalidated choice"
    );
}
#[test]
fn scan_commit_preserves_result_order_and_rolls_back_partial_replacement() {
    let (_scratch, mut store, group, _signature, before) = scanned_store();
    let second = sample_group(&group.preferred.source_id, "c", "d");
    store.connection.execute_batch("CREATE TRIGGER fail_second_group BEFORE INSERT ON groups WHEN NEW.ordinal=1 BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert_eq!(
        store.complete_scan(before.revision, vec![second.clone(), group.clone()]),
        Err(CoreError::WriteFailed)
    );
    let loaded = store.load().unwrap();
    assert_eq!(loaded.metadata, before);
    assert_eq!(loaded.groups.len(), 1);
    assert_eq!(loaded.groups[0].group, group);
    store
        .connection
        .execute_batch("DROP TRIGGER fail_second_group;")
        .unwrap();
    store
        .complete_scan(before.revision, vec![second.clone(), group.clone()])
        .unwrap();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.groups[0].group, second);
    assert_eq!(loaded.groups[1].group, group);
}
#[test]
fn failed_decision_or_metadata_write_leaves_committed_state_unchanged() {
    for target in ["decisions", "meta"] {
        let (_scratch, mut store, group, signature, before) = scanned_store();
        let trigger = if target == "decisions" {
            "CREATE TRIGGER fail_write BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT,'injected'); END;"
        } else {
            "CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;"
        };
        store.connection.execute_batch(trigger).unwrap();
        let decision = ReviewDecision::confirm(
            &group,
            Some(group.preferred.clone()),
            false,
            &ProtectionState::default(),
        )
        .unwrap();
        assert!(matches!(
            store.save_decision(
                before.revision,
                &signature,
                decision,
                "failed".into(),
                [1; 32]
            ),
            Err(CoreError::WriteFailed)
        ));
        let loaded = store.load().unwrap();
        assert_eq!(loaded.metadata, before);
        assert!(loaded.decisions.is_empty());
        assert_eq!(loaded.groups.len(), 1);
    }
}
#[test]
fn a_source_scope_change_blocks_new_decisions_until_another_scan() {
    let (_scratch, mut store, group, signature, before) = scanned_store();
    let changed = store
        .set_source_active(before.revision, &group.preferred.source_id, false)
        .unwrap();
    let decision = ReviewDecision::confirm(
        &group,
        Some(group.preferred.clone()),
        false,
        &ProtectionState::default(),
    )
    .unwrap();
    assert!(matches!(
        store.save_decision(
            changed.metadata.revision,
            &signature,
            decision,
            "late".into(),
            [1; 32]
        ),
        Err(CoreError::StaleOperation)
    ));
    let loaded = store.load().unwrap();
    assert!(loaded.groups.iter().all(|group| !group.active));
    assert!(loaded.decisions.is_empty());
}
fn confirmed_store(
    delete_all: bool,
) -> (
    Scratch,
    ReviewStore,
    ReviewGroup,
    String,
    ReviewDecision,
    ReviewMetadata,
) {
    let (scratch, mut store, group, signature, before) = scanned_store();
    let decision = ReviewDecision::confirm(
        &group,
        (!delete_all).then(|| group.preferred.clone()),
        delete_all,
        &ProtectionState::default(),
    )
    .unwrap();
    let committed = store
        .save_decision(
            before.revision,
            &signature,
            decision.clone(),
            "confirm".into(),
            [1; 32],
        )
        .unwrap();
    (
        scratch,
        store,
        group,
        signature,
        decision,
        committed.metadata,
    )
}
#[test]
fn locking_prunes_atomically_and_unlocking_or_retry_never_restores_removals() {
    let (scratch, mut store, group, signature, original, before) = confirmed_store(false);
    let protection = ProtectionState::new(vec![group.members[1].clone()], vec![]).unwrap();
    let changed = store.save_protection(before.revision, &protection).unwrap();
    assert_eq!(
        changed.metadata.protection_epoch,
        before.protection_epoch + 1
    );
    assert_eq!(changed.metadata.decision_epoch, before.decision_epoch + 1);
    assert_eq!(changed.metadata.scope_epoch, before.scope_epoch);
    assert_eq!(changed.changed_decisions.len(), 1);
    assert!(changed.changed_decisions[0].1.removals.is_empty());
    let retry = store
        .save_decision(
            before.revision - 1,
            &signature,
            original,
            "confirm".into(),
            [1; 32],
        )
        .unwrap();
    assert!(retry.replayed && retry.decision.removals.is_empty());
    let unlocked = store
        .save_protection(changed.metadata.revision, &ProtectionState::default())
        .unwrap();
    assert!(unlocked.changed_decisions.is_empty());
    assert_eq!(
        unlocked.metadata.decision_epoch,
        changed.metadata.decision_epoch
    );
    drop(store);
    let loaded = ReviewStore::open(&scratch.db(), true)
        .unwrap()
        .load()
        .unwrap();
    assert_eq!(loaded.protection.locks().count(), 0);
    assert!(loaded.decisions[0].decision.removals.is_empty());
    assert_eq!(loaded.decisions[0].decision.keep, Some(group.preferred));
}
#[test]
fn read_only_policy_resets_delete_all_even_for_an_inactive_saved_group() {
    let (scratch, mut store, group, _signature, _decision, before) = confirmed_store(true);
    let inactive = store
        .set_source_active(before.revision, &group.preferred.source_id, false)
        .unwrap();
    let policy = ReadOnlyPolicy {
        source_id: group.preferred.source_id.clone(),
        kind: SourceKind::ControlledTest,
        snapshot_complete: true,
        members: group.members.clone(),
    };
    let protection = ProtectionState::new(vec![], vec![policy.clone()]).unwrap();
    let changed = store
        .save_protection(inactive.metadata.revision, &protection)
        .unwrap();
    assert_eq!(changed.changed_decisions[0].1, ReviewDecision::default());
    drop(store);
    let loaded = ReviewStore::open(&scratch.db(), true)
        .unwrap()
        .load()
        .unwrap();
    assert!(!loaded.groups[0].active);
    assert_eq!(loaded.protection.policies().next(), Some(&policy));
    assert_eq!(loaded.decisions[0].decision, ReviewDecision::default());
}
#[test]
fn protection_and_decision_writes_roll_back_together_at_every_write_boundary() {
    for trigger in [
        "CREATE TRIGGER fail_write BEFORE UPDATE ON decisions BEGIN SELECT RAISE(ABORT,'injected'); END;",
        "CREATE TRIGGER fail_write BEFORE INSERT ON locks BEGIN SELECT RAISE(ABORT,'injected'); END;",
        "CREATE TRIGGER fail_write BEFORE INSERT ON read_only_members BEGIN SELECT RAISE(ABORT,'injected'); END;",
        "CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;",
    ] {
        let (_scratch, mut store, group, _signature, original, before) = confirmed_store(false);
        store.connection.execute_batch(trigger).unwrap();
        let policy = ReadOnlyPolicy {
            source_id: group.preferred.source_id.clone(),
            kind: SourceKind::ControlledTest,
            snapshot_complete: true,
            members: group.members.clone(),
        };
        let protection =
            ProtectionState::new(vec![group.members[1].clone()], vec![policy]).unwrap();
        assert!(matches!(
            store.save_protection(before.revision, &protection),
            Err(CoreError::WriteFailed)
        ));
        let loaded = store.load().unwrap();
        assert_eq!(loaded.metadata, before);
        assert_eq!(loaded.protection.locks().count(), 0);
        assert_eq!(loaded.protection.policies().count(), 0);
        assert_eq!(loaded.decisions[0].decision, original);
    }
}
#[test]
fn protection_rejects_unknown_sources_and_stale_commands_without_writes() {
    let (_scratch, mut store, group, _signature, _original, before) = confirmed_store(false);
    let mut asset = group.members[0].clone();
    asset.id.source_id = "unregistered".into();
    let protection = ProtectionState::new(vec![asset], vec![]).unwrap();
    assert!(matches!(
        store.save_protection(before.revision, &protection),
        Err(CoreError::InvalidValue)
    ));
    assert!(matches!(
        store.save_protection(before.revision - 1, &ProtectionState::default()),
        Err(CoreError::StaleOperation)
    ));
    let changes = store.connection.total_changes();
    let unchanged = store
        .save_protection(before.revision, &ProtectionState::default())
        .unwrap();
    assert_eq!(store.connection.total_changes(), changes);
    assert_eq!(unchanged.metadata, before);
}

#[test]
fn query_and_cancel_settings_do_not_invalidate_scan_or_cleanup_epochs() {
    use crate::review::ReviewSort;
    let (_scratch, mut store, _group, _signature, _original, before) = confirmed_store(false);
    let mut settings = ReviewSettings::default();
    settings.query.sort = ReviewSort::Newest;
    settings.scan_cancelled_by_user = true;
    let changed = store.save_settings(before.revision, &settings).unwrap();
    assert_eq!(changed.revision, before.revision + 1);
    assert_eq!(changed.scope_epoch, before.scope_epoch);
    assert_eq!(changed.protection_epoch, before.protection_epoch);
    assert_eq!(changed.decision_epoch, before.decision_epoch);
    let loaded = store.load().unwrap();
    assert!(loaded.groups[0].active);
    assert_eq!(loaded.settings, settings);
}
#[test]
fn changed_scope_requires_rescan_and_preserves_decisions_until_evidence_is_known() {
    use crate::review::CaptureRange;
    let (_scratch, mut store, _group, _signature, original, before) = confirmed_store(false);
    let mut settings = ReviewSettings::default();
    settings.photo_scope.dates = Some(CaptureRange {
        start: 0.0,
        end: 10.0,
        includes_unknown: false,
    });
    let changed = store.save_settings(before.revision, &settings).unwrap();
    assert_eq!(changed.scope_epoch, before.scope_epoch + 1);
    assert_eq!(changed.decision_epoch, before.decision_epoch);
    let loaded = store.load().unwrap();
    assert!(!loaded.groups[0].active);
    assert_eq!(loaded.decisions[0].decision, original);
}
#[test]
fn invalid_or_failed_settings_never_partially_change_scan_scope() {
    let (_scratch, mut store, _group, _signature, _original, before) = confirmed_store(false);
    let mut settings = ReviewSettings {
        preferred_source: Some("unregistered".into()),
        ..ReviewSettings::default()
    };
    assert!(matches!(
        store.save_settings(before.revision, &settings),
        Err(CoreError::InvalidValue)
    ));
    settings.preferred_source = None;
    settings.similar_scenes_enabled = true;
    store.connection.execute_batch("CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        store.save_settings(before.revision, &settings),
        Err(CoreError::WriteFailed)
    ));
    let loaded = store.load().unwrap();
    assert_eq!(loaded.metadata, before);
    assert_eq!(loaded.settings, ReviewSettings::default());
    assert!(loaded.groups[0].active);
}
#[test]
fn reset_progress_retains_protection_and_blocks_late_navigation_and_decision_retries() {
    let (scratch, mut store, group, signature, original, before) = confirmed_store(false);
    let protection = ProtectionState::new(vec![group.members[0].clone()], vec![]).unwrap();
    let protected = store
        .save_protection(before.revision, &protection)
        .unwrap()
        .metadata;
    store
        .save_position(protected.revision, 10, Some(signature.clone()), Some(0))
        .unwrap();
    let reset = store.reset_progress(protected.revision).unwrap();
    assert_eq!(reset.protection_epoch, protected.protection_epoch);
    assert_eq!(reset.scope_epoch, protected.scope_epoch);
    assert!(matches!(
        store.save_decision(
            before.revision - 1,
            &signature,
            original,
            "confirm".into(),
            [1; 32]
        ),
        Err(CoreError::StaleOperation)
    ));
    assert!(matches!(
        store.save_position(reset.revision, 10, Some(signature), Some(0)),
        Err(CoreError::StaleOperation)
    ));
    drop(store);
    let loaded = ReviewStore::open(&scratch.db(), true)
        .unwrap()
        .load()
        .unwrap();
    assert_eq!(loaded.protection.locks().count(), 1);
    assert!(loaded.decisions.is_empty() && loaded.anchor.is_none() && loaded.position.is_none());
    assert_eq!(loaded.navigation_sequence, 11);
}
#[test]
fn remove_invalid_only_preserves_valid_choices_and_navigation() {
    let (_scratch, mut store, group, signature, _original, before) = confirmed_store(false);
    let mut changed = group.clone();
    changed.members[1].revision = "r2".into();
    let after_scan = store.complete_scan(before.revision, vec![changed]).unwrap();
    store
        .save_position(after_scan.revision, 1, Some(signature.clone()), Some(0))
        .unwrap();
    let cleaned = store.remove_invalid_decisions(after_scan.revision).unwrap();
    assert_eq!(cleaned.decision_count, 0);
    assert_eq!(cleaned.group_count, 1);
    let loaded = store.load().unwrap();
    assert!(loaded.decisions.is_empty());
    assert_eq!(loaded.anchor, Some(signature));
    let unchanged = store.remove_invalid_decisions(cleaned.revision).unwrap();
    assert_eq!(unchanged, cleaned);
}
#[test]
fn failed_reset_rolls_back_choices_and_navigation_together() {
    let (_scratch, mut store, _group, signature, original, before) = confirmed_store(false);
    store
        .save_position(before.revision, 3, Some(signature.clone()), Some(0))
        .unwrap();
    store.connection.execute_batch("CREATE TRIGGER fail_write BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(matches!(
        store.reset_progress(before.revision),
        Err(CoreError::WriteFailed)
    ));
    let loaded = store.load().unwrap();
    assert_eq!(loaded.metadata, before);
    assert_eq!(loaded.decisions[0].decision, original);
    assert_eq!(loaded.anchor, Some(signature));
    assert_eq!(loaded.navigation_sequence, 3);
}

#[test]
fn one_review_database_has_only_one_live_owner_including_hardlink_aliases() {
    let scratch = Scratch::new();
    let store = ReviewStore::open(&scratch.db(), false).unwrap();
    assert!(matches!(
        ReviewStore::open(&scratch.db(), true),
        Err(CoreError::ProtectionUnavailable)
    ));
    let alias = scratch.0.join("alias.sqlite");
    std::fs::hard_link(scratch.db(), &alias).unwrap();
    assert!(matches!(
        ReviewStore::open(&scratch.db(), true),
        Err(CoreError::ProtectionUnavailable)
    ));
    assert!(matches!(
        ReviewStore::open(&alias, true),
        Err(CoreError::ProtectionUnavailable)
    ));
    drop(store);
    std::fs::remove_file(alias).unwrap();
    assert!(ReviewStore::open(&scratch.db(), true).is_ok());
}

#[test]
fn missing_owner_lock_and_symlink_database_never_grant_live_authority() {
    let scratch = Scratch::new();
    let store = ReviewStore::open(&scratch.db(), false).unwrap();
    let mut lock = scratch.db().as_os_str().to_os_string();
    lock.push(".owner.lock");
    std::fs::remove_file(PathBuf::from(lock)).unwrap();
    assert_eq!(
        store.verify_current(),
        Err(CoreError::ProtectionUnavailable)
    );
    let alias = scratch.0.join("symlink.sqlite");
    std::os::unix::fs::symlink(scratch.db(), &alias).unwrap();
    assert!(matches!(
        ReviewStore::open(&alias, true),
        Err(CoreError::ProtectionUnavailable)
    ));
}
