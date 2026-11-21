import AlbumWinnowCore
import SwiftUI

struct ScanPolicySettings: View {
    let model: ReviewModel
    @State private var showingScope = false
    @State private var first = "photos-library"
    @State private var second = ""

    private var sources: [(id: String, name: String)] {
        (model.photosEnabled && model.allowsPhotos ? [("photos-library", "Photos")] : []) +
            model.folders.map { ($0.id, $0.name) }
    }

    var body: some View {
        Section("Comparison Scope") {
            Button("Photo Albums and Dates…") { showingScope = true }
                .accessibilityIdentifier("photo-scope")
                .disabled(!model.photosEnabled || !model.allowsPhotos)
            Text(model.photoScope.albums.map { "\($0.count) selected albums" } ?? String(localized: "All accessible photos"))
                .font(.caption).foregroundStyle(.secondary)
            if let dates = model.photoScope.dates {
                Text("\(dates.start.formatted(date: .abbreviated, time: .omitted)) – \(dates.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
            }
            Toggle("Compare Two Sides Only", isOn: Binding(get: { model.comparisonSides != nil }, set: {
                model.setComparisonSides($0 ? ComparisonSides(first: first, second: second) : nil)
            }))
            .accessibilityIdentifier("compare-two-sides")
            Picker("Side A", selection: $first) { sourceOptions }
            Picker("Side B", selection: $second) { sourceOptions }
            if let sides = model.comparisonSides {
                Text("Active: \(model.sourceLabel(sides.first)) ⇄ \(model.sourceLabel(sides.second))")
                    .font(.caption)
                Button("Apply Two Sides") { applySides() }
            }
            Text("Cross-side mode uses only matches between the two sources. It may keep extra photos when a selected copy has no verified match to another member.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canEditSources)
        .sheet(isPresented: $showingScope) { PhotoScopeEditor(model: model) }
        .onAppear {
            first = model.comparisonSides?.first ?? sources.first?.id ?? ""
            second = model.comparisonSides?.second ?? sources.dropFirst().first?.id ?? ""
        }
        Section("Source Policy") {
            Picker("Quality Tie Preference", selection: Binding(get: { model.preferredSource ?? "" }, set: {
                model.setPreferredSource($0.isEmpty ? nil : $0)
            })) {
                Text("Quality First").tag("")
                ForEach(sources, id: \.id) { Text($0.name).tag($0.id) }
                if let preferred = model.preferredSource, !sources.contains(where: { $0.id == preferred }) {
                    Text("Unavailable Source").tag(preferred)
                }
            }
            ForEach(sources, id: \.id) { source in readOnlyToggle(source.id, name: source.name) }
            ForEach(model.readOnlySources.filter { id in !sources.contains { $0.id == id } }.sorted(), id: \.self) { id in
                readOnlyToggle(id, name: String(localized: "Unavailable Source"))
            }
            Text("Read-only sources participate in comparison but cannot be cleaned. Locks and associated resources remain protected. Hardlinked files may be kept conservatively while a folder is read-only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.canEditSources)
    }

    private var sourceOptions: some View {
        Group {
            Text("Choose Source").tag("")
            ForEach(sources, id: \.id) { Text($0.name).tag($0.id) }
            if let sides = model.comparisonSides {
                ForEach([sides.first, sides.second].filter { id in !sources.contains { $0.id == id } }, id: \.self) { id in
                    Text("Unavailable Source").tag(id)
                }
            }
        }
    }

    private func applySides() {
        if model.comparisonSides != nil { model.setComparisonSides(ComparisonSides(first: first, second: second)) }
    }

    private func readOnlyToggle(_ id: String, name: String) -> some View {
        Toggle("Read-only · \(name)", isOn: Binding(get: { model.readOnlySources.contains(id) }, set: { enabled in
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
                Toggle("Selected Albums Only", isOn: $selectedAlbums)
                if selectedAlbums {
                    if model.authorization == .limited {
                        Text("Albums are unavailable with limited photo access. Review access or choose all accessible photos explicitly.")
                    }
                    ForEach(albums.keys.sorted { (albums[$0] ?? "") < (albums[$1] ?? "") }, id: \.self) { id in
                        Toggle(albums[id] ?? "", isOn: Binding(get: { selection[id] != nil }, set: {
                            if $0 { selection[id] = albums[id] } else { selection.removeValue(forKey: id) }
                        }))
                    }
                    ForEach(selection.keys.filter { albums[$0] != selection[$0] }.sorted(), id: \.self) { id in
                        Button("Remove Unavailable or Renamed Album: \(selection[id] ?? "")") { selection.removeValue(forKey: id) }
                    }
                    Text("Multiple albums form a union. Empty selection scans no photos; unavailable selections never fall back to the whole library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Capture Date Range", isOn: $dated)
                if dated {
                    DatePicker("First Day", selection: $first, displayedComponents: .date)
                    DatePicker("Last Day", selection: $last, displayedComponents: .date)
                    Toggle("Include Unknown Capture Dates", isOn: $includesUnknown)
                    Text("Uses the current calendar and time zone when applied. The exact start and end are saved for scan recovery.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Photo Scope")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() }.disabled(!model.canEditSources) }
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
            catch { self.error = "Albums could not be loaded. Existing selections are preserved." }
        }
    }

    private func apply() {
        do {
            var scope = PhotoScope()
            scope.albums = selectedAlbums ? selection : nil
            scope.dates = dated ? try CaptureRange(firstDay: first, lastDay: last, includesUnknown: includesUnknown) : nil
            model.setPhotoScope(scope)
            dismiss()
        } catch { self.error = "Choose a valid capture-date range." }
    }
}
