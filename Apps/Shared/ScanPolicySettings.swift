import AlbumWinnowApple
import SwiftUI

struct ScanPolicySettings: View {
    let model: ReviewModel
    @State private var showingScope = false
    @State private var first = ""
    @State private var second = ""

    private var sources: [(id: String, name: String)] {
        (model.photosEnabled && model.allowsPhotos ? model.photoSourceID.map { [($0, L10n.text("app_photos"))] } ?? [] : []) +
            model.folders.map { ($0.id, $0.name) }
    }

    var body: some View {
        Section(L10n.text("app_comparison_scope")) {
            Button(L10n.text("app_photo_albums_and_dates")) { showingScope = true }
                .accessibilityIdentifier("photo-scope")
                .disabled(!model.photosEnabled || !model.allowsPhotos)
            Text(model.photoScope.albums.map { L10n.text("app_arg1_selected_albums", Int64($0.count)) } ?? L10n.text("app_all_accessible_photos"))
                .font(.caption).foregroundStyle(.secondary)
            if let dates = model.photoScope.dates {
                Text("\(dates.start.formatted(date: .abbreviated, time: .omitted)) – \(dates.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
            }
            Toggle(L10n.text("app_compare_two_sides_only"), isOn: Binding(get: { model.comparisonSides != nil }, set: {
                model.setComparisonSides($0 ? ComparisonSides(first: first, second: second) : nil)
            }))
            .accessibilityIdentifier("compare-two-sides")
            Picker(L10n.text("app_side_a"), selection: $first) { sourceOptions }
            Picker(L10n.text("app_side_b"), selection: $second) { sourceOptions }
            if let sides = model.comparisonSides {
                Text(L10n.text("app_active_arg1_arg2", model.sourceLabel(sides.first), model.sourceLabel(sides.second)))
                    .font(.caption)
                Button(L10n.text("app_apply_two_sides")) { applySides() }
            }
            Text(L10n.text("app_cross_side_mode_uses_only_matches_between_the_two_sources_it_may_keep_extra_photos_when_a_selected_copy_has_no_verified_match_to_another_member"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canEditSources)
        .sheet(isPresented: $showingScope) { PhotoScopeEditor(model: model) }
        .onChange(of: sources.map(\.id), initial: true) {
            first = model.comparisonSides?.first ?? (sources.contains { $0.id == first } ? first : sources.first?.id ?? "")
            second = model.comparisonSides?.second ?? (sources.contains { $0.id == second } ? second : sources.dropFirst().first?.id ?? "")
        }
        Section(L10n.text("app_source_policy")) {
            Picker(L10n.text("app_quality_tie_preference"), selection: Binding(get: { model.preferredSource ?? "" }, set: {
                model.setPreferredSource($0.isEmpty ? nil : $0)
            })) {
                Text(L10n.text("app_quality_first")).tag("")
                ForEach(sources, id: \.id) { Text($0.name).tag($0.id) }
                if let preferred = model.preferredSource, !sources.contains(where: { $0.id == preferred }) {
                    Text(model.sourceLabel(preferred)).tag(preferred)
                }
            }
            ForEach(sources, id: \.id) { source in readOnlyToggle(source.id, name: source.name) }
            ForEach(model.readOnlySources.filter { id in !sources.contains { $0.id == id } }.sorted(), id: \.self) { id in
                readOnlyToggle(id, name: model.sourceLabel(id))
            }
            Text(L10n.text("app_read_only_sources_participate_in_comparison_but_cannot_be_cleaned_locks_and_associated_resources_remain_protected_hardlinked_files_may_be_kept_conservatively_while_a_folder_is_read_only"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canEditSources)
    }

    private var sourceOptions: some View {
        Group {
            Text(L10n.text("app_choose_source")).tag("")
            ForEach(sources, id: \.id) { Text($0.name).tag($0.id) }
            if let sides = model.comparisonSides {
                ForEach([sides.first, sides.second].filter { id in !sources.contains { $0.id == id } }, id: \.self) { id in
                    Text(model.sourceLabel(id)).tag(id)
                }
            }
        }
    }

    private func applySides() {
        if model.comparisonSides != nil { model.setComparisonSides(ComparisonSides(first: first, second: second)) }
    }

    private func readOnlyToggle(_ id: String, name: String) -> some View {
        Toggle(L10n.text("app_read_only_arg1", name), isOn: Binding(get: { model.readOnlySources.contains(id) }, set: { enabled in
            Task { await model.setReadOnly(id, enabled: enabled) }
        }))
    }
}

private struct PhotoScopeEditor: View {
    let model: ReviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAlbums = false
    @State private var selection: [String: String] = [:]
    @State private var albums: [String: String] = [:]
    @State private var dated = false
    @State private var first = Date()
    @State private var last = Date()
    @State private var includesUnknown = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Toggle(L10n.text("app_selected_albums_only"), isOn: $selectedAlbums)
                if selectedAlbums {
                    if model.authorization == .limited {
                        Text(L10n.text("app_albums_are_unavailable_with_limited_photo_access_review_access_or_choose_all_accessible_photos_explicitly"))
                    }
                    ForEach(albums.keys.sorted { (albums[$0] ?? "") < (albums[$1] ?? "") }, id: \.self) { id in
                        Toggle(albums[id] ?? "", isOn: Binding(get: { selection[id] != nil }, set: {
                            if $0 { selection[id] = albums[id] } else { selection.removeValue(forKey: id) }
                        }))
                    }
                    ForEach(selection.keys.filter { albums[$0] != selection[$0] }.sorted(), id: \.self) { id in
                        Button(L10n.text("app_remove_unavailable_or_renamed_album_arg1", selection[id] ?? "")) { selection.removeValue(forKey: id) }
                    }
                    Text(L10n.text("app_multiple_albums_form_a_union_empty_selection_scans_no_photos_unavailable_selections_never_fall_back_to_the_whole_library"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.text("app_capture_date_range"), isOn: $dated)
                if dated {
                    DatePicker(L10n.text("app_first_day"), selection: $first, displayedComponents: .date)
                    DatePicker(L10n.text("app_last_day"), selection: $last, displayedComponents: .date)
                    Toggle(L10n.text("app_include_unknown_capture_dates"), isOn: $includesUnknown)
                    Text(L10n.text("app_uses_the_current_calendar_and_time_zone_when_applied_the_exact_start_and_end_are_saved_for_scan_recovery"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.text("app_photo_scope"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("app_cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("app_apply")) { apply() }.disabled(!model.canEditSources) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .onAppear {
            let scope = model.photoScope
            selectedAlbums = scope.albums != nil
            selection = scope.albums ?? [:]
            dated = scope.dates != nil
            if let range = scope.dates { first = range.start; last = range.end.addingTimeInterval(-1); includesUnknown = range.includesUnknown }
            do { albums = try PhotoLibrarySource.albums() }
            catch { self.error = L10n.text("app_albums_could_not_be_loaded_existing_selections_are_preserved") }
        }
    }

    private func apply() {
        do {
            var scope = PhotoScope()
            scope.albums = selectedAlbums ? selection : nil
            scope.dates = dated ? try CaptureRange(firstDay: first, lastDay: last, includesUnknown: includesUnknown) : nil
            model.setPhotoScope(scope)
            dismiss()
        } catch { self.error = L10n.text("app_choose_a_valid_capture_date_range") }
    }
}
