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
            .navigationTitle("Duplicates")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    settingsButton("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .help("Settings")
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
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        #endif
        .alert("AlbumWinnow", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
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
            return Text("Group \(index + 1) of \(groups.count)")
        }
        return Text("Review Group")
    }

    private func finishReview() {
        if !reviewQueue.isEmpty {
            let completed = reviewQueue.filter { model.status(for: $0) == .confirmed || model.status(for: $0) == .kept }.count
            batchSummary = "\(completed) of \(reviewQueue.count) groups decided."
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
                Button("Close Review", systemImage: "xmark") { selectedGroup = nil }
                    .labelStyle(.iconOnly)
                    .help("Close Review")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            review
        }
    }

    private func settingsButton(_ title: LocalizedStringKey, systemImage: String) -> some View {
        #if os(macOS)
        SettingsLink { Label(title, systemImage: systemImage) }
        #else
        Button { showingSettings = true } label: { Label(title, systemImage: systemImage) }
        #endif
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let download = model.downloadProgress { downloadStatus(download) }
            if model.running || model.scanCancelled {
                if let counts = model.scanAccounting {
                    Text("\(counts.processed) processed · \(counts.skipped) skipped · \(counts.failed) failed · \(counts.unfinished) unfinished")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.scanCancelled {
                    Text("Scan cancelled before enumeration finished. Remaining count unknown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let progress = model.progress {
                progressView(progress)
            } else if model.running && model.downloadProgress == nil {
                ProgressView("Preparing scan…")
            }
            HStack(spacing: 8) {
                if model.running, let download = model.downloadProgress, download.remaining > 0, !download.ended {
                    Button("Cancel Download") { model.cancelScan() }
                } else if model.running {
                    Button("Cancel Scan") { model.cancelScan() }
                } else {
                    Button { model.scan() } label: {
                        Label(model.lastCleanup == nil ? "Scan" : "Scan Again", systemImage: "magnifyingglass")
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
                        Text("Confirm Cleanup (\(model.selectedCount))")
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
                ContentUnavailableView("Moving Selected Photos", systemImage: "trash")
            } else if model.running {
                ContentUnavailableView(
                    model.downloadProgress == nil ? "Scanning Photos" : "Updating Scan Results",
                    systemImage: "magnifyingglass",
                    description: Text("Duplicates will be ready to review when the scan finishes.")
                )
            } else if let cleanup = model.lastCleanup {
                CleanupOutcomeView(items: cleanup, model: model)
            } else if let result = model.result {
                scanResults(result, wide: wide, narrowed: narrowed)
            } else if !model.hasScanSources {
                ContentUnavailableView {
                    Label("Choose Scan Sources", systemImage: "photo.stack")
                } description: {
                    Text("Enable Photos or add a folder to start scanning.")
                } actions: {
                    settingsButton("Configure Scan Sources", systemImage: "gearshape")
                        .buttonStyle(.glass)
                }
            } else if model.resultsStale {
                ContentUnavailableView("Scan Again", systemImage: "arrow.clockwise",
                                       description: Text("The selected sources or their contents changed."))
            } else {
                ContentUnavailableView("Ready to Scan", systemImage: "photo.stack")
            }
        }
    }

    private func scanResults(_ result: ScanResult, wide: Bool, narrowed: Bool) -> some View {
        Group {
            if result.groups.isEmpty {
                VStack(spacing: 0) {
                    scanSummaryCard(result)
                    ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.circle")
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
                Button(result.issues.count == 1 ? "Review 1 Scan Issue" : "Review \(result.issues.count) Scan Issues") {
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
            if !model.protectionAvailable {
                Label("Protection unavailable · Cleanup disabled", systemImage: "lock.trianglebadge.exclamationmark")
            }
            Text("\(model.visibleGroups.count) of \(result.groups.count) groups shown · \(model.resultQuery.sort.title)")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = model.reviewNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let batchSummary { Text(batchSummary).font(.caption) }
            if model.visibleGroups.isEmpty, !result.groups.isEmpty {
                Text("No groups match these filters.").font(.subheadline)
                Button("Clear Filters") { model.setResultQuery(ReviewResultQuery()) }
            }
            HStack {
                Button("Continue Review") { openSession(result, limit: nil) }
                    .disabled(model.resumeGroup == nil || !model.canClean)
                Menu("Review Options", systemImage: "ellipsis.circle") {
                    Button("Review Ten Groups") { openSession(result, limit: 10) }
                    Button("Filter and Sort") { showingFilters = true }
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
                Text(model.resultsStale ? "Scan Again" : "Scan Complete")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(result.scanned + result.reused) processed · \(result.issues.filter { $0.reason == .cloudSkipped }.count) skipped · \(result.issues.filter { $0.reason != .cloudSkipped }.count) failed · 0 unfinished")
                    .font(.caption)
                if model.resultsStale {
                    Text("The photo library changed. Scan again before cleanup.")
                } else if result.groups.isEmpty {
                    Text("\(result.scanned + result.reused) photos checked")
                } else {
                    Text(result.groups.count == 1 ? "1 duplicate group to review" : "\(result.groups.count) duplicate groups to review")
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
        case .fingerprinting(let done, let count): (title, complete, total) = ("Reading photos", done, count)
        case .comparing(let done, let count): (title, complete, total) = ("Comparing photos", done, count)
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
                    Label("Downloading from iCloud", systemImage: "icloud.and.arrow.down")
                } currentValueLabel: {
                    Text("\(percent)%").monospacedDigit()
                }
                .accessibilityIdentifier("icloud-download-progress")
            } else if download.cancelled {
                Label("iCloud Download Cancelled", systemImage: "icloud")
            } else if download.needsRetry {
                Label("iCloud Download Incomplete", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            } else {
                Label("iCloud Download Finished", systemImage: "icloud")
            }
            Text("\(download.available) available · \(download.failed) failed · \(download.remaining) pending")
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
                            Text("\(hiddenCount) pending photos are outside the current filters. All confirmed candidates are shown here.")
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
            .navigationTitle("Confirm Cleanup")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmingCleanup = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Selected", role: .destructive) {
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
                            Label("Download Pending Photos from iCloud", systemImage: "icloud.and.arrow.down")
                            Text("\(model.pendingDownloadCount) photos pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.canScan)
                }
                Section("Skipped Photos") {
                    ForEach((model.result?.issues ?? []).filter { $0.reason == .cloudSkipped }, id: \.id) { _ in
                        Label("iCloud photo skipped by policy", systemImage: "icloud.slash")
                    }
                }
                ForEach(Array((model.result?.issues ?? []).filter { $0.reason != .cloudSkipped }.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.id.source.hasPrefix("folder:") ? URL(fileURLWithPath: issue.id.item).lastPathComponent : "Photos")
                        Text(issue.reason.label).font(.caption).foregroundStyle(.secondary)
                        if let detail = issue.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Scan Issues")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingIssues = false } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }
}

private extension AssetIssueReason {
    var label: String {
        switch self {
        case .inaccessible: "Unavailable"
        case .changedDuringScan: "Changed during scan"
        case .unreadableImage: "Unreadable image"
        case .unsupportedImage: "Unsupported image"
        case .cloudSkipped: "Skipped by iCloud policy"
        case .cloudDownloadRequired: "iCloud download required"
        case .cloudDownloadFailed: "iCloud download failed"
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
                Text("Will Remove (\(group.pairs.count))").font(.headline)
            } else {
                Label("Delete entire group · \(group.pairs.count) photos", systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            if group.match == .similarPhoto {
                Text("Similar photos · Check differences before confirming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if group.match == .visualDuplicate {
                Text("Possible same image · Check differences before confirming.")
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
                Text(removing ? "Will Remove" : "Keep")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(removing ? Color.red : Color.primary)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let image = preview?.image {
                        Image(image, scale: 1, label: Text("Preview"))
                            .resizable()
                            .scaledToFit()
                            .padding(2)
                    } else if preview != nil {
                        Image(systemName: "photo.badge.exclamationmark")
                            .accessibilityLabel("Preview unavailable")
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
                let destination = asset.id.source == "photos-library" ? "Recently Deleted" : "Trash"
                Text(removing ? "\(source) → \(destination)" : source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(removing ? String(localized: "Will Remove") : String(localized: "Keep")), \(preview?.details ?? String(localized: "Photo details unavailable"))"))
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
                    Image(image, scale: 1, label: Text("Preview"))
                        .resizable()
                        .scaledToFit()
                } else if finished {
                    ContentUnavailableView("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                } else {
                    ProgressView()
                }
                if showFilename { Text(asset.name).font(.caption).textSelection(.enabled) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Photo")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                Label(incomplete.isEmpty ? "Cleanup Finished" : moved == 0 ? "No Photos Moved" : "Cleanup Partially Completed",
                      systemImage: incomplete.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(incomplete.isEmpty ? Color.primary : .orange)
                Text("\(moved) moved · \(items.filter { $0.status == .skipped }.count) skipped · \(items.filter { $0.status == .failed }.count) failed")
                    .foregroundStyle(.secondary)
            }
            if !incomplete.isEmpty {
                Section("Photos Not Moved") {
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
                .accessibilityLabel("Photo preview")
                .accessibilityIdentifier("cleanup-issue-preview-\(item.pair.remove.name)")
            VStack(alignment: .leading, spacing: 4) {
                if showFilename { Text(item.pair.remove.name).lineLimit(2) }
                else { Text("Photo \(number)") }
                Text(item.status == .skipped ? "Skipped" : "Failed").fontWeight(.medium)
                Text(item.detail ?? String(localized: "The photo could not be moved. Scan again to retry."))
                    .textSelection(.enabled)
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
