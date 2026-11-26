import AlbumWinnowApple
import AlbumWinnowRust
import SwiftUI

struct ResultFiltersView: View {
    let model: ReviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker(L10n.text("app_review_status"), selection: binding(\.status)) {
                    ForEach(CoreReviewStatusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("result-status-filter")
                Picker(L10n.text("app_match_category"), selection: binding(\.kind)) {
                    Text(L10n.text("app_all_categories")).tag(nil as CoreMatch?)
                    ForEach(model.reviewCollection == .similarScenes ? [CoreMatch.sceneSimilar] : [CoreMatch.exactDuplicate, .visualDuplicate, .similarPhoto], id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
                Picker(L10n.text("app_source"), selection: binding(\.source)) {
                    Text(L10n.text("app_all_sources")).tag(nil as String?)
                    if let photoSourceID = model.photoSourceID { Text(L10n.text("app_photos")).tag(Optional(photoSourceID)) }
                    ForEach(model.folders) { Text($0.name).tag(Optional($0.id)) }
                    if let source = model.resultQuery.source, source != model.photoSourceID,
                       !model.folders.contains(where: { $0.id == source }) {
                        Text(L10n.text("app_unavailable_source")).tag(Optional(source))
                    }
                }
                Picker(L10n.text("app_sort"), selection: binding(\.sort)) {
                    ForEach(CoreReviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("result-sort")
                Text(L10n.text("app_dates_use_the_latest_known_capture_metadata_in_each_group_unknown_dates_stay_last_in_either_direction_size_sorting_uses_known_candidate_bytes_partial_sizes_are_lower_bounds"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("app_clear_filters")) { model.clearResultFilters() }
                Text(L10n.text("app_filtering_never_clears_confirmed_cleanup_candidates_a_review_session_keeps_its_current_order_until_you_return_to_the_overview"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .disabled(!model.canEditSources)
            .navigationTitle(L10n.text("app_filter_and_sort"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("app_done")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 500, minHeight: 400, idealHeight: 520)
        #endif
    }

    private func binding<Value>(_ path: WritableKeyPath<CoreReviewQuery, Value>) -> Binding<Value> {
        Binding(get: { model.resultQuery[keyPath: path] }, set: {
            var query = model.resultQuery
            query[keyPath: path] = $0
            model.setResultQuery(query)
        })
    }
}

struct GroupInformationView: View {
    let model: ReviewModel
    let group: ReviewGroupDetail
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("app_recommendation_evidence")) {
                    let reasons = group.recommendationReasons
                    ForEach(Array(reasons.prefix(2)), id: \.self) { Text(reason($0)) }
                    if reasons.count > 2 {
                        DisclosureGroup(L10n.text("app_more_evidence")) {
                            ForEach(Array(reasons.dropFirst(2)), id: \.self) { Text(reason($0)) }
                        }
                    }
                    Text(L10n.text("app_recommended_is_a_suggestion_selected_is_your_keep_choice_locked_photos_must_also_remain_a_lock_is_not_a_quality_rating"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("app_why_these_photos_are_grouped")) {
                    Text(group.match.title).font(.headline)
                    Text(group.match.explanation)
                    if group.comparisonSides != nil {
                        Text(L10n.text("app_only_cross_side_edges_are_evidence_photos_on_the_same_side_are_not_assumed_identical_choosing_one_photo_may_retain_additional_members_without_a_verified_match_to_a_retained_photo"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L10n.text("app_the_summary_uses_the_most_cautious_category_each_member_below_records_its_own_match_to_the_reference_photo_not_to_every_other_member"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(group.duplicates.enumerated()), id: \.element.id) { index, member in
                        LabeledContent(showFilenames ? member.asset.name : L10n.text("app_photo_arg1", Int64(index + 2))) {
                            Text(member.match.title)
                        }
                    }
                    Text(L10n.text("app_reference_arg1", showFilenames ? group.preferred.name : L10n.text("app_photo_1")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if group.sceneAlgorithm != nil {
                    Section(L10n.text("app_scene_similarity_evidence")) {
                        Text(L10n.text("app_visual_features_agree_within_this_group_a_shared_burst_identifier_and_capture_time_proximity_are_candidate_hints_not_proof_of_identical_content"))
                        Text(L10n.text("app_groups_require_every_member_to_agree_with_the_representative_and_the_other_members_with_at_most_24_photos_larger_scenes_and_similarity_chains_can_be_split_low_texture_photos_may_be_omitted"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("app_natural_photo_precision_and_recall_have_not_been_measured_inspect_content_differences_before_deciding_what_to_keep"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("app_arg1_actual_pair_comparisons", Int64(group.sceneEvidence?.count ?? 0)))
                        DisclosureGroup(L10n.text("app_pair_details")) {
                            ForEach(Array((group.sceneEvidence ?? []).enumerated()), id: \.offset) { index, evidence in
                                Text(L10n.text("app_pair_arg1_feature_distance_arg2", Int64(index + 1), Double(evidence.distance).formatted(.number.precision(.fractionLength(3)))))
                                if evidence.sharedBurst { Text(L10n.text("app_shared_photos_burst_identifier")) }
                            }
                        }
                        Text(L10n.text("app_feature_distance_is_not_a_confidence_percentage_smaller_values_mean_closer_representations_not_guaranteed_duplicates"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.text("app_photo_metadata")) {
                    ForEach(Array(group.assets.enumerated()), id: \.element.id) { index, asset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(showFilenames ? asset.name : L10n.text("app_photo_arg1", Int64(index + 1))).font(.headline)
                            Text(model.sourceLabel(asset.id.source))
                            let evidence = group.evidence?[asset.id]
                            if let evidence {
                                Text("\(evidence.width) × \(evidence.height)")
                                Text(evidence.bitDepth.map { L10n.text("app_arg1_bit", Int64($0)) } ?? L10n.text("app_bit_depth_unknown"))
                            } else { Text(L10n.text("app_resolution_and_bit_depth_unknown")) }
                            Text(asset.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.text("app_size_unknown"))
                            let date = asset.captureDate ?? evidence?.captureDate.map(Date.init(timeIntervalSince1970:))
                            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L10n.text("app_capture_date_unknown"))
                            if let quality = group.sceneQuality?[asset.id] {
                                Text(L10n.text("app_thumbnail_focus_energy_arg1", quality.focusEnergy.formatted(.number.precision(.fractionLength(4)))))
                                Text(L10n.text("app_clipped_shadows_arg1_clipped_highlights_arg2", quality.darkClipping.formatted(.percent.precision(.fractionLength(1))), quality.brightClipping.formatted(.percent.precision(.fractionLength(1)))))
                                Text(L10n.text("app_these_measured_thumbnail_signals_do_not_establish_subject_focus_artistic_intent_or_aesthetic_quality"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if model.isLocked(asset) { Label(L10n.text("app_locked"), systemImage: "lock.fill") }
                            if model.isReadOnly(asset) { Label(L10n.text("app_read_only_source"), systemImage: "hand.raised.fill") }
                        }
                        .font(.subheadline)
                    }
                }
                Section(L10n.text("app_candidate_resource_size")) {
                    if group.hasQualityRecommendation == false, model.selection(for: group.id).keepID == nil,
                       !model.selection(for: group.id).deleteAll {
                        Text(L10n.text("app_choose_and_confirm_a_keeper_before_estimating_candidate_size"))
                    } else {
                        Text(group.core.summary.estimate.summary)
                    }
                    Text(L10n.text("app_this_is_not_a_promise_of_immediately_released_device_storage_icloud_optimization_and_recently_deleted_affect_actual_free_space"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("app_difference_preview")) {
                    NavigationLink {
                        PhotoDifferenceView(model: model, group: group)
                    } label: {
                        Label(L10n.text("app_show_differences"), systemImage: "square.on.square")
                    }
                    .accessibilityIdentifier("show-differences")
                    Text(L10n.text("app_choose_a_reference_and_comparison_photo_differences_are_shown_only_when_their_previews_can_be_reliably_aligned"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("app_zoom")) {
                    Text(L10n.text("app_double_tap_or_double_click_a_photo_to_zoom_or_reset_use_the_group_menu_for_zoom_in_reset_zoom_and_sync_zoom_dragging_while_zoomed_pans_the_image_instead_of_changing_groups"))
                    Text(L10n.text("app_photos_are_linked_by_relative_image_position_not_pixel_alignment_crops_and_different_viewpoints_may_show_different_objects_detail_previews_are_limited_to_available_pixels_and_do_not_silently_download_from_icloud"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("app_review_evidence"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("app_done")) { dismiss() }.accessibilityIdentifier("evidence-done") } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 600, minHeight: 400, idealHeight: 620)
        #endif
    }

    private func reason(_ reason: CoreRecommendationReason) -> String {
        let evidence = group.evidence?[group.recommendation.id]
        switch reason {
        case .focusSignal: return L10n.text("app_more_measured_thumbnail_edge_energy_at_the_same_image_dimensions_and_comparable_exposure_check_subject_focus_manually_intentional_blur_can_be_appropriate")
        case .exposureSignal: return L10n.text("app_less_measured_shadow_highlight_clipping_at_the_same_image_dimensions_exposure_can_be_intentional_inspect_the_original_appearance")
        case .sourcePreference: return L10n.text("app_quality_ranking_signals_are_tied_the_configured_source_preference_is_used")
        case .associatedResources: return L10n.text("app_associated_resource_flags_are_present_cleanup_protection_applies")
        case .higherResolution:
            guard let evidence else { return L10n.text("app_resolution_unknown") }
            return L10n.text("app_more_pixels_than_another_copy_arg1_arg2_resolution_alone_does_not_establish_sharpness", Int64(evidence.width), Int64(evidence.height))
        case .higherBitDepth:
            guard let depth = evidence?.bitDepth else { return L10n.text("app_bit_depth_unknown") }
            return L10n.text("app_higher_documented_bit_depth_arg1_bit_than_another_copy", Int64(depth))
        case .wideColor: return L10n.text("app_the_decoded_image_has_a_wide_color_profile")
        case .edgeContrast: return L10n.text("app_a_thumbnail_edge_contrast_tie_break_is_used_this_is_not_a_calibrated_sharpness_comparison")
        case .noQualityAdvantage: return L10n.text("app_no_established_quality_advantage_choose_according_to_your_preference")
        }
    }
}

extension CoreReviewStatusFilter {
    var title: String {
        switch self {
        case .active: L10n.text("app_all_except_kept")
        case .all: L10n.text("app_all_review_states")
        case .pending: L10n.text("app_needs_review")
        case .confirmed: L10n.text("app_confirmed")
        case .deferred: L10n.text("app_later")
        case .kept: L10n.text("app_entire_group_kept")
        }
    }
}

extension CoreReviewSort {
    var title: String {
        switch self {
        case .stable: L10n.text("app_stable_order")
        case .newest: L10n.text("app_capture_date_newest_first")
        case .oldest: L10n.text("app_capture_date_oldest_first")
        case .count: L10n.text("app_most_photos")
        case .bytes: L10n.text("app_largest_candidate_size")
        }
    }
}

extension CoreMatch {
    var title: String {
        switch self {
        case .sceneSimilar: L10n.text("app_burst_similar_scene")
        case .exactDuplicate: L10n.text("app_exact_duplicate")
        case .visualDuplicate: L10n.text("app_possible_same_image_caption")
        case .similarPhoto: L10n.text("app_highly_similar_review_differences")
        case .distinct: L10n.text("app_different_photos")
        }
    }

    var explanation: String {
        switch self {
        case .sceneSimilar: L10n.text("app_visual_scene_features_are_close_frames_may_contain_different_expressions_movement_or_objects_this_is_not_duplicate_proof")
        case .exactDuplicate: L10n.text("app_file_bytes_and_effective_orientation_agree")
        case .visualDuplicate: L10n.text("app_multi_scale_image_checks_agree_size_format_or_compression_may_differ")
        case .similarPhoto: L10n.text("app_the_overall_image_is_close_but_higher_resolution_checks_found_local_differences_manual_review_is_required")
        case .distinct: L10n.text("app_these_photos_do_not_have_a_verified_duplicate_relationship")
        }
    }
}

extension CoreSizeEstimate {
    var summary: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: knownBytes), countStyle: .file)
        if knownCount == 0, unknownCount > 0 { return L10n.text("app_size_unknown") }
        if unknownCount > 0 { return L10n.text("app_at_least_arg1_plus_arg2_photos_of_unknown_size", Int64(unknownCount), bytes) }
        if overflowed { return L10n.text("app_at_least_arg1", bytes) }
        return bytes
    }
}
