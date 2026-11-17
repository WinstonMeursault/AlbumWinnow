import AlbumWinnowCore
import SwiftUI

struct LibraryView: View {
    let model: ReviewModel
    @State private var selectedGroup: AssetID?
    @State private var reviewPath: [AssetID] = []
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @State private var showingHistory = false
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
                    if let group {
                        Divider()
                        reviewPane(group)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onChange(of: wide) { _, wide in
                    if wide {
                        selectedGroup = reviewPath.last
                        reviewPath.removeAll()
                    } else {
                        reviewPath = selectedGroup.map { [$0] } ?? []
                        selectedGroup = nil
                    }
                }
            }
            .navigationTitle("Duplicates")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Cleanup History", systemImage: "clock.arrow.circlepath") {
                        showingHistory = true
                    }
                    .labelStyle(.iconOnly)
                    .help("Cleanup History")
                    settingsButton("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .help("Settings")
                }
            }
            .navigationDestination(for: AssetID.self) { id in
                if let group = group(withID: id) {
                    review(group)
                        .navigationTitle("Review Group")
                        .toolbarTitleDisplayMode(.inline)
                }
            }
        }
        .onChange(of: model.result) {
            if group(withID: selectedGroup) == nil { selectedGroup = nil }
            if group(withID: reviewPath.last) == nil { reviewPath.removeAll() }
        }
        .sheet(isPresented: $showingHistory) {
            history.task { await model.loadHistory() }
        }
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

    private func review(_ group: DuplicateGroup) -> some View {
        GroupReviewView(group: group, model: model) { confirmingCleanup = true }
            .id(group.id)
    }

    private func reviewPane(_ group: DuplicateGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Group").font(.headline)
                Spacer()
                Button("Close Review", systemImage: "xmark") { selectedGroup = nil }
                    .labelStyle(.iconOnly)
                    .help("Close Review")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            review(group)
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
            } else if let result = model.result {
                scanSummary(result)
                    .padding(.horizontal)
                Divider()
                scanResults(result, wide: wide, narrowed: narrowed)
            } else if let cleanup = model.lastCleanup {
                ContentUnavailableView {
                    Label("Cleanup Finished", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(cleanupSummary(cleanup))
                } actions: {
                    Button("View Cleanup History") { showingHistory = true }
                }
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
                ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.circle")
            } else {
                DuplicateGallery(groups: result.groups, model: model, selectedGroup: selectedGroup,
                                 narrowed: narrowed, isActive: reviewPath.isEmpty) { group in
                    if wide { selectedGroup = group.id }
                    else { reviewPath = [group.id] }
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

    private func scanSummary(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Scan Complete", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if result.groups.isEmpty {
                Text("\(result.scanned + result.reused) photos checked")
            } else {
                Text(result.groups.count == 1 ? "1 duplicate group to review" : "\(result.groups.count) duplicate groups to review")
                Text("Photos are moved only after you confirm cleanup.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
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
            } else {
                Label(download.cancelled ? "iCloud Download Cancelled" : "iCloud Download Finished",
                      systemImage: "icloud")
            }
            Text("\(download.available) available · \(download.failed) failed · \(download.remaining) pending")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func cleanupSummary(_ run: CleanupRun) -> String {
        let counts = Dictionary(grouping: run.items, by: \.status).mapValues(\.count)
        let moved = counts[.movedToTrash, default: 0] + counts[.movedToRecentlyDeleted, default: 0]
        let summary = "\(moved) moved · \(counts[.skipped, default: 0]) skipped · \(counts[.failed, default: 0]) failed"
        let pending = counts[.pending, default: 0]
        return pending == 0 ? summary : summary + " · \(pending) interrupted"
    }

    private var cleanupConfirmation: some View {
        let groups = model.cleanupGroups
        let pairs = groups.flatMap(\.pairs)
        return NavigationStack {
            List(groups) { group in
                Section {
                    ForEach(group.pairs) { pair in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pair.remove.name)
                            let destination = pair.remove.id.source == "photos-library" ? "Recently Deleted" : "Trash"
                            Text("\(model.sourceLabel(pair.remove.id.source)) → \(destination)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Keep \(group.keep.name) · \(model.sourceLabel(group.keep.id.source))")
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
        .frame(minWidth: 480, minHeight: 340)
        #endif
    }

    private var history: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No Cleanup History", systemImage: "clock")
                } else {
                    List(model.history) { run in
                        Section(run.startedAt.formatted()) {
                            Text(cleanupSummary(run)).font(.subheadline)
                            ForEach(run.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.pair.remove.name)
                                    Text(item.status.label).foregroundStyle(.secondary)
                                    if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cleanup History")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingHistory = false } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
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
                ForEach(Array((model.result?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.id.source.hasPrefix("folder:") ? URL(fileURLWithPath: issue.id.item).lastPathComponent : "Photos")
                        Text(issue.reason.label).font(.caption).foregroundStyle(.secondary)
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

private extension CleanupStatus {
    var label: String {
        switch self {
        case .pending: "Interrupted before a result was recorded"
        case .movedToTrash: "Moved to Trash"
        case .movedToRecentlyDeleted: "Moved to Recently Deleted"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

private extension AssetIssueReason {
    var label: String {
        switch self {
        case .inaccessible: "Unavailable"
        case .changedDuringScan: "Changed during scan"
        case .unreadableImage: "Unreadable image"
        case .unsupportedImage: "Unsupported image"
        case .cloudDownloadRequired: "iCloud download required"
        case .cloudDownloadFailed: "iCloud download failed"
        }
    }
}
