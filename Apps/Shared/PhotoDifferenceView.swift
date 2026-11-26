import AlbumWinnowApple
import CoreGraphics
import SwiftUI

struct PhotoDifferenceView: View {
    let model: ReviewModel
    let group: ReviewGroupDetail
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false
    @State private var referenceID: AssetID?
    @State private var comparisonID: AssetID?
    @State private var requestID: UUID?
    @State private var result: PhotoDifference?
    @State private var errorMessage: String?
    @State private var showHighlights = false
    @State private var opacity = 0.25

    private var loading: Bool { requestID != nil && result == nil && errorMessage == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("app_choose_two_photos_to_compare_your_keep_choice_stays_unchanged"))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(L10n.text("app_reference")).font(.caption)
                        .accessibilityIdentifier("difference-reference-label")
                    Menu {
                        Picker(L10n.text("app_reference"), selection: $referenceID) {
                            Text(L10n.text("app_choose_photo")).tag(nil as AssetID?)
                            ForEach(group.assets) { asset in Text(title(asset)).tag(Optional(asset.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(menuTitle(referenceID)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .accessibilityLabel(L10n.text("app_reference"))
                    .accessibilityValue(menuTitle(referenceID))
                    .accessibilityIdentifier("difference-reference")
                }
                VStack(alignment: .leading) {
                    Text(L10n.text("app_comparison")).font(.caption)
                        .accessibilityIdentifier("difference-comparison-label")
                    Menu {
                        Picker(L10n.text("app_comparison"), selection: $comparisonID) {
                            Text(L10n.text("app_choose_photo")).tag(nil as AssetID?)
                            ForEach(group.assets.filter { $0.id != referenceID }) { asset in Text(title(asset)).tag(Optional(asset.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(menuTitle(comparisonID)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .accessibilityLabel(L10n.text("app_comparison"))
                    .accessibilityValue(menuTitle(comparisonID))
                    .accessibilityIdentifier("difference-comparison")
                }
                Button(result == nil ? L10n.text("app_show_differences") : L10n.text("app_refresh_differences")) {
                    result = nil
                    errorMessage = nil
                    showHighlights = true
                    requestID = UUID()
                }
                .buttonStyle(.borderedProminent)
                .disabled(referenceID == nil || comparisonID == nil || referenceID == comparisonID ||
                          loading || model.running || model.cleaning || model.resultsStale)
                .accessibilityIdentifier("difference-show")
                if loading { ProgressView(L10n.text("app_comparing_previews")) }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("difference-unavailable")
                }
                if let result {
                    if let reason = result.unavailableReason {
                        Label(L10n.text("app_cannot_reliably_show_differences"), systemImage: "rectangle.slash")
                            .accessibilityIdentifier("difference-unavailable")
                        Text(explanation(reason)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.text("app_display"), selection: $showHighlights) {
                            Text(L10n.text("app_original")).tag(false)
                            Text(L10n.text("app_differences")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("difference-display")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], spacing: 16) {
                        photo(result.reference, label: L10n.text("app_reference"), regions: [])
                        photo(result.comparison, label: L10n.text("app_comparison"),
                              regions: showHighlights ? result.regions : [])
                    }
                    if result.unavailableReason == nil {
                        if result.regions.isEmpty {
                            Text(L10n.text("app_no_significant_local_differences_at_this_preview_resolution"))
                                .accessibilityIdentifier("difference-region-count")
                        } else {
                            Text(result.regions.count == 1 ? L10n.text("app_1_local_change_region") : L10n.text("app_arg1_local_change_regions", Int64(result.regions.count)))
                                .accessibilityIdentifier("difference-region-count")
                            if showHighlights {
                                Text(L10n.text("app_highlight_opacity")).font(.caption)
                                Slider(value: $opacity, in: 0...0.75) { Text(L10n.text("app_highlight_opacity")) }
                                    .accessibilityIdentifier("difference-opacity")
                            }
                        }
                    }
                    Text(L10n.text("app_these_are_approximate_image_change_hints_from_previews_up_to_512_pixels_with_global_color_and_compression_noise_suppressed_small_details_can_be_missed_use_synchronized_zoom_in_the_group_to_inspect_originals_hints_do_not_change_matching_recommendations_or_cleanup_choices"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L10n.text("app_compare_photos"))
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: referenceID) { _, value in
            if comparisonID == value { comparisonID = nil }
            reset()
        }
        .onChange(of: comparisonID) { _, _ in reset() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
        .onChange(of: model.resultsStale) { _, stale in if stale { reset() } }
        .onChange(of: model.running) { _, running in if running { reset() } }
        .onDisappear { reset() }
        .task(id: requestID) {
            guard let request = requestID,
                  let reference = group.assets.first(where: { $0.id == referenceID }),
                  let comparison = group.assets.first(where: { $0.id == comparisonID }) else { return }
            do {
                let value = try await model.difference(reference: reference, comparison: comparison)
                guard !Task.isCancelled, requestID == request else { return }
                result = value
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                errorMessage = message(error)
            }
        }
    }

    private func title(_ asset: PhotoAsset) -> String {
        if showFilenames { return asset.name }
        return L10n.text("app_photo_arg1", Int64((group.assets.firstIndex(of: asset) ?? 0) + 1))
    }

    private func menuTitle(_ id: AssetID?) -> String {
        group.assets.first { $0.id == id }.map { title($0) } ?? L10n.text("app_choose_photo")
    }

    private func reset() {
        requestID = nil
        result = nil
        errorMessage = nil
        showHighlights = false
    }

    private func photo(_ image: CGImage, label: String, regions: [CGRect]) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.headline)
            GeometryReader { geometry in
                let fit = ReviewZoom.fittedSize(image: CGSize(width: image.width, height: image.height), viewport: geometry.size)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .overlay {
                        ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                            Rectangle()
                                .fill(.orange.opacity(opacity))
                                .overlay { Rectangle().stroke(.orange, lineWidth: 2) }
                                .frame(width: rect.width * fit.width, height: rect.height * fit.height)
                                .position(x: rect.midX * fit.width, y: rect.midY * fit.height)
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 280)
            .background(.quaternary, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.text("app_arg1_preview", label)))
        }
    }

    private func explanation(_ reason: DifferenceUnavailableReason) -> String {
        switch reason {
        case .geometry: return L10n.text("app_the_image_proportions_differ_crops_or_changed_viewpoints_require_manual_comparison")
        case .insufficientDetail: return L10n.text("app_there_is_not_enough_stable_detail_to_verify_alignment_inspect_the_photos_with_synchronized_zoom_in_the_group")
        case .alignment: return L10n.text("app_the_framing_or_image_details_do_not_agree_closely_enough_for_a_reliable_overlay_inspect_the_originals_manually")
        }
    }

    private func message(_ error: Error) -> String {
        switch error {
        case AssetAccessError.changedDuringScan, ScopeError.unavailableAlbum:
            return L10n.text("app_the_photos_or_their_scope_changed_return_to_the_overview_and_scan_again")
        case AssetAccessError.cloudDownloadRequired, AssetAccessError.cloudDownloadFailed:
            return L10n.text("app_a_local_preview_is_unavailable_download_and_rescan_from_the_group_menu_before_comparing_again")
        case is CancellationError: return L10n.text("app_difference_preview_cancelled_try_again_when_the_photos_are_available")
        default: return L10n.text("app_cannot_read_or_verify_these_previews_return_to_the_group_and_check_access_before_trying_again")
        }
    }
}
