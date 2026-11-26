use albumwinnow_core::{
    CoreError,
    cleanup::{CleanupPlan, CleanupReason, ComparisonProof, PairFacts, PlanGroup, RemovalFacts},
    matching::MatchKind,
    model::{AssetId, SceneProvider},
    review::{
        ProtectionState, ReadOnlyPolicy, ReviewAsset, ReviewDecision, ReviewGroup, ReviewStatus,
        SourceKind, SourceRecord,
    },
    review_store::ReviewMetadata,
    scene::SceneQuality,
};
fn metadata() -> ReviewMetadata {
    ReviewMetadata {
        revision: 10,
        scan_generation: 1,
        scan_scope_epoch: 2,
        protection_epoch: 3,
        scope_epoch: 2,
        decision_epoch: 4,
        source_count: 1,
        group_count: 1,
        decision_count: 1,
    }
}
fn source() -> SourceRecord {
    SourceRecord {
        id: "opaque:source\0写真".into(),
        kind: SourceKind::FileSystem,
        native_namespace: "test.native.dir".into(),
        native_identity: vec![1],
        bookmark: vec![],
        label: "Fixture".into(),
        active: true,
    }
}
fn group() -> ReviewGroup {
    let asset = |item: &str| ReviewAsset {
        id: AssetId {
            source_id: source().id,
            item_id: item.into(),
        },
        name: item.into(),
        revision: "opaque nanoseconds".into(),
        kind: SourceKind::FileSystem,
        properties: Some(0),
        byte_count: Some(100),
        capture_date: None,
        burst: None,
        native_identity: Some(format!("native:{item}")),
        link_count: Some(1),
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
fn build(
    group: &ReviewGroup,
    decision: Option<&ReviewDecision>,
    protection: &ProtectionState,
) -> Result<CleanupPlan, CoreError> {
    CleanupPlan::build(
        "plan".into(),
        &metadata(),
        [PlanGroup {
            signature: &group.signature()?,
            group,
            decision,
        }],
        [&source()],
        protection,
    )
}
fn confirm(group: &ReviewGroup, all: bool) -> ReviewDecision {
    ReviewDecision::confirm(
        group,
        (!all).then(|| group.preferred.clone()),
        all,
        &ProtectionState::default(),
    )
    .unwrap()
}
fn facts(asset: &ReviewAsset) -> RemovalFacts {
    RemovalFacts {
        asset: asset.clone(),
        source_namespace: source().native_namespace,
        source_identity: source().native_identity,
        accessible: true,
        in_scan_scope: true,
        independently_removable: true,
        inside_read_only_root: false,
        matches_saved_lock: false,
        protection_complete: true,
    }
}
fn pair(group: &ReviewGroup) -> PairFacts {
    PairFacts {
        keep: Some(facts(&group.members[0])),
        remove: facts(&group.members[1]),
        proof: ComparisonProof::Pixels {
            kind: MatchKind::ExactDuplicate,
        },
    }
}
#[test]
fn only_saved_manual_intents_create_items_and_defer_retains_prior_confirmation() {
    let group = group();
    let protection = ProtectionState::default();
    assert_eq!(build(&group, None, &protection).unwrap().item_count(), 0);
    let mut decision = confirm(&group, false);
    assert_eq!(
        build(&group, Some(&decision), &protection)
            .unwrap()
            .item_count(),
        1
    );
    decision.status = ReviewStatus::Deferred;
    assert_eq!(
        build(&group, Some(&decision), &protection)
            .unwrap()
            .item_count(),
        1
    );
    decision.invalidated = true;
    assert_eq!(
        build(&group, Some(&decision), &protection)
            .unwrap()
            .item_count(),
        0
    );
    decision.invalidated = false;
    decision.status = ReviewStatus::Pending;
    assert_eq!(
        build(&group, Some(&decision), &protection)
            .unwrap()
            .item_count(),
        0
    );
}
#[test]
fn plans_bind_four_authority_epochs_but_not_filter_or_navigation_revision() {
    let group = group();
    let decision = confirm(&group, false);
    let plan = build(&group, Some(&decision), &ProtectionState::default()).unwrap();
    let mut current = metadata();
    current.revision += 100;
    assert_eq!(plan.check_epochs(&current), Ok(()));
    for epoch in 0..5 {
        let mut changed = current.clone();
        match epoch {
            0 => changed.scan_generation += 1,
            1 => changed.scope_epoch += 1,
            2 => changed.protection_epoch += 1,
            3 => changed.decision_epoch += 1,
            _ => changed.scan_scope_epoch += 1,
        }
        assert_eq!(plan.check_epochs(&changed), Err(CleanupReason::StalePlan));
    }
}
#[test]
fn final_native_facts_reject_source_revision_scope_companion_and_protection_changes() {
    let group = group();
    let decision = confirm(&group, false);
    let protection = ProtectionState::default();
    let plan = build(&group, Some(&decision), &protection).unwrap();
    let valid = pair(&group);
    assert_eq!(
        plan.validate_pair(0, 0, &valid, &metadata(), &protection),
        Ok(())
    );
    for (which, expected) in [
        (0, CleanupReason::ChangedAsset),
        (1, CleanupReason::UnavailableSource),
        (2, CleanupReason::Inaccessible),
        (3, CleanupReason::ChangedAsset),
        (4, CleanupReason::ProtectedResources),
        (5, CleanupReason::ReadOnlySource),
        (6, CleanupReason::UserProtected),
        (7, CleanupReason::UnavailableProtection),
        (8, CleanupReason::Inaccessible),
    ] {
        let mut changed = valid.clone();
        match which {
            0 => changed.remove.asset.revision = "changed".into(),
            1 => changed.remove.source_identity = vec![2],
            2 => changed.remove.accessible = false,
            3 => changed.remove.in_scan_scope = false,
            4 => changed.remove.asset.properties = Some(1),
            5 => changed.remove.inside_read_only_root = true,
            6 => changed.remove.matches_saved_lock = true,
            7 => changed.remove.protection_complete = false,
            _ => changed.remove.independently_removable = false,
        }
        assert_eq!(
            plan.validate_pair(0, 0, &changed, &metadata(), &protection),
            Err(expected)
        );
    }
    let mut changed = valid;
    changed.proof = ComparisonProof::Pixels {
        kind: MatchKind::Distinct,
    };
    assert_eq!(
        plan.validate_pair(0, 0, &changed, &metadata(), &protection),
        Err(CleanupReason::NoLongerDuplicate)
    );
}
#[test]
fn protection_changes_and_new_hardlinks_fail_closed_without_parsing_ids_or_revisions() {
    let group = group();
    let decision = confirm(&group, false);
    let protection = ProtectionState::default();
    let plan = build(&group, Some(&decision), &protection).unwrap();
    let mut current = pair(&group);
    let locked = ProtectionState::new(vec![group.members[1].clone()], vec![]).unwrap();
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &locked),
        Err(CleanupReason::UserProtected)
    );
    let policy = ReadOnlyPolicy {
        source_id: source().id,
        kind: SourceKind::FileSystem,
        snapshot_complete: true,
        members: vec![],
    };
    let read_only = ProtectionState::new(vec![], vec![policy]).unwrap();
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &read_only),
        Err(CleanupReason::ReadOnlySource)
    );
    let other = ReadOnlyPolicy {
        source_id: "other-source".into(),
        kind: SourceKind::FileSystem,
        snapshot_complete: true,
        members: vec![],
    };
    let read_only = ProtectionState::new(vec![], vec![other]).unwrap();
    current.remove.asset.link_count = Some(2);
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &read_only),
        Err(CleanupReason::UnavailableProtection)
    );
}
#[test]
fn whole_group_requires_all_current_resources_and_one_protected_member_blocks_preflight() {
    let group = group();
    let decision = confirm(&group, true);
    let protection = ProtectionState::default();
    let plan = build(&group, Some(&decision), &protection).unwrap();
    assert_eq!(plan.item_count(), 2);
    let mut current = group.members.iter().map(facts).collect::<Vec<_>>();
    assert_eq!(
        plan.preflight_whole_group(0, &current, &metadata(), &protection),
        Ok(())
    );
    assert_eq!(
        plan.preflight_whole_group(0, &current[..1], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    current[0].asset.properties = Some(2);
    assert_eq!(
        plan.preflight_whole_group(0, &current, &metadata(), &protection),
        Err(CleanupReason::ProtectedResources)
    );
    let locked = ProtectionState::new(vec![group.members[0].clone()], vec![]).unwrap();
    assert_eq!(
        build(&group, Some(&decision), &locked)
            .unwrap()
            .item_count(),
        0
    );
}
#[test]
fn current_or_cross_group_native_aliases_cannot_be_removed_as_distinct_resources() {
    let mut group = group();
    let decision = confirm(&group, false);
    let protection = ProtectionState::default();
    let plan = build(&group, Some(&decision), &protection).unwrap();
    let mut current = pair(&group);
    current.remove.asset.native_identity =
        current.keep.as_ref().unwrap().asset.native_identity.clone();
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &protection),
        Err(CleanupReason::ChangedAsset)
    );
    group.members[1].native_identity = group.members[0].native_identity.clone();
    assert_eq!(
        build(&group, Some(&decision), &protection)
            .unwrap()
            .item_count(),
        0
    );
}
#[test]
fn a_scene_plan_requires_fresh_compatible_distance_and_quality_evidence() {
    let mut group = group();
    group.duplicates[0].1 = MatchKind::SceneSimilar;
    let provider = SceneProvider {
        provider_id: "test.scene".into(),
        model_revision: "1".into(),
        preprocessing: "fixture128".into(),
        platform_compatibility: "controlled".into(),
    };
    group.scene = Some(provider.clone());
    let decision = confirm(&group, false);
    let protection = ProtectionState::default();
    let plan = build(&group, Some(&decision), &protection).unwrap();
    let mut current = pair(&group);
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &protection),
        Err(CleanupReason::NoLongerDuplicate)
    );
    let quality = SceneQuality {
        mean_luminance: 0.5,
        texture_variance: 0.05,
        focus_energy: 0.1,
        dark_clipping: 0.0,
        bright_clipping: 0.0,
    };
    current.proof = ComparisonProof::Scene {
        provider: provider.clone(),
        first: quality,
        second: quality,
        shared_burst: false,
        distance: 0.1,
    };
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &protection),
        Ok(())
    );
    let mut stale = provider;
    stale.model_revision = "2".into();
    current.proof = ComparisonProof::Scene {
        provider: stale,
        first: quality,
        second: quality,
        shared_burst: false,
        distance: 0.1,
    };
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &protection),
        Err(CleanupReason::NoLongerDuplicate)
    );
}
#[test]
fn missing_filesystem_protection_evidence_does_not_block_independent_photokit_items() {
    let mut source = source();
    source.kind = SourceKind::PhotoLibrary;
    let mut group = group();
    for asset in &mut group.members {
        asset.kind = SourceKind::PhotoLibrary;
        asset.native_identity = None;
        asset.link_count = None;
    }
    let protection = ProtectionState::new(
        vec![],
        vec![ReadOnlyPolicy {
            source_id: "unavailable-folder".into(),
            kind: SourceKind::FileSystem,
            snapshot_complete: false,
            members: vec![],
        }],
    )
    .unwrap();
    let decision = confirm(&group, false);
    let plan = CleanupPlan::build(
        "photos".into(),
        &metadata(),
        [PlanGroup {
            signature: &group.signature().unwrap(),
            group: &group,
            decision: Some(&decision),
        }],
        [&source],
        &protection,
    )
    .unwrap();
    let mut current = pair(&group);
    current.remove.protection_complete = false;
    assert_eq!(
        plan.validate_pair(0, 0, &current, &metadata(), &protection),
        Ok(())
    );
}

