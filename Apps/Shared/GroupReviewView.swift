import AlbumWinnowCore
import CoreImage
import ImageIO
import SwiftUI

struct GroupReviewView: View {
    let group: DuplicateGroup
    let model: ReviewModel
    let showHistory: () -> Void

    @State private var keepID: AssetID?
    @State private var compareID: AssetID?
    @State private var selected = Set<AssetID>()
    @State private var confirming = false

    private var assets: [PhotoAsset] { [group.preferred] + group.duplicates.map(\.asset) }
    private var keep: PhotoAsset { assets.first(where: { $0.id == keepID }) ?? group.preferred }
    private var comparison: PhotoAsset? {
        let alternatives = assets.filter { $0.id != keep.id }
        return alternatives.first(where: { $0.id == compareID }) ?? alternatives.first
    }
    private var pairs: [CleanupPair] {
        assets.filter { selected.contains($0.id) && canMark($0) }.map { CleanupPair(keep: keep, remove: $0) }
    }

    var body: some View {
        let rows = assets
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { previews }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) { previews }
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { asset in
                        row(asset)
                        if asset.id != rows.last?.id { Divider() }
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Review Group")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(pairs.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Review Cleanup…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canClean || pairs.isEmpty)
                    .accessibilityIdentifier("review-cleanup")
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $confirming) { confirmation }
    }

    @ViewBuilder private var previews: some View {
        PreviewCard(asset: keep, label: "Keep", model: model)
        if let comparison { PreviewCard(asset: comparison, label: "Compare", model: model) }
    }

    private func row(_ asset: PhotoAsset) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name).fontWeight(.medium).lineLimit(1)
                Text(description(for: asset)).font(.caption).foregroundStyle(.secondary)
                if asset.photoProperties?.hasAssociatedResources == true {
                    Label("Associated resources protected", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if asset.id == keep.id {
                Label("Keep", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Menu {
                    Button("Compare") { compareID = asset.id }
                    Button("Keep This Copy") {
                        keepID = asset.id
                        compareID = nil
                        selected.removeAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Review options for \(asset.name)")

                Toggle("Move \(asset.name)", isOn: Binding(
                    get: { selected.contains(asset.id) },
                    set: { if $0 { selected.insert(asset.id) } else { selected.remove(asset.id) } }
                ))
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .disabled(!canMark(asset) || !model.canClean)
                .accessibilityIdentifier("mark-\(asset.name)")
            }
        }
    }

    private func description(for asset: PhotoAsset) -> String {
        let source = model.sourceLabel(asset.id.source)
        if asset.id == group.preferred.id { return "\(source) · Recommended" }
        guard let match = group.duplicates.first(where: { $0.id == asset.id })?.match else { return source }
        return "\(source) · \(match == .exactDuplicate ? "Exact duplicate" : "Same image")"
    }

    private func canMark(_ asset: PhotoAsset) -> Bool {
        asset.id != keep.id && asset.photoProperties?.hasAssociatedResources != true
    }

    private var confirmation: some View {
        NavigationStack {
            List {
                Section("Keep") {
                    LabeledContent(keep.name, value: model.sourceLabel(keep.id.source))
                }
                Section("Move") {
                    ForEach(pairs) { pair in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pair.remove.name)
                            let destination = pair.remove.id.source == "photos-library" ? "Recently Deleted" : "Trash"
                            Text("\(model.sourceLabel(pair.remove.id.source)) → \(destination)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Confirm Cleanup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirming = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Selected", role: .destructive) {
                        let reviewed = pairs
                        confirming = false
                        Task {
                            await model.applyCleanup(reviewed)
                            showHistory()
                        }
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
}

private struct PreviewCard: View {
    let asset: PhotoAsset
    let label: String
    let model: ReviewModel

    @State private var preview: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel(asset.name)
                } else if failed {
                    Label("Preview unavailable", systemImage: "photo.badge.exclamationmark").font(.caption)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 210, idealWidth: 255, maxWidth: .infinity, minHeight: 180, idealHeight: 225, maxHeight: 260)
            Text(asset.name).font(.caption).lineLimit(1)
        }
        .task(id: asset) {
            preview = nil
            failed = false
            do {
                let image = try await model.image(for: asset)
                let next = await Self.thumbnail(image)
                try Task.checkCancellation()
                preview = next
                failed = next == nil
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }

    private nonisolated static func thumbnail(_ input: AssetImage) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(input.data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let embedded = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let override = input.orientation.flatMap { $0.rawValue == embedded ? nil : $0 }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: override == nil,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let override, override != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(override)
        return CIContext().createCGImage(oriented, from: oriented.extent)
    }
}
