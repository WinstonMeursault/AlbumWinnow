import AlbumWinnowCore
import CoreImage
import ImageIO
import SwiftUI

struct GroupReviewView: View {
    let group: DuplicateGroup
    let model: ReviewModel
    let isActive: Bool
    let reviewCleanup: () -> Void

    @State private var compareID: AssetID?
    @State private var keepPreview: LoadedPreview?
    @State private var comparisonPreview: LoadedPreview?
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false

    private var assets: [PhotoAsset] { [group.preferred] + group.duplicates.map(\.asset) }
    private var selection: ReviewModel.GroupSelection { model.selection(for: group.id) }
    private var keep: PhotoAsset { assets.first(where: { $0.id == selection.keepID }) ?? group.preferred }
    private var comparison: PhotoAsset? {
        let alternatives = assets.filter { $0.id != keep.id }
        return alternatives.first(where: { $0.id == compareID }) ?? alternatives.first
    }
    var body: some View {
        let rows = assets
        let kept = keep
        let compared = comparison
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previews(keep: kept, comparison: compared, height: viewport.size.height - 36)
                    if group.duplicates.contains(where: { $0.match == .visualDuplicate }) {
                        Label("Compare details before moving a possible match.", systemImage: "eye")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, asset in
                            row(asset, number: index + 1)
                            if asset.id != rows.last?.id { Divider() }
                        }
                    }
                }
                .padding(18)
            }
            .accessibilityIdentifier(isActive ? "group-review" : "")
            .accessibilityHidden(!isActive)

        }
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
    }

    private var selectionSummary: some View {
        Text(model.selectedCount == 0 ? "Select copies to move" : "\(model.selectedCount) selected across all groups")
            .foregroundStyle(.secondary)
    }

    private var reviewButton: some View {
        Button("Review Cleanup…", action: reviewCleanup)
            .buttonStyle(.borderedProminent)
            .disabled(!isActive || !model.canClean || model.selectedCount == 0)
            .accessibilityIdentifier(isActive ? "review-cleanup" : "")
    }

    private func previews(keep: PhotoAsset, comparison: PhotoAsset?, height: CGFloat) -> some View {
        let first = keepPreview?.asset == keep ? keepPreview : nil
        let second = comparisonPreview?.asset == comparison ? comparisonPreview : nil
        let fallbackAspect = group.preferredDimensions.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1
        let firstAspect = first?.aspectRatio ?? second?.aspectRatio ?? fallbackAspect
        let secondAspect = second?.aspectRatio ?? firstAspect
        return ReviewPreviewLayout(height: height, aspects: comparison == nil ? [firstAspect] : [firstAspect, secondAspect]) {
            PreviewCard(asset: keep, label: "Copy to Keep", showFilename: showFilenames, preview: first)
                .task(id: keep) { await loadPreview(for: keep, into: $keepPreview) }
            if let comparison {
                PreviewCard(asset: comparison, label: "Comparison Copy", showFilename: showFilenames, preview: second)
                    .task(id: comparison) { await loadPreview(for: comparison, into: $comparisonPreview) }
            }
        }
    }

    private func loadPreview(for asset: PhotoAsset, into state: Binding<LoadedPreview?>) async {
        state.wrappedValue = nil
        let image: CGImage?
        if let input = try? await model.image(for: asset) {
            image = await LoadedPreview.thumbnail(input)
        } else {
            image = nil
        }
        guard !Task.isCancelled else { return }
        state.wrappedValue = LoadedPreview(asset: asset, image: image)
    }

    private func row(_ asset: PhotoAsset, number: Int) -> some View {
        let title = showFilenames ? asset.name : "Copy \(number)"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium).lineLimit(1)
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
                    Button("Show in Preview") { compareID = asset.id }
                        .disabled(comparison?.id == asset.id)
                    Button("Keep This Copy") {
                        model.setSelection(.init(keepID: asset.id), for: group.id)
                        compareID = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Review options for \(title)")

                Toggle("Move \(title)", isOn: Binding(
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
    let label: String
    let showFilename: Bool
    let preview: LoadedPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image = preview?.image {
                    Image(image, scale: 1, label: Text(label))
                        .resizable()
                        .scaledToFit()
                        .accessibilityIdentifier("preview-\(asset.name)")
                } else if preview != nil {
                    Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            if showFilename { Text(asset.name).font(.caption).lineLimit(1) }
        }
    }
}

private struct LoadedPreview {
    let asset: PhotoAsset
    let image: CGImage?

    var aspectRatio: CGFloat? {
        image.map { CGFloat($0.width) / CGFloat($0.height) }
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
