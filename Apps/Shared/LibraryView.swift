import AlbumWinnowCore
import Photos
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

struct LibraryView: View {
    let model: ReviewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedGroup: AssetID?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var importing = false
    @State private var showingHistory = false
    @State private var showingIssues = false

    var body: some View {
        #if os(macOS)
        content
        #else
        content.fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.addFolder(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    private var content: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            sidebar
                .navigationTitle("Sources")
                .navigationSplitViewColumnWidth(
                    min: dynamicTypeSize.isAccessibilitySize ? 250 : 180,
                    ideal: dynamicTypeSize.isAccessibilitySize ? 280 : 215,
                    max: 300
                )
        } content: {
            groups
                .navigationTitle("Duplicates")
                .toolbarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 350)
        } detail: {
            if let group = model.result?.groups.first(where: { $0.id == selectedGroup }) {
                GroupReviewView(group: group, model: model) { showingHistory = true }
                    .id(group.id)
            } else {
                ContentUnavailableView("Select a Group", systemImage: "photo.on.rectangle.angled")
            }
        }
        .onChange(of: model.result) { _, result in
            #if os(iOS)
            if result != nil { compactColumn = .content }
            if result?.groups.contains(where: { $0.id == selectedGroup }) != true { selectedGroup = nil }
            #else
            if let result, result.groups.contains(where: { $0.id == selectedGroup }) { return }
            selectedGroup = result?.groups.first?.id
            #endif
        }
        .sheet(isPresented: $showingHistory) {
            history.task { await model.loadHistory() }
        }
        .sheet(isPresented: $showingIssues) { issues }
        .alert("AlbumWinnow", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List {
            Section("Photo Library") {
                Toggle(isOn: Binding(
                    get: { model.photosEnabled && model.allowsPhotos },
                    set: { enabled in Task { await model.setPhotosEnabled(enabled) } }
                )) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Photos")
                    } else {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                }
                .disabled(model.running || model.cleaning)
                .accessibilityIdentifier("photos-source")
                if model.authorization == .limited {
                    Text("Limited access").foregroundStyle(.secondary)
                    #if os(iOS)
                    Button("Manage Photo Access") { managePhotoAccess() }
                    #endif
                } else if model.authorization == .denied {
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    #endif
                }
            }

            Section("Folders") {
                ForEach(model.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button("Remove Source", role: .destructive) { model.removeFolder(folder.id) }
                                .disabled(model.running || model.cleaning)
                        }
                }
                Button(action: pickFolder) {
                    Label("Add Folder", systemImage: "plus")
                }
                .disabled(model.running || model.cleaning)
                .accessibilityIdentifier("add-folder")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let download = model.downloadProgress { downloadStatus(download) }
                if let progress = model.progress {
                    progressView(progress)
                } else if model.running && model.downloadProgress == nil {
                    ProgressView("Preparing scan…")
                }
                if model.cleaning { ProgressView("Moving selected photos…") }
                #if os(iOS)
                if model.result != nil && !model.running {
                    Button("View Results") { compactColumn = .content }
                }
                #endif
                HStack {
                    if model.running, let download = model.downloadProgress, download.remaining > 0, !download.ended {
                        Button("Cancel Download") { model.cancelScan() }
                    } else if model.running {
                        Button("Cancel Scan") { model.cancelScan() }
                    } else {
                        Button("Scan", systemImage: "magnifyingglass") { model.scan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canScan)
                            .accessibilityIdentifier("start-scan")
                    }
                    Spacer()
                    Button("Cleanup History", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                        .labelStyle(.iconOnly)
                        .help("Cleanup History")
                }
            }
            .padding()
            .background(.bar)
        }
    }

    #if os(iOS)
    private func managePhotoAccess() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow,
              let controller = window.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
    #endif

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Folder"
        panel.begin { response in
            if response == .OK, let url = panel.url { model.addFolder(url) }
        }
        #else
        importing = true
        #endif
    }

    private var groups: some View {
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
                scanResults(result)
            } else if let cleanup = model.lastCleanup {
                ContentUnavailableView(
                    "Cleanup Finished",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(cleanupSummary(cleanup) + " Scan again to refresh duplicates.")
                )
            } else if model.resultsStale {
                ContentUnavailableView("Scan Again", systemImage: "arrow.clockwise",
                                       description: Text("The selected sources or their contents changed."))
            } else {
                ContentUnavailableView("Ready to Scan", systemImage: "photo.stack",
                                       description: Text("Choose a source and start a scan."))
            }
        }
    }

    private func scanResults(_ result: ScanResult) -> some View {
        Group {
            if result.groups.isEmpty {
                ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.circle")
            } else {
                List(selection: $selectedGroup) {
                    ForEach(result.groups) { group in
                        NavigationLink(value: group.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.preferred.name).lineLimit(1)
                                Text("\(group.duplicates.count + 1) photos")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("duplicate-groups")
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
        let moved = run.items.count { $0.status == .movedToTrash || $0.status == .movedToRecentlyDeleted }
        return "\(moved) moved · \(run.items.count - moved) not moved."
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
                        compactColumn = .sidebar
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
