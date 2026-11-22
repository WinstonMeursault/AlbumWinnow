import AlbumWinnowCore
import SwiftUI

struct LibraryView: View {
    let model: ReviewModel
    @State private var showingFilters = false
    @State private var reviewQueue: [DuplicateGroup] = []
    @State private var batchSummary: String?
    @State private var selectedGroup: AssetID?
    @State private var reviewPath: [AssetID] = []
    @State private var galleryBottomRequest = 0
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @State private var showingIssues = false
    @State private var confirmingCleanup = false

    var body: some View {
        NavigationStack(path: $reviewPath) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let wide = width >= 760
                let group = wide ? group(withID: selectedGroup) : nil
                HStack(spacing: 0) {
                    groups(wide: wide, narrowed: group != nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) { scanControls }
                        .frame(width: group == nil ? nil : min(470, max(330, width * 0.36)))
                    if group != nil {
                        Divider()
                        reviewPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onChange(of: wide) { _, wide in
                    if wide {
                        reviewPath.removeAll()
                    } else {
                        reviewPath = selectedGroup.map { [$0] } ?? []
                    }
                }
                .onChange(of: reviewPath.isEmpty) { _, closed in
                    if closed && !wide { selectedGroup = nil }
                }
            }
            .navigationTitle(L10n.text("app_duplicates"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    settingsButton(L10n.text("app_settings"), systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .help(L10n.text("app_settings"))
                }
            }
            .navigationDestination(for: AssetID.self) { _ in
                if group(withID: selectedGroup) != nil {
                    review
                        .navigationTitle(reviewTitle)
                        .toolbarTitleDisplayMode(.inline)
                }
            }
        }
        .onChange(of: selectedGroup) {
            if let group = group(withID: selectedGroup) { model.rememberPosition(group) }
        }
        .onChange(of: model.result) {
            reviewQueue.removeAll()
            if group(withID: selectedGroup) == nil {
                selectedGroup = nil
                reviewPath.removeAll()
            }
        }
        .sheet(isPresented: $showingFilters) { ResultFiltersView(model: model) }
        .sheet(isPresented: $showingIssues) { issues }
        .sheet(isPresented: $confirmingCleanup) { cleanupConfirmation }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                ScanSourcesView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("app_done")) { showingSettings = false }
                                .accessibilityIdentifier("settings-done")
                        }
                    }
            }
        }
        #endif
        .alert("AlbumWinnow", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.text("app_ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func group(withID id: AssetID?) -> DuplicateGroup? {
        guard let id else { return nil }
        return model.result?.groups.first { $0.id == id }
    }

    private var review: some View {
        ReviewPager(groups: reviewQueue.isEmpty ? model.result?.groups ?? [] : reviewQueue, selectedID: $selectedGroup,
                    model: model, finishReview: finishReview)
    }

    private var reviewTitle: Text {
        let groups = reviewQueue.isEmpty ? model.visibleGroups : reviewQueue
        if let index = groups.firstIndex(where: { $0.id == selectedGroup }) {
            return Text(L10n.text("app_group_arg1_of_arg2", Int64(index + 1), Int64(groups.count)))
        }
        return Text(L10n.text("app_review_group"))
    }

    private func finishReview() {
        if !reviewQueue.isEmpty {
            let completed = reviewQueue.filter { model.status(for: $0) == .confirmed || model.status(for: $0) == .kept }.count
            batchSummary = L10n.text("app_arg1_of_arg2_groups_decided", Int64(completed), Int64(reviewQueue.count))
        }
        reviewQueue.removeAll()
        galleryBottomRequest += 1
        if reviewPath.isEmpty { selectedGroup = nil }
        else { reviewPath.removeAll() }
    }

    private var reviewPane: some View {
        VStack(spacing: 0) {
            HStack {
                reviewTitle.font(.headline)
                Spacer()
                Button(L10n.text("app_close_review"), systemImage: "xmark") { selectedGroup = nil }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("app_close_review"))
                    .accessibilityIdentifier("close-review")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            review
        }
    }

    private func settingsButton(_ title: String, systemImage: String) -> some View {
        #if os(macOS)
        SettingsLink { Label(title, systemImage: systemImage) }
            .accessibilityIdentifier("open-settings")
        #else
        Button { showingSettings = true } label: { Label(title, systemImage: systemImage) }
            .accessibilityIdentifier("open-settings")
        #endif
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let download = model.downloadProgress { downloadStatus(download) }
            if model.running || model.scanCancelled {
                if let counts = model.scanAccounting {
                    Text(L10n.text("app_arg1_processed_arg2_skipped_arg3_failed_arg4_unfinished", Int64(counts.processed), Int64(counts.skipped), Int64(counts.failed), Int64(counts.unfinished)))
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.scanCancelled {
                    Text(L10n.text("app_scan_cancelled_before_enumeration_finished_remaining_count_unknown"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let progress = model.progress {
                progressView(progress)
            } else if model.running && model.downloadProgress == nil {
                ProgressView(L10n.text("app_preparing_scan"))
            }
            HStack(spacing: 8) {
                if model.running, let download = model.downloadProgress, download.remaining > 0, !download.ended {
                    Button(L10n.text("app_cancel_download")) { model.cancelScan() }
                } else if model.running {
                    Button(L10n.text("app_cancel_scan")) { model.cancelScan() }
                } else {
                    Button { model.scan() } label: {
                        Label(model.lastCleanup == nil ? L10n.text("app_scan") : L10n.text("app_scan_again"), systemImage: "magnifyingglass")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canScan)
                    .accessibilityIdentifier("start-scan")
                }
                Spacer(minLength: 0)
                if model.selectedCount > 0 {
                    Button { confirmingCleanup = true } label: {
                        Text(L10n.text("app_confirm_cleanup_arg1", Int64(model.selectedCount)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canClean)
                    .accessibilityIdentifier("review-batch-cleanup")
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func groups(wide: Bool, narrowed: Bool) -> some View {
        VStack(spacing: 0) {
            if model.cleaning {
                ContentUnavailableView(L10n.text("app_moving_selected_photos"), systemImage: "trash")
            } else if model.running {
                ContentUnavailableView(
                    model.downloadProgress == nil ? L10n.text("app_scanning_photos") : L10n.text("app_updating_scan_results"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.text("app_duplicates_will_be_ready_to_review_when_the_scan_finishes"))
                )
            } else if let cleanup = model.lastCleanup {
                CleanupOutcomeView(items: cleanup, model: model)
            } else if let result = model.result {
                scanResults(result, wide: wide, narrowed: narrowed)
            } else if !model.hasScanSources {
                ContentUnavailableView {
                    Label(L10n.text("app_choose_scan_sources"), systemImage: "photo.stack")
                } description: {
                    Text(L10n.text("app_enable_photos_or_add_a_folder_to_start_scanning"))
                } actions: {
                    settingsButton(L10n.text("app_configure_scan_sources"), systemImage: "gearshape")
                        .buttonStyle(.glass)
                }
            } else if model.resultsStale {
                ContentUnavailableView(L10n.text("app_scan_again"), systemImage: "arrow.clockwise",
                                       description: Text(L10n.text("app_the_selected_sources_or_their_contents_changed")))
            } else {
                ContentUnavailableView(L10n.text("app_ready_to_scan"), systemImage: "photo.stack")
            }
        }
    }

    private func scanResults(_ result: ScanResult, wide: Bool, narrowed: Bool) -> some View {
        Group {
            if result.groups.isEmpty {
                VStack(spacing: 0) {
                    scanSummaryCard(result)
                    ContentUnavailableView(model.reviewCollection == .similarScenes ? L10n.text("app_no_similar_photos_found") : L10n.text("app_no_duplicates_found"), systemImage: "checkmark.circle")
                }
            } else {
                DuplicateGallery(groups: model.visibleGroups, model: model, selectedGroup: selectedGroup,
                                 narrowed: narrowed, isActive: reviewPath.isEmpty,
                                 bottomRequest: galleryBottomRequest, header: {
                    scanSummaryCard(result)
                }) { group in
                    reviewQueue = model.visibleGroups
                    selectedGroup = group.id
                    if !wide { reviewPath = [group.id] }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !result.issues.isEmpty {
                Button(result.issues.count == 1 ? L10n.text("app_review_1_scan_issue") : L10n.text("app_review_arg1_scan_issues", Int64(result.issues.count))) {
                    showingIssues = true
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    private func scanSummaryCard(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            scanSummary(result)
            Picker(L10n.text("app_review_collection"), selection: Binding(get: { model.reviewCollection }, set: { model.setReviewCollection($0) })) {
                Text(L10n.text("app_duplicates")).tag(ReviewCollection.duplicates)
                Text(L10n.text("app_similar_photos_caption")).tag(ReviewCollection.similarScenes)
            }
            .pickerStyle(.segmented)
            .disabled(!model.canEditSources)
            .accessibilityIdentifier("review-collection")
            if model.reviewCollection == .similarScenes && !model.similarScenesEnabled {
                Text(L10n.text("app_find_burst_frames_and_similar_scenes_in_a_separate_review_queue_all_cleanup_requires_your_confirmation"))
                    .font(.caption)
                Button(L10n.text("app_scan_similar_photos")) { model.setSimilarScenesEnabled(true); model.scan() }
                    .disabled(!model.canScan)
            }
            if !model.protectionAvailable {
                Label(L10n.text("app_protection_unavailable_cleanup_disabled"), systemImage: "lock.trianglebadge.exclamationmark")
            }
            Text(L10n.text("app_arg1_of_arg2_groups_shown_arg3", Int64(model.visibleGroups.count), Int64(result.groups.count), model.resultQuery.sort.title))
                .font(.caption).foregroundStyle(.secondary)
            if let notice = model.reviewNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let batchSummary { Text(batchSummary).font(.caption) }
            if model.visibleGroups.isEmpty, !result.groups.isEmpty {
                if model.collectionGroups.isEmpty {
                    Text(model.reviewCollection == .similarScenes ? L10n.text("app_no_similar_scenes_found_in_this_scan") : L10n.text("app_no_duplicates_found_in_this_scan"))
                        .font(.subheadline)
                } else {
                    Text(L10n.text("app_no_groups_match_these_filters")).font(.subheadline)
                    Button(L10n.text("app_clear_filters")) { model.clearResultFilters() }
                }
            }
            HStack {
                Button(L10n.text("app_continue_review")) { openSession(result, limit: nil) }
                    .disabled(model.resumeGroup == nil || !model.canClean)
                Menu(L10n.text("app_review_options"), systemImage: "ellipsis.circle") {
                    Button(L10n.text("app_review_ten_groups")) { openSession(result, limit: 10) }
                    Button(L10n.text("app_filter_and_sort")) { showingFilters = true }
                }
                .disabled(!model.canClean)
            }
            .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func openSession(_ result: ScanResult, limit: Int?) {
        let visible = model.visibleGroups
        let pending = visible.filter { model.status(for: $0) == .pending || model.status(for: $0) == .deferred }
        reviewQueue = limit.map { Array(pending.prefix($0)) } ?? visible
        selectedGroup = limit == nil ? visible.first { $0.id == model.resumeGroup?.id }?.id ?? pending.first?.id : reviewQueue.first?.id
        if let selectedGroup { reviewPath = [selectedGroup] }
        batchSummary = nil
    }

    private func scanSummary(_ result: ScanResult) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.resultsStale ? Color.orange : Color.blue)
                Image(systemName: model.resultsStale ? "arrow.clockwise" : "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.resultsStale ? L10n.text("app_scan_again") : L10n.text("app_scan_complete"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text("app_arg1_processed_arg2_skipped_arg3_failed_0_unfinished", Int64(result.scanned + result.reused), Int64(result.issues.filter { $0.reason == .cloudSkipped }.count), Int64(result.issues.filter { $0.reason != .cloudSkipped }.count)))
                    .font(.caption)
                if model.resultsStale {
                    Text(L10n.text("app_the_photo_library_changed_scan_again_before_cleanup"))
                } else if result.groups.isEmpty {
                    Text(L10n.text("app_arg1_photos_checked", Int64(result.scanned + result.reused)))
                } else {
                    Text(result.groups.count == 1 ? L10n.text("app_1_duplicate_group_to_review") : L10n.text("app_arg1_duplicate_groups_to_review", Int64(result.groups.count)))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scan-summary")
    }

    private func progressView(_ progress: ScanProgress) -> some View {
        let title: String
        let complete: Int
        let total: Int
        switch progress {
        case .fingerprinting(let done, let count): (title, complete, total) = (L10n.text("app_reading_photos"), done, count)
        case .comparing(let done, let count): (title, complete, total) = (L10n.text("app_comparing_photos"), done, count)
        case .similarity(let done, let count): (title, complete, total) = (L10n.text("app_finding_similar_scenes"), done, count)
        }
        return ProgressView(value: Double(complete), total: Double(max(1, total))) {
            Text("\(title) · \(complete)/\(total)").font(.caption)
        }
    }

    private func downloadStatus(_ download: CloudDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !download.ended && download.remaining > 0 {
                let percent = Int(download.processed * 100 / Double(download.total))
                ProgressView(value: download.processed, total: Double(download.total)) {
                    Label(L10n.text("app_downloading_from_icloud"), systemImage: "icloud.and.arrow.down")
                } currentValueLabel: {
                    Text("\(percent)%").monospacedDigit()
                }
                .accessibilityIdentifier("icloud-download-progress")
            } else if download.cancelled {
                Label(L10n.text("app_icloud_download_cancelled"), systemImage: "icloud")
            } else if download.needsRetry {
                Label(L10n.text("app_icloud_download_incomplete"), systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            } else {
                Label(L10n.text("app_icloud_download_finished"), systemImage: "icloud")
            }
            Text(L10n.text("app_arg1_available_arg2_failed_arg3_pending", Int64(download.available), Int64(download.failed), Int64(download.remaining)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private var cleanupConfirmation: some View {
        let groups = model.cleanupGroups
        let pairs = groups.flatMap(\.pairs)
        let hiddenCount = model.hiddenCandidateCount
        return NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if hiddenCount > 0 {
                            Text(L10n.text("app_arg1_pending_photos_are_outside_the_current_filters_all_confirmed_candidates_are_shown_here", Int64(hiddenCount)))
                                .font(.subheadline)
                        }
                        ForEach(groups) { group in
                            CleanupGroupPreview(model: model, group: group, width: max(1, geometry.size.width - 32),
                                                heightBudget: min(420, max(240, geometry.size.height * 0.55)))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(L10n.text("app_confirm_cleanup"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("app_cancel")) { confirmingCleanup = false }
                        .accessibilityIdentifier("cleanup-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("app_move_selected"), role: .destructive) {
                        confirmingCleanup = false
                        Task { await model.applyCleanup(pairs) }
                    }
                    .disabled(!model.canClean || pairs.isEmpty)
                    .accessibilityIdentifier("confirm-cleanup")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 720, minHeight: 340, idealHeight: 640)
        #endif
    }

    private var issues: some View {
        NavigationStack {
            List {
                if model.pendingDownloadCount > 0 {
                    Button {
                        showingIssues = false
                        model.downloadPendingPhotos()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L10n.text("app_download_pending_photos_from_icloud"), systemImage: "icloud.and.arrow.down")
                            Text(L10n.text("app_arg1_photos_pending", Int64(model.pendingDownloadCount)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.canScan)
                }
                Section(L10n.text("app_skipped_photos")) {
                    ForEach((model.result?.issues ?? []).filter { $0.reason == .cloudSkipped }, id: \.id) { _ in
                        Label(L10n.text("app_icloud_photo_skipped_by_policy"), systemImage: "icloud.slash")
                    }
                }
                ForEach(Array((model.result?.issues ?? []).filter { $0.reason != .cloudSkipped }.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.id.source.hasPrefix("folder:") ? URL(fileURLWithPath: issue.id.item).lastPathComponent : L10n.text("app_photos"))
                        Text(issue.reason.label).font(.caption).foregroundStyle(.secondary)
                        if let detail = issue.detail {
                            Text(L10n.text("diagnostic_original_detail", detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("app_scan_issues"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { Button(L10n.text("app_done")) { showingIssues = false } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }
}

private extension AssetIssueReason {
    var label: String {
        switch self {
        case .inaccessible: L10n.text("app_unavailable")
        case .changedDuringScan: L10n.text("app_changed_during_scan")
        case .unreadableImage: L10n.text("app_unreadable_image")
        case .unsupportedImage: L10n.text("app_unsupported_image")
        case .cloudSkipped: L10n.text("app_skipped_by_icloud_policy")
        case .cloudDownloadRequired: L10n.text("app_icloud_download_required")
        case .cloudDownloadFailed: L10n.text("app_icloud_download_failed")
        case .sceneAnalysisFailed: L10n.text("app_scene_analysis_could_not_finish")
        }
    }
}


private struct CleanupGroupPreview: View {
    let model: ReviewModel
    let group: ReviewModel.CleanupGroup
    let width: CGFloat
    let heightBudget: CGFloat
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false
    @ScaledMetric(relativeTo: .caption) private var minimumPreviewWidth: CGFloat = 170
    @State private var enlarged: PhotoAsset?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if group.keep != nil {
                Text(L10n.text("app_will_remove_arg1", Int64(group.pairs.count))).font(.headline)
            } else {
                Label(L10n.text("app_delete_entire_group_arg1_photos", Int64(group.pairs.count)), systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            if group.match == .similarPhoto {
                Text(L10n.text("app_similar_photos_check_differences_before_confirming"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if group.match == .visualDuplicate {
                Text(L10n.text("app_possible_same_image_check_differences_before_confirming"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let assets = group.retained
            let photos = assets + group.pairs.map(\.remove)
            let columns = CleanupPreviewLayout.columns(width: width, minimumColumnWidth: minimumPreviewWidth)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(stride(from: 0, to: photos.count, by: columns)), id: \.self) { start in
                    CleanupPreviewLayout(heightBudget: heightBudget, minimumColumnWidth: minimumPreviewWidth) {
                        ForEach(photos[start..<min(start + columns, photos.count)]) { asset in
                            CleanupPhotoPreview(model: model, asset: asset, removing: group.pairs.contains { $0.remove.id == asset.id },
                                                showFilename: showFilenames) {
                                enlarged = asset
                            }
                        }
                    }
                }
            }
            Divider()
        }
        .sheet(item: $enlarged) { asset in
            CleanupPhotoDetail(model: model, asset: asset)
        }
    }
}

private struct CleanupAspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

struct CleanupPreviewLayout: Layout {
    let heightBudget: CGFloat
    var minimumColumnWidth: CGFloat = 170

    static func columns(width: CGFloat, minimumColumnWidth: CGFloat = 170) -> Int {
        max(1, Int((width + 12) / (max(1, minimumColumnWidth) + 12)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        Self.frames(width: width, heightBudget: heightBudget,
                    aspects: subviews.map { $0[CleanupAspectRatioKey.self] }, minimumColumnWidth: minimumColumnWidth) { index, width in
            subviews[index].sizeThatFits(.init(width: width, height: 0)).height
        }
    }

    static func frames(width: CGFloat, heightBudget: CGFloat, aspects: [CGFloat],
                       minimumColumnWidth: CGFloat = 170, captionHeight: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        let width = max(1, width)
        let spacing: CGFloat = 12
        let aspects = aspects.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let columns = columns(width: width, minimumColumnWidth: minimumColumnWidth)
        var result: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: aspects.count, by: columns) {
            let row = Array(aspects[start..<min(start + columns, aspects.count)])
            let count = CGFloat(row.count)
            let columnWidth = max(1, (width - spacing * (count - 1)) / count)
            let captions = row.indices.map { captionHeight(start + $0, columnWidth) }
            let imageHeight = max(1, heightBudget - (captions.max() ?? 0))
            let rowImages = row.map { min(imageHeight, columnWidth / $0) }
            let rowArea = zip(row, rowImages).reduce(CGFloat.zero) { $0 + $1.0 * $1.1 * $1.1 }

            let fullCaptions = row.indices.map { captionHeight(start + $0, width) }
            let idealImages = row.map { width / $0 }
            let available = max(1, heightBudget - fullCaptions.reduce(0, +) - spacing * (count - 1))
            let scale = min(1, available / max(1, idealImages.reduce(0, +)))
            let stackedImages = idealImages.map { $0 * scale }
            let stackedArea = zip(row, stackedImages).reduce(CGFloat.zero) { $0 + $1.0 * $1.1 * $1.1 }

            // Prefer a compact row unless stacking improves fitted image area by at least 15%.
            if row.count > 1 && stackedArea >= rowArea * 1.15 {
                for index in row.indices {
                    let height = fullCaptions[index] + stackedImages[index]
                    result.append(CGRect(x: 0, y: y, width: width, height: height))
                    y += height + spacing
                }
            } else {
                for index in row.indices {
                    result.append(CGRect(x: CGFloat(index) * (columnWidth + spacing), y: y,
                                         width: columnWidth, height: captions[index] + rowImages[index]))
                }
                y += zip(captions, rowImages).map(+).max() ?? 0
                y += spacing
            }
        }
        return result
    }
}

private struct CleanupPhotoPreview: View {
    let model: ReviewModel
    let asset: PhotoAsset
    let removing: Bool
    let showFilename: Bool
    let open: () -> Void
    @State private var preview: LoadedPreview?
    @State private var aspectRatio: CGFloat = 1

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Text(removing ? L10n.text("app_will_remove") : L10n.text("app_keep"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(removing ? Color.red : Color.primary)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let image = preview?.image {
                        Image(image, scale: 1, label: Text(L10n.text("app_preview")))
                            .resizable()
                            .scaledToFit()
                            .padding(2)
                    } else if preview != nil {
                        Image(systemName: "photo.badge.exclamationmark")
                            .accessibilityLabel(L10n.text("app_preview_unavailable"))
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(removing ? Color.red : Color.secondary.opacity(0.35), lineWidth: 2)
                }
                PhotoMetadataView(preview: preview)
                if showFilename { Text(asset.name).font(.caption).lineLimit(1) }
                let source = model.sourceLabel(asset.id.source)
                let destination = asset.id.source == "photos-library" ? L10n.text("app_recently_deleted") : L10n.text("app_trash")
                Text(removing ? "\(source) → \(destination)" : source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(removing ? L10n.text("app_will_remove") : L10n.text("app_keep")), \(preview?.details ?? L10n.text("app_photo_details_unavailable"))"))
        .accessibilityIdentifier("cleanup-\(removing ? "remove" : "keep")-\(asset.name)")
        .task(id: asset) {
            if let loaded = try? await model.preview(for: asset) {
                guard !Task.isCancelled else { return }
                preview = loaded
                aspectRatio = loaded.aspectRatio ?? 1
            } else if !Task.isCancelled {
                preview = LoadedPreview(asset: asset, image: nil, format: nil, byteCount: nil, dimensions: nil)
            }
        }
        .layoutValue(key: CleanupAspectRatioKey.self, value: aspectRatio)
        .onDisappear {
            if let loaded = preview {
                preview = LoadedPreview(asset: asset, image: nil, format: loaded.format,
                                        byteCount: loaded.byteCount, dimensions: loaded.dimensions)
            }
        }
    }
}

private struct CleanupPhotoDetail: View {
    let model: ReviewModel
    let asset: PhotoAsset
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilename = false
    @State private var image: CGImage?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
                    Image(image, scale: 1, label: Text(L10n.text("app_preview")))
                        .resizable()
                        .scaledToFit()
                } else if finished {
                    ContentUnavailableView(L10n.text("app_preview_unavailable"), systemImage: "photo.badge.exclamationmark")
                } else {
                    ProgressView()
                }
                if showFilename { Text(asset.name).font(.caption).textSelection(.enabled) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L10n.text("app_photo"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("app_done")) { dismiss() }
                }
            }
        }
        .task(id: asset) {
            image = try? await model.thumbnail(for: asset, pixelSize: 2560)
            finished = true
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 800, minHeight: 340, idealHeight: 640)
        #endif
    }
}

struct CleanupOutcomeView: View {
    let items: [CleanupItem]
    let model: ReviewModel

    private var incomplete: [CleanupItem] { items.filter { $0.status == .failed || $0.status == .skipped } }
    private var moved: Int { items.count - incomplete.count }

    var body: some View {
        List {
            Section {
                Label(incomplete.isEmpty ? L10n.text("app_cleanup_finished") : moved == 0 ? L10n.text("app_no_photos_moved") : L10n.text("app_cleanup_partially_completed"),
                      systemImage: incomplete.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(incomplete.isEmpty ? Color.primary : .orange)
                Text(L10n.text("app_arg1_moved_arg2_skipped_arg3_failed", Int64(moved), Int64(items.filter { $0.status == .skipped }.count), Int64(items.filter { $0.status == .failed }.count)))
                    .foregroundStyle(.secondary)
            }
            if !incomplete.isEmpty {
                Section(L10n.text("app_photos_not_moved")) {
                    ForEach(Array(incomplete.enumerated()), id: \.element.id) { index, item in
                        CleanupIssueRow(item: item, number: index + 1, model: model)
                    }
                }
            }
        }
        .accessibilityIdentifier("cleanup-outcome")
    }
}

private struct CleanupIssueRow: View {
    let item: CleanupItem
    let number: Int
    let model: ReviewModel
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilename = false
    @State private var image: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.secondary.opacity(0.1)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("app_photo_preview"))
                .accessibilityIdentifier("cleanup-issue-preview-\(item.pair.remove.name)")
            VStack(alignment: .leading, spacing: 4) {
                if showFilename { Text(item.pair.remove.name).lineLimit(2) }
                else { Text(L10n.text("app_photo_arg1", Int64(number))) }
                Text(item.status == .skipped ? L10n.text("app_skipped") : L10n.text("app_failed")).fontWeight(.medium)
                if let reason = item.failureReason {
                    Text(L10n.cleanupFailure(reason)).textSelection(.enabled)
                } else {
                    Text(L10n.text("app_the_photo_could_not_be_moved_scan_again_to_retry"))
                    if let detail = item.detail {
                        Text(L10n.text("diagnostic_original_detail", detail)).textSelection(.enabled)
                    }
                }
                Text(model.sourceLabel(item.pair.remove.id.source)).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: item.id) {
            image = try? await model.thumbnail(for: item.pair.remove, pixelSize: 256)
        }
    }
}
