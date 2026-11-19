import AlbumWinnowCore
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ReviewHand: String {
    static let defaultsKey = "AlbumWinnow.reviewHand"
    case left, right
}

struct GroupReviewView: View {
    private enum KeepDraft {
        case unchanged
        case changed(AssetID?)
    }

    let group: DuplicateGroup
    let model: ReviewModel
    let isActive: Bool
    let advance: () -> Void

    @State private var keepDraft = KeepDraft.unchanged
    @State private var deleteAllDraft: Bool?
    @State private var deleteAllUnavailable: String?
    @State private var checkedRemovability = false
    @State private var previews: [AssetID: LoadedPreview] = [:]
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false
    @AppStorage(ReviewHand.defaultsKey) private var hand = ReviewHand.right.rawValue

    private var assets: [PhotoAsset] { [group.preferred] + group.duplicates.map(\.asset) }
    private var selection: ReviewModel.GroupSelection { model.selection(for: group.id) }
    private var keepID: AssetID? {
        if case let .changed(id) = keepDraft { return id }
        return selection.keepID
    }
    private var deletingAll: Bool { deleteAllDraft ?? selection.deleteAll }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                let copies = assets
                if copies.count == 2 {
                    ReviewPreviewLayout(height: viewport.size.height - 32, aspects: copies.map(aspect)) {
                        ForEach(Array(copies.enumerated()), id: \.element.id) { index, asset in
                            card(asset, number: index + 1)
                        }
                    }
                    .padding(16)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(copies.enumerated()), id: \.element.id) { index, asset in
                            card(asset, number: index + 1)
                                .frame(height: min(viewport.size.height * 0.7,
                                                   max(160, (viewport.size.width - 32) / aspect(asset))))
                        }
                    }
                    .padding(16)
                }
            }
            .accessibilityIdentifier(isActive ? "group-review" : "")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .task(id: isActive && model.canClean) {
            checkedRemovability = false
            guard isActive, model.canClean else { return }
            deleteAllUnavailable = model.deleteAllUnavailableReason(for: assets)
            checkedRemovability = true
        }
        .onChange(of: isActive) { _, active in
            if !active { resetDraft() }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if checkedRemovability, let deleteAllUnavailable {
                Text("Delete All unavailable: \(deleteAllUnavailable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if group.duplicates.contains(where: { $0.match == .visualDuplicate }) {
                Text("Possible matches · Compare details before confirming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if hand == ReviewHand.left.rawValue { confirmButton } else { deleteAllButton }
                Button {
                    resetDraft()
                    advance()
                } label: {
                    actionTitle("Skip")
                }
                .foregroundStyle(.primary)
                .disabled(!isActive)
                .accessibilityIdentifier(isActive ? "review-skip" : "")
                if hand == ReviewHand.left.rawValue { deleteAllButton } else { confirmButton }
            }
            .environment(\.layoutDirection, .leftToRight)
            .controlSize(.large)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var confirmButton: some View {
        Button {
            guard model.confirmSelection(in: group, keepID: keepID, deleteAll: deletingAll) else { return }
            resetDraft()
            advance()
        } label: {
            actionTitle("Confirm")
        }
        .buttonStyle(.borderedProminent)
        .tint(deletingAll ? .red : .accentColor)
        .disabled(!isActive || !model.canClean ||
                  (deletingAll ? !checkedRemovability || deleteAllUnavailable != nil : keepID == nil))
        .accessibilityIdentifier(isActive ? "review-confirm" : "")
        .accessibilityHint(deletingAll ? Text("Adds the entire group to pending cleanup") :
                                        Text("Keeps the selected photo and queues removable copies"))
    }

    private var deleteAllButton: some View {
        Button {
            deleteAllDraft = !deletingAll
        } label: {
            actionTitle("Delete All")
        }
        .foregroundStyle(.red)
        .tint(deletingAll ? .red : nil)
        .disabled(!isActive || !checkedRemovability || !model.canClean || deleteAllUnavailable != nil)
        .accessibilityIdentifier(isActive ? "review-delete-all" : "")
        .accessibilityValue(deletingAll ? Text("On") : Text("Off"))
        .accessibilityHint(Text("Previews removing every photo in this group"))
    }

    private func actionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func resetDraft() {
        keepDraft = .unchanged
        deleteAllDraft = nil
    }

    private func aspect(_ asset: PhotoAsset) -> CGFloat {
        if let aspect = previews[asset.id]?.aspectRatio { return aspect }
        return group.preferredDimensions.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1
    }

    private func card(_ asset: PhotoAsset, number: Int) -> some View {
        let recommended = !deletingAll && asset.id == group.preferred.id
        let selected = !deletingAll && keepID == asset.id
        let title = showFilenames ? Text(asset.name) : Text("Photo \(number)")
        let accessibleTitle = recommended ? Text("\(title), recommended to keep") : title
        return Button {
            keepDraft = .changed(selected ? nil : asset.id)
            deleteAllDraft = false
        } label: {
            PreviewCard(asset: asset, recommended: recommended, selected: selected, deletingAll: deletingAll,
                        showFilename: showFilenames, isActive: isActive, preview: previews[asset.id])
        }
        .buttonStyle(.plain)
        .disabled(!isActive || !model.canClean)
        .accessibilityLabel(Text("\(accessibleTitle), \(previews[asset.id]?.details ?? String(localized: "Photo details unavailable"))"))
        .accessibilityValue(deletingAll ? Text("Marked for removal") : selected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(isActive ? "review-photo-\(asset.name)" : "")
        .task(id: asset) {
            guard previews[asset.id]?.asset != asset else { return }
            let preview: LoadedPreview
            if let input = try? await model.image(for: asset) {
                preview = await LoadedPreview.load(asset: asset, input: input)
            } else {
                preview = LoadedPreview(asset: asset, image: nil, format: nil, byteCount: nil, dimensions: nil)
            }
            guard !Task.isCancelled else { return }
            previews[asset.id] = preview
        }
        .onDisappear {
            if group.duplicates.count > 1 {
                previews.removeValue(forKey: asset.id)
            }
        }
    }
}

private struct ReviewPreviewLayout: Layout {
    let height: CGFloat
    let aspects: [CGFloat]
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let captions = subviews.map { $0.sizeThatFits(.init(width: width, height: 0)).height }
        let idealHeights = aspects.map { width / $0 }
        let gap = aspects.count == 2 ? spacing : 0
        let availableHeight = max(100, height - captions.reduce(0, +) - gap)
        let scale = min(1, availableHeight / max(1, idealHeights.reduce(0, +)))
        let stackedImages = idealHeights.map { $0 * scale }
        let first = CGRect(x: 0, y: 0, width: width, height: captions[0] + stackedImages[0])

        guard aspects.count == 2 else { return [first] }
        let second = CGRect(x: 0, y: first.maxY + gap, width: width, height: captions[1] + stackedImages[1])
        guard width > spacing else { return [first, second] }

        // Compare the actual fitted image area after reserving room for each card's text.
        let rowWidth = width - spacing
        let minimumColumnWidth = min(120, rowWidth / 2)
        let proportionalWidth = rowWidth * aspects[0] / (aspects[0] + aspects[1])
        let firstWidth = min(rowWidth - minimumColumnWidth, max(minimumColumnWidth, proportionalWidth))
        let columnWidths = [firstWidth, rowWidth - firstWidth]
        let rowCaptions = zip(subviews, columnWidths).map { view, width in
            view.sizeThatFits(.init(width: width, height: 0)).height
        }
        let rowHeight = max(100, height - (rowCaptions.max() ?? 0))
        let rowImages = zip(columnWidths, aspects).map { min(rowHeight, $0 / $1) }
        let rowArea = zip(aspects, rowImages).reduce(CGFloat.zero) { $0 + $1.0 * $1.1 * $1.1 }
        let stackedArea = zip(aspects, stackedImages).reduce(CGFloat.zero) { $0 + $1.0 * $1.1 * $1.1 }
        guard rowArea > stackedArea || (rowArea == stackedArea && aspects.allSatisfy { $0 < 1 }) else {
            return [first, second]
        }
        return [
            CGRect(x: 0, y: 0, width: firstWidth, height: rowCaptions[0] + rowImages[0]),
            CGRect(x: firstWidth + spacing, y: 0, width: columnWidths[1], height: rowCaptions[1] + rowImages[1]),
        ]
    }
}

private struct PreviewCard: View {
    let asset: PhotoAsset
    let recommended: Bool
    let selected: Bool
    let deletingAll: Bool
    let showFilename: Bool
    let isActive: Bool
    let preview: LoadedPreview?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Group {
                    if let image = preview?.image {
                        Image(image, scale: 1, label: Text("Preview"))
                            .resizable()
                            .scaledToFit()
                            .accessibilityIdentifier(isActive ? "preview-\(asset.name)" : "")
                    } else {
                        shape.fill(.quaternary)
                            .overlay {
                                if preview != nil {
                                    Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                                        .font(.caption)
                                } else {
                                    ProgressView()
                                }
                            }
                    }
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(deletingAll ? .red : selected ? Color.accentColor : .clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Text("Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor, in: .capsule)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if recommended {
                        Text("Recommended")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: .capsule)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .contentShape(shape)
            PhotoMetadataView(preview: preview)
            if showFilename { Text(asset.name).font(.caption).lineLimit(1) }
        }
    }
}

struct PhotoMetadataView: View {
    let preview: LoadedPreview?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                metadataSummary
                Text(" · ")
                metadataDimensions
            }
            VStack(alignment: .leading, spacing: 2) {
                metadataSummary
                metadataDimensions
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var metadataSummary: some View {
        HStack(spacing: 0) {
            Text(preview?.format ?? String(localized: "Unknown format"))
            Text(" · ")
            Text(preview?.byteCount.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? String(localized: "Size unknown"))
        }
    }

    private var metadataDimensions: some View {
        Text(preview?.dimensions ?? String(localized: "Resolution unknown"))
    }
}

struct LoadedPreview {
    let asset: PhotoAsset
    let image: CGImage?
    let format: String?
    let byteCount: Int?
    let dimensions: String?

    var details: String {
        let size = byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [format ?? String(localized: "Unknown format"),
                size ?? String(localized: "Size unknown"),
                dimensions ?? String(localized: "Resolution unknown")].joined(separator: " · ")
    }

    var aspectRatio: CGFloat? {
        image.map { CGFloat($0.width) / CGFloat($0.height) }
    }

    nonisolated static func load(asset: PhotoAsset, input: AssetImage) async -> LoadedPreview {
        guard let source = CGImageSourceCreateWithData(input.data as CFData, nil) else {
            return LoadedPreview(asset: asset, image: nil, format: nil,
                                 byteCount: input.data.count, dimensions: nil)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let embedded = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let orientation = input.orientation?.rawValue ?? embedded
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        let dimensions: String?
        if let width, let height {
            dimensions = orientation >= 5 ? "\(height) × \(width)" : "\(width) × \(height)"
        } else {
            dimensions = nil
        }
        let format = CGImageSourceGetType(source).flatMap {
            UTType($0 as String)?.preferredFilenameExtension?.uppercased()
        }
        let image = await thumbnail(input)
        return LoadedPreview(asset: asset, image: image, format: format,
                             byteCount: input.data.count, dimensions: dimensions)
    }

    nonisolated static func thumbnail(_ input: AssetImage) async -> CGImage? {
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
