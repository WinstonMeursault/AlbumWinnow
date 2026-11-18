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

            Section("Review") {
                Toggle("Show Filenames in Review", isOn: $showReviewFilenames)
                    .accessibilityIdentifier("show-review-filenames")
            }

            Section("Interaction") {
                Picker("Group Transition", selection: $reviewAnimation) {
                    ForEach(ReviewAnimation.allCases) { animation in
                        Text(animation.title).tag(animation.rawValue)
                    }
                }
                .accessibilityIdentifier("review-animation")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
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