#[test]
fn aliases_across_groups_cannot_remove_a_retained_file_or_the_same_file_twice() {
    let first = group();
    let mut second = first.clone();
    for asset in &mut second.members {
        asset.id.item_id.push_str("-second");
        asset.native_identity = Some(format!("second:{}", asset.id.item_id));
    }
    second.preferred = second.members[0].id.clone();
    second.duplicates[0].0 = second.members[1].id.clone();
    for alias_of_keeper in [false, true] {
        if alias_of_keeper {
            second.members[0].native_identity = first.members[1].native_identity.clone();
        } else {
            second.members[1].native_identity = first.members[1].native_identity.clone();
        }
        let a = confirm(&first, false);
        let b = confirm(&second, false);
        let result = CleanupPlan::build(
            "aliases".into(),
            &metadata(),
            [
                PlanGroup {
                    signature: &first.signature().unwrap(),
                    group: &first,
                    decision: Some(&a),
                },
                PlanGroup {
                    signature: &second.signature().unwrap(),
                    group: &second,
                    decision: Some(&b),
                },
            ],
            [&source()],
            &ProtectionState::default(),
        );
        assert!(matches!(result, Err(CoreError::InvalidValue)));
    }
}
#[test]
fn whole_group_cannot_issue_any_ticket_before_all_members_pass_preflight() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, true);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let input = PairFacts {
        keep: None,
        remove: facts(&group.members[0]),
        proof: ComparisonProof::WholeGroup,
    };
    let key = CleanupItemKey { group: 0, pair: 0 };
    assert_eq!(
        run.authorize(&[(key, input.clone())], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    let mut all = group.members.iter().map(facts).collect::<Vec<_>>();
    all[1].inside_read_only_root = true;
    assert_eq!(
        run.preflight_whole_group(0, &all, &metadata(), &protection),
        Err(CleanupReason::ReadOnlySource)
    );
    assert_eq!(
        run.authorize(&[(key, input.clone())], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    all[1].inside_read_only_root = false;
    run.preflight_whole_group(0, &all, &metadata(), &protection)
        .unwrap();
    assert!(
        run.authorize(&[(key, input)], &metadata(), &protection)
            .is_ok()
    );
}
#[test]
fn tickets_are_single_use_and_native_reports_are_idempotent_without_overwriting_outcomes() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupOutcome, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, false);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let key = CleanupItemKey { group: 0, pair: 0 };
    let ticket = run
        .authorize(&[(key, pair(&group))], &metadata(), &protection)
        .unwrap();
    assert!(run.busy());
    assert_eq!(run.validate_ticket(&ticket, &metadata()), Ok(()));
    assert_eq!(
        run.authorize(&[(key, pair(&group))], &metadata(), &protection),
        Err(CleanupReason::OperationInProgress)
    );
    let mut forged = ticket.clone();
    forged.nonce += 1;
    assert_eq!(
        run.report(&forged, vec![CleanupOutcome::MovedToTrash]),
        Err(CleanupReason::StalePlan)
    );
    assert_eq!(
        run.report(&ticket, vec![CleanupOutcome::MovedToRecentlyDeleted]),
        Err(CleanupReason::InvalidSelection)
    );
    assert!(run.busy());
    assert_eq!(
        run.report(&ticket, vec![CleanupOutcome::MovedToTrash]),
        Ok(true)
    );
    assert!(!run.busy());
    assert_eq!(
        run.report(&ticket, vec![CleanupOutcome::MovedToTrash]),
        Ok(false)
    );
    assert_eq!(
        run.report(&ticket, vec![CleanupOutcome::Failed]),
        Err(CleanupReason::InvalidSelection)
    );
    assert_eq!(
        run.authorize(&[(key, pair(&group))], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    assert_eq!(
        run.outcomes().get(&key),
        Some(&CleanupOutcome::MovedToTrash)
    );
}
#[test]
fn cancellation_preserves_completed_partial_results_and_rejects_further_authorization() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupOutcome, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, true);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let all = group.members.iter().map(facts).collect::<Vec<_>>();
    run.preflight_whole_group(0, &all, &metadata(), &protection)
        .unwrap();
    let input = |index: usize| {
        (
            CleanupItemKey {
                group: 0,
                pair: index,
            },
            PairFacts {
                keep: None,
                remove: all[index].clone(),
                proof: ComparisonProof::WholeGroup,
            },
        )
    };
    let ticket = run
        .authorize(&[input(0)], &metadata(), &protection)
        .unwrap();
    run.cancel();
    assert_eq!(
        run.validate_ticket(&ticket, &metadata()),
        Err(CleanupReason::Cancelled)
    );
    assert_eq!(
        run.report(&ticket, vec![CleanupOutcome::MovedToTrash]),
        Ok(true)
    );
    assert_eq!(run.outcomes().len(), 1);
    assert_eq!(
        run.authorize(&[input(1)], &metadata(), &protection),
        Err(CleanupReason::Cancelled)
    );
}
#[test]
fn batch_authorization_validates_every_item_before_issuing_any_native_ticket() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, true);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let all = group.members.iter().map(facts).collect::<Vec<_>>();
    run.preflight_whole_group(0, &all, &metadata(), &protection)
        .unwrap();
    let a = (
        CleanupItemKey { group: 0, pair: 0 },
        PairFacts {
            keep: None,
            remove: all[0].clone(),
            proof: ComparisonProof::WholeGroup,
        },
    );
    let mut b = (
        CleanupItemKey { group: 0, pair: 1 },
        PairFacts {
            keep: None,
            remove: all[1].clone(),
            proof: ComparisonProof::WholeGroup,
        },
    );
    b.1.remove.in_scan_scope = false;
    assert_eq!(
        run.authorize(&[a.clone(), b], &metadata(), &protection),
        Err(CleanupReason::ChangedAsset)
    );
    assert!(!run.busy());
    assert!(run.outcomes().is_empty());
    assert_eq!(
        run.authorize(&[a.clone(), a], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    assert!(!run.busy());
}

#[test]
fn bounded_whole_preflight_rejects_duplicates_and_failed_recheck_revokes_prior_preflight() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, true);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let all = group.members.iter().map(facts).collect::<Vec<_>>();
    run.begin_whole_preflight(0, &metadata()).unwrap();
    assert_eq!(
        run.append_whole_preflight(0, &vec![all[0].clone(); 17], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    run.append_whole_preflight(0, &all[..1], &metadata(), &protection)
        .unwrap();
    assert_eq!(
        run.finish_whole_preflight(0, &metadata()),
        Err(CleanupReason::InvalidSelection)
    );
    assert_eq!(
        run.append_whole_preflight(0, &all[..1], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
    run.append_whole_preflight(0, &all[1..], &metadata(), &protection)
        .unwrap();
    run.finish_whole_preflight(0, &metadata()).unwrap();
    let mut failed = all.clone();
    failed[1].inside_read_only_root = true;
    assert_eq!(
        run.preflight_whole_group(0, &failed, &metadata(), &protection),
        Err(CleanupReason::ReadOnlySource)
    );
    let input = PairFacts {
        keep: None,
        remove: all[0].clone(),
        proof: ComparisonProof::WholeGroup,
    };
    assert_eq!(
        run.authorize(
            &[(CleanupItemKey { group: 0, pair: 0 }, input)],
            &metadata(),
            &protection
        ),
        Err(CleanupReason::InvalidSelection)
    );
}

#[test]
fn a_native_failure_without_authorization_records_no_move_and_cannot_overwrite_a_result() {
    use albumwinnow_core::cleanup::run::{CleanupItemKey, CleanupOutcome, CleanupRun};
    let group = group();
    let protection = ProtectionState::default();
    let decision = confirm(&group, false);
    let mut run = CleanupRun::new(build(&group, Some(&decision), &protection).unwrap());
    let key = CleanupItemKey { group: 0, pair: 0 };
    run.fail(key).unwrap();
    assert_eq!(run.results().unwrap()[0].outcome, CleanupOutcome::Failed);
    assert_eq!(run.fail(key), Err(CleanupReason::InvalidSelection));
    assert_eq!(
        run.authorize(&[(key, pair(&group))], &metadata(), &protection),
        Err(CleanupReason::InvalidSelection)
    );
}
