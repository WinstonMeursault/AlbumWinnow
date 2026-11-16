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
                .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 300)
        } content: {
            groups
                .navigationTitle("Duplicates")
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
                    Label("Photos", systemImage: "photo.on.rectangle")
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
                if let progress = model.progress { progressView(progress) }
                if model.cleaning { ProgressView("Moving selected photos…") }
                #if os(iOS)
                if model.result != nil && !model.running {
                    Button("View Results") { compactColumn = .content }
                }
                #endif
                HStack {
                    if model.running {
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
            if let result = model.result {
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
                }
                if !result.issues.isEmpty {
                    Button("Review \(result.issues.count) Scan Issues") { showingIssues = true }
                        .padding(10)
                }
            } else if model.running {
                ContentUnavailableView("Scanning Photos", systemImage: "magnifyingglass")
            } else if model.resultsStale {
                ContentUnavailableView("Scan Again", systemImage: "arrow.clockwise",
                                       description: Text("The selected sources or their contents changed."))
            } else {
                ContentUnavailableView("Ready to Scan", systemImage: "photo.stack",
                                       description: Text("Choose a source and start a scan."))
            }
        }
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

    private var history: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No Cleanup History", systemImage: "clock")
                } else {
                    List(model.history) { run in
                        Section(run.startedAt.formatted()) {
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
            .toolbar { Button("Done") { showingHistory = false } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }

    private var issues: some View {
        NavigationStack {
            List {
                if model.hasPendingDownloads {
                    Button("Download Pending Photos from iCloud") {
                        showingIssues = false
                        compactColumn = .sidebar
                        model.downloadPendingPhotos()
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
