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
    @State private var reconnectingFolder: Data?
    #if os(iOS)
    @State private var importing = false
    #endif

    var body: some View {
        Form {
            Section(L10n.text("app_scan_sources")) {
                Toggle(L10n.text("app_photos"), systemImage: "photo.on.rectangle", isOn: Binding(
                    get: { model.photosEnabled && model.allowsPhotos },
                    set: { enabled in Task { await model.setPhotosEnabled(enabled) } }
                ))
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("photos-source")

                Toggle(L10n.text("app_skip_photos_stored_only_in_icloud"), isOn: Binding(
                    get: { model.skipCloudPhotos }, set: { model.setSkipCloudPhotos($0) }
                ))
                .disabled(!model.canEditSources)
                Text(model.skipCloudPhotos
                     ? L10n.text("app_scanning_does_not_download_missing_icloud_resources_skipped_photos_may_be_absent_from_results")
                     : L10n.text("app_scanning_may_download_original_photo_resources_from_icloud_and_use_network_data"))
                    .font(.caption).foregroundStyle(.secondary)

                if model.authorization == .limited {
                    Text(L10n.text("app_limited_access")).foregroundStyle(.secondary)
                    #if os(iOS)
                    Button(L10n.text("app_manage_photo_access"), action: managePhotoAccess)
                        .disabled(!model.canEditSources)
                    #endif
                } else if model.authorization == .denied || model.authorization == .restricted {
                    Text(L10n.text("app_allow_photos_access_in_system_settings_to_scan_the_photo_library"))
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    Button(L10n.text("app_open_settings")) {
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
                            Label(L10n.text("app_remove_arg1_from_scan_sources", folder.name), systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canEditSources)
                    }
                }
                ForEach(Array(model.unavailableFolders.enumerated()), id: \.element) { index, bookmark in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("app_unavailable_folder_number", Int64(index + 1)), systemImage: "externaldrive.badge.exclamationmark")
                        HStack {
                            Button(L10n.text("app_reconnect_folder")) {
                                reconnectingFolder = bookmark
                                pickFolder()
                            }
                            Button(L10n.text("app_remove_source_record"), role: .destructive) { model.removeUnavailableFolder(bookmark) }
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(!model.canEditSources)
                }
                if !model.unavailableFolders.isEmpty {
                    Button(L10n.text("app_retry_saved_folders")) { model.retryFolders() }
                        .disabled(!model.canEditSources)
                    Text(L10n.text("app_unavailable_folder_explanation")).font(.caption).foregroundStyle(.secondary)
                }
                Button(action: { reconnectingFolder = nil; pickFolder() }) {
                    Label(L10n.text("app_add_folder"), systemImage: "plus")
                }
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("add-folder")
            }

            ScanPolicySettings(model: model)
            SavedProtectionSettings(model: model)

            Section(L10n.text("app_review")) {
                Toggle(L10n.text("app_find_burst_and_similar_scenes"), isOn: Binding(get: { model.similarScenesEnabled }, set: { model.setSimilarScenesEnabled($0) }))
                    .disabled(!model.canEditSources)
                Text(L10n.text("app_adds_a_separate_similar_photos_queue_and_includes_accessible_burst_members_natural_photo_accuracy_has_not_been_measured_duplicate_checks_and_cleanup_confirmation_remain_separate"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("app_show_filenames_in_review"), isOn: $showReviewFilenames)
                    .accessibilityIdentifier("show-review-filenames")
            }

            Section(L10n.text("app_interaction")) {
                Picker(L10n.text("app_review_button_layout"), selection: $reviewHand) {
                    Text(L10n.text("app_left_hand")).tag(ReviewHand.left.rawValue)
                    Text(L10n.text("app_right_hand")).tag(ReviewHand.right.rawValue)
                }
                .accessibilityIdentifier("review-hand")
                Text(reviewHand == ReviewHand.left.rawValue
                     ? L10n.text("app_confirm_skip_delete_all")
                     : L10n.text("app_delete_all_skip_confirm"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.text("app_group_transition"), selection: $reviewAnimation) {
                    ForEach(ReviewAnimation.allCases) { animation in
                        Text(animation.title).tag(animation.rawValue)
                    }
                }
                .accessibilityIdentifier("review-animation")
            }

            Section(L10n.text("app_storage")) {
                Button {
                    Task { await model.clearScanCache() }
                } label: {
                    if model.clearingCache {
                        ProgressView(L10n.text("app_clearing_scan_cache"))
                    } else {
                        Label(L10n.text("app_clear_scan_cache"), systemImage: "externaldrive.badge.minus")
                    }
                }
                .disabled(!model.canEditSources)
                .accessibilityIdentifier("clear-scan-cache")
                Button(L10n.text("app_reset_review_progress"), role: .destructive) { resettingReview = true }
                    .disabled(!model.canEditSources || !model.protectionAvailable)
                Text(L10n.text("app_resets_kept_groups_deferred_groups_and_pending_cleanup_photo_locks_remain_protected"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.cacheStatus ?? L10n.text("app_frees_scan_cache_storage_photos_and_source_access_are_preserved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("app_about")) {
                Button(L10n.text("app_about_open_source"), systemImage: "info.circle") {
                    showingAbout = true
                }
                .accessibilityIdentifier("about-open-source")
                Link(L10n.text("app_privacy_policy"), destination: AboutView.privacyURL)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("app_settings"))
        .confirmationDialog(L10n.text("app_reset_review_progress_confirmation_title"), isPresented: $resettingReview, titleVisibility: .visible) {
            Button(L10n.text("app_reset_review_progress"), role: .destructive) { model.resetReviewProgress() }
        } message: {
            Text(L10n.text("app_clears_all_group_decisions_and_pending_cleanup_locked_photos_remain_locked_no_photos_are_deleted"))
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): acceptFolder(url)
            case .failure(let error): model.sourceErrorMessage = L10n.error(error)
            }
        }
        #endif
        .alert(L10n.text("app_scan_sources"), isPresented: Binding(
            get: { model.sourceErrorMessage != nil },
            set: { if !$0 { model.sourceErrorMessage = nil } }
        )) {
            Button(L10n.text("app_ok"), role: .cancel) { model.sourceErrorMessage = nil }
        } message: {
            Text(model.sourceErrorMessage ?? "")
        }
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L10n.text("app_add_folder_caption")
        panel.begin { response in
            if response == .OK, let url = panel.url { acceptFolder(url) }
        }
        #else
        importing = true
        #endif
    }

    private func acceptFolder(_ url: URL) {
        if let reconnectingFolder { model.reconnectFolder(reconnectingFolder, to: url) }
        else { model.addFolder(url) }
        reconnectingFolder = nil
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
