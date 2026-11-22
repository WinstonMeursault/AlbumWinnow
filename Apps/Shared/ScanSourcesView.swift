import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

struct ScanSourcesView: View {
    let model: ReviewModel
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showReviewFilenames = false
    @AppStorage(ReviewAnimation.defaultsKey) private var reviewAnimation = ReviewAnimation.slide.rawValue
    @AppStorage(ReviewHand.defaultsKey) private var reviewHand = ReviewHand.right.rawValue
    @State private var resettingReview = false
    @State private var showingAbout = false
    #if os(iOS)
    @State private var importing = false
    #endif

    var body: some View {
        Form {
            Section("Scan Sources") {
                Toggle("Photos", systemImage: "photo.on.rectangle", isOn: Binding(
                    get: { model.photosEnabled && model.allowsPhotos },
                    set: { enabled in Task { await model.setPhotosEnabled(enabled) } }
                ))
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("photos-source")

                Toggle("Skip Photos Stored Only in iCloud", isOn: Binding(
                    get: { model.skipCloudPhotos }, set: { model.setSkipCloudPhotos($0) }
                ))
                .disabled(!model.canEditSources)
                Text(model.skipCloudPhotos
                     ? "Scanning does not download missing iCloud resources. Skipped photos may be absent from results."
                     : "Scanning may download original photo resources from iCloud and use network data.")
                    .font(.caption).foregroundStyle(.secondary)

                if model.authorization == .limited {
                    Text("Limited access").foregroundStyle(.secondary)
                    #if os(iOS)
                    Button("Manage Photo Access", action: managePhotoAccess)
                        .disabled(!model.canEditSources)
                    #endif
                } else if model.authorization == .denied || model.authorization == .restricted {
                    Text("Allow Photos access in System Settings to scan the photo library.")
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    #endif
                }

                ForEach(model.folders) { folder in
                    HStack {
                        Label(folder.name, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            model.removeFolder(folder.id)
                        } label: {
                            Label("Remove \(folder.name) from scan sources", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canEditSources)
                    }
                }
                Button(action: pickFolder) {
                    Label("Add Folder…", systemImage: "plus")
                }
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("add-folder")
            }

            ScanPolicySettings(model: model)

            Section("Review") {
                Toggle("Find Burst and Similar Scenes", isOn: Binding(get: { model.similarScenesEnabled }, set: { model.setSimilarScenesEnabled($0) }))
                    .disabled(!model.canEditSources)
                Text("Adds a separate Similar Photos queue and includes accessible burst members. Natural-photo accuracy has not been measured. Duplicate checks and cleanup confirmation remain separate.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show Filenames in Review", isOn: $showReviewFilenames)
                    .accessibilityIdentifier("show-review-filenames")
            }

            Section("Interaction") {
                Picker("Review Button Layout", selection: $reviewHand) {
                    Text("Left Hand").tag(ReviewHand.left.rawValue)
                    Text("Right Hand").tag(ReviewHand.right.rawValue)
                }
                .accessibilityIdentifier("review-hand")
                Text(reviewHand == ReviewHand.left.rawValue
                     ? "Confirm  ·  Skip  ·  Delete All"
                     : "Delete All  ·  Skip  ·  Confirm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Group Transition", selection: $reviewAnimation) {
                    ForEach(ReviewAnimation.allCases) { animation in
                        Text(animation.title).tag(animation.rawValue)
                    }
                }
                .accessibilityIdentifier("review-animation")
            }

            Section("Storage") {
                Button {
                    Task { await model.clearScanCache() }
                } label: {
                    if model.clearingCache {
                        ProgressView("Clearing Scan Cache…")
                    } else {
                        Label("Clear Scan Cache", systemImage: "externaldrive.badge.minus")
                    }
                }
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("clear-scan-cache")
                Button("Reset Review Progress", role: .destructive) { resettingReview = true }
                    .disabled(!model.canEditSources || !model.protectionAvailable)
                Text("Resets kept groups, deferred groups and pending cleanup. Photo locks remain protected.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.cacheStatus ?? "Frees scan cache storage. Photos and source access are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Button("About & Open Source", systemImage: "info.circle") {
                    showingAbout = true
                }
                .accessibilityIdentifier("about-open-source")
                Link("Privacy Policy", destination: AboutView.privacyURL)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Reset Review Progress?", isPresented: $resettingReview, titleVisibility: .visible) {
            Button("Reset Review Progress", role: .destructive) { model.resetReviewProgress() }
        } message: {
            Text("Clears all group decisions and pending cleanup. Locked photos remain locked. No photos are deleted.")
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.addFolder(url)
            case .failure(let error): model.sourceErrorMessage = error.localizedDescription
            }
        }
        #endif
        .alert("Scan Sources", isPresented: Binding(
            get: { model.sourceErrorMessage != nil },
            set: { if !$0 { model.sourceErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.sourceErrorMessage = nil }
        } message: {
            Text(model.sourceErrorMessage ?? "")
        }
    }

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

    #if os(iOS)
    private func managePhotoAccess() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow,
              var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }
    #endif
}
