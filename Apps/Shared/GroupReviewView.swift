import AlbumWinnowCore
import CoreImage
import ImageIO
import SwiftUI

struct GroupReviewView: View {
    let group: DuplicateGroup
    let model: ReviewModel
    let reviewCleanup: () -> Void

    @State private var compareID: AssetID?
    @State private var presentedComparison: PhotoAsset?

    private var assets: [PhotoAsset] { [group.preferred] + group.duplicates.map(\.asset) }
    private var selection: ReviewModel.GroupSelection { model.selection(for: group.id) }
    private var keep: PhotoAsset { assets.first(where: { $0.id == selection.keepID }) ?? group.preferred }
    private var comparison: PhotoAsset? {
        let alternatives = assets.filter { $0.id != keep.id }
        return alternatives.first(where: { $0.id == compareID }) ?? alternatives.first
    }
    var body: some View {
        let rows = assets
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let comparison {
                    Button("Compare…", systemImage: "rectangle.split.2x1") { presentedComparison = comparison }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("open-comparison")
                }
                previews(comparing: comparison)
                if group.duplicates.contains(where: { $0.match == .visualDuplicate }) {
                    Label("Compare details before moving a possible match.", systemImage: "eye")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    selectionSummary.fixedSize()
                    Spacer(minLength: 0)
                    reviewButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    selectionSummary
                    reviewButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
        .sheet(item: $presentedComparison) { asset in
            NavigationStack {
                ScrollView {
                    previews(comparing: asset)
                        .padding(18)
                }
                .navigationTitle("Compare Photos")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { presentedComparison = nil }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 640, minHeight: 380)
            #endif
        }
    }

    private var selectionSummary: some View {
        Text(model.selectedCount == 0 ? "Select copies to move" : "\(model.selectedCount) selected across all groups")
            .foregroundStyle(.secondary)
    }

    private var reviewButton: some View {
        Button("Review Cleanup…", action: reviewCleanup)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canClean || model.selectedCount == 0)
            .accessibilityIdentifier("review-cleanup")
    }

    private func previews(comparing asset: PhotoAsset?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { cards(comparing: asset) }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 12) { cards(comparing: asset) }
        }
    }

    @ViewBuilder private func cards(comparing asset: PhotoAsset?) -> some View {
        PreviewCard(asset: keep, label: "Copy to Keep", model: model)
        if let asset { PreviewCard(asset: asset, label: "Comparison Copy", model: model) }
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
                    Button("Compare") {
                        compareID = asset.id
                        presentedComparison = asset
                    }
                    Button("Keep This Copy") {
                        model.setSelection(.init(keepID: asset.id), for: group.id)
                        compareID = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Review options for \(asset.name)")

                Toggle("Move \(asset.name)", isOn: Binding(
                    get: { selection.selected.contains(asset.id) },
                    set: {
                        var next = selection
                        if $0 { next.selected.insert(asset.id) } else { next.selected.remove(asset.id) }
                        model.setSelection(next, for: group.id)
                    }
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
        if asset.id == group.preferred.id { return "\(source) · Recommended to keep" }
        guard let match = group.duplicates.first(where: { $0.id == asset.id })?.match else { return source }
        return "\(source) · \(match == .exactDuplicate ? "Exact duplicate" : "Possible same image")"
    }

    private func canMark(_ asset: PhotoAsset) -> Bool {
        asset.id != keep.id && asset.photoProperties?.hasAssociatedResources != true
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
