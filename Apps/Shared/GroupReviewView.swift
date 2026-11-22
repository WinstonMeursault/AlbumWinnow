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
    @Binding var zoomed: Bool
    let advance: () -> Void

    @ScaledMetric(relativeTo: .caption) private var minimumPreviewWidth: CGFloat = 120
    @Environment(\.scenePhase) private var scenePhase
    @State private var sharedZoom = ReviewZoom()
    @State private var independentZoom: [AssetID: ReviewZoom] = [:]
    @State private var synchronizedZoom = true
    @State private var lastZoomedID: AssetID?
    @State private var showingInformation = false
    @State private var keepDraft = KeepDraft.unchanged
    @State private var deleteAllDraft: Bool?
    @State private var deleteAllUnavailable: String?
    @State private var checkedRemovability = false
    @State private var confirmationTask: Task<Void, Never>?
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
                    ReviewPreviewLayout(height: viewport.size.height - 32, aspects: copies.map(aspect),
                                        minimumColumnWidth: minimumPreviewWidth) {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(model.status(for: group).title).font(.caption)
                if selection.keepID != nil || selection.deleteAll {
                    Text("\(assets.count - selection.selected.count) kept · \(selection.selected.count) pending cleanup")
                        .font(.caption)
                }
                if group.comparisonSides != nil {
                    Text("Cross-side evidence only; unmatched members remain kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review Evidence", systemImage: "info.circle") { showingInformation = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier(isActive ? "review-evidence" : "")
                    .disabled(!isActive)
                Menu("Group Actions", systemImage: "ellipsis.circle") {
                    Button("Zoom In", systemImage: "plus.magnifyingglass", action: zoomIn)
                        .keyboardShortcut("+", modifiers: .command)
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise", action: resetZoom)
                        .keyboardShortcut("0", modifiers: .command)
                    Toggle("Sync Zoom", isOn: Binding(get: { synchronizedZoom }, set: { setSynchronizedZoom($0) }))
                    Divider()
                    Button("Keep Entire Group") { model.setStatus(.kept, for: group); advance() }
                    Button("Undo Group Decision") { model.setStatus(.pending, for: group); resetDraft() }
                }
                .labelStyle(.iconOnly)
                .disabled(!isActive || !model.canClean)
            }
            .padding(.horizontal).padding(.vertical, 6).background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .sheet(isPresented: $showingInformation) { GroupInformationView(model: model, group: group) }
        .task(id: isActive && model.canClean) {
            checkedRemovability = false
            guard isActive, model.canClean else { return }
            let reason = await model.deleteAllUnavailableReason(for: assets)
            guard !Task.isCancelled else { return }
            deleteAllUnavailable = reason
            checkedRemovability = true
        }
        .onChange(of: Set(assets.filter { model.isProtected($0) }.map(\.id))) {
            checkedRemovability = false
            deleteAllDraft = false
            confirmationTask?.cancel()
            confirmationTask = nil
            Task {
                deleteAllUnavailable = await model.deleteAllUnavailableReason(for: assets)
                checkedRemovability = true
            }
        }
        .onChange(of: group) { resetZoom() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { resetZoom() } }
        .onChange(of: model.canClean) { _, allowed in if !allowed { resetZoom() } }
        .onDisappear { confirmationTask?.cancel(); resetZoom() }
        .onChange(of: isActive) { _, active in
            if !active {
                confirmationTask?.cancel()
                resetDraft()
                resetZoom()
                synchronizedZoom = true
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if checkedRemovability, let deleteAllUnavailable {
                Text("Delete All unavailable: \(deleteAllUnavailable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if group.match == .similarPhoto || group.match == .sceneSimilar {
                Text("Similar photos · Check differences before confirming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if group.match == .visualDuplicate {
                Text("Possible matches · Compare details before confirming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if hand == ReviewHand.left.rawValue { confirmButton } else { deleteAllButton }
                Button {
                    model.setStatus(.deferred, for: group)
                    resetDraft()
                    advance()
                } label: {
                    actionTitle("Skip")
                }
                .foregroundStyle(.primary)
                .disabled(!isActive || confirmationTask != nil)
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
            confirmationTask = Task {
                defer { confirmationTask = nil }
                guard await model.confirmSelection(in: group, keepID: keepID, deleteAll: deletingAll),
                      !Task.isCancelled, isActive else { return }
                resetDraft()
                advance()
            }
        } label: {
            actionTitle("Confirm")
        }
        .buttonStyle(.borderedProminent)
        .tint(deletingAll ? .red : .accentColor)
        .disabled(!isActive || confirmationTask != nil || !model.canClean ||
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
        .disabled(!isActive || confirmationTask != nil || !checkedRemovability || !model.canClean || deleteAllUnavailable != nil)
        .accessibilityIdentifier(isActive ? "review-delete-all" : "")
        .accessibilityValue(deletingAll ? Text("On") : Text("Off"))
        .accessibilityHint(Text("Previews removing every photo in this group"))
    }

    private func actionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .lineLimit(2)
            .minimumScaleFactor(0.65)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func resetDraft() {
        keepDraft = .unchanged
        deleteAllDraft = nil
    }

    private func zoomBinding(for asset: PhotoAsset) -> Binding<ReviewZoom> {
        Binding(get: { synchronizedZoom ? sharedZoom : independentZoom[asset.id] ?? ReviewZoom() }, set: {
            if synchronizedZoom { sharedZoom = $0 } else { independentZoom[asset.id] = $0 }
            lastZoomedID = asset.id
            if isActive { updateZoomed() }
        })
    }

    private func updateZoomed() {
        zoomed = synchronizedZoom ? sharedZoom.scale > 1.001 : independentZoom.values.contains { $0.scale > 1.001 }
    }

    private func setSynchronizedZoom(_ enabled: Bool) {
        if enabled {
            sharedZoom = lastZoomedID.flatMap { independentZoom[$0] } ?? sharedZoom
            independentZoom.removeAll()
        } else {
            independentZoom = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, sharedZoom) })
        }
        synchronizedZoom = enabled
        if isActive { updateZoomed() }
    }

    private func zoomIn() {
        guard isActive, model.canClean else { return }
        let asset = assets.first { $0.id == lastZoomedID } ?? group.preferred
        let binding = zoomBinding(for: asset)
        var next = binding.wrappedValue
        next.scale = min(4, max(1, next.scale) * 2)
        binding.wrappedValue = next
    }

    private func resetZoom() {
        sharedZoom = ReviewZoom()
        independentZoom.removeAll()
        if isActive { zoomed = false }
    }

    private func aspect(_ asset: PhotoAsset) -> CGFloat {
        if let aspect = previews[asset.id]?.aspectRatio { return aspect }
        return group.preferredDimensions.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1
    }

    private func card(_ asset: PhotoAsset, number: Int) -> some View {
        let recommended = !deletingAll && asset.id == group.recommendation.id && group.hasQualityRecommendation != false
        let selected = !deletingAll && keepID == asset.id
        let title = showFilenames ? Text(asset.name) : Text("Photo \(number)")
        let accessibleTitle = recommended ? Text("\(title), recommended to keep") : title
        let active = isActive && confirmationTask == nil && model.canClean && !showingInformation
        let select = {
            guard active else { return }
            keepDraft = .changed(selected ? nil : asset.id)
            deleteAllDraft = false
        }
        return PreviewCard(asset: asset, recommended: recommended, selected: selected, deletingAll: deletingAll,
                           showFilename: showFilenames, preview: previews[asset.id],
                           model: model, zoom: zoomBinding(for: asset), active: active, select: select)
        .overlay(alignment: .topLeading) {
            if model.isLocked(asset) || model.isReadOnly(asset) {
                Label(model.isLocked(asset) ? "Locked" : "Read-only Source", systemImage: model.isLocked(asset) ? "lock.fill" : "hand.raised.fill")
                    .font(.caption).padding(8).background(.regularMaterial, in: .capsule).padding(8)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if asset.id.source == "photos-library" {
                Button("Download and Rescan This Photo", systemImage: "icloud.and.arrow.down") {
                    model.downloadAndRescan(asset)
                }
                .disabled(!model.canScan)
            }
            Button(model.isLocked(asset) ? "Unlock Photo" : "Lock Photo", systemImage: model.isLocked(asset) ? "lock.open" : "lock") {
                model.setLocked(asset, locked: !model.isLocked(asset))
            }
            .disabled(!model.canEditSources)
        }
        .allowsHitTesting(active)
        .disabled(!active)
        .focusable(active)
        .onKeyPress(.space) { guard active else { return .ignored }; select(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("Zoom or Reset")) {
            guard active else { return }
            let binding = zoomBinding(for: asset)
            binding.wrappedValue = binding.wrappedValue.scale > 1 ? ReviewZoom() : ReviewZoom(scale: 2)
        }
        .accessibilityLabel(Text("\(accessibleTitle), \(previews[asset.id]?.details ?? String(localized: "Photo details unavailable"))"))
        .accessibilityValue(model.isLocked(asset) ? Text("Locked, must be kept") : model.isReadOnly(asset) ? Text("Read-only, must be kept") : deletingAll ? Text("Marked for removal") : selected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(isActive ? "review-photo-\(asset.name)" : "")
        .task(id: asset) {
            guard previews[asset.id]?.asset != asset else { return }
            let preview = (try? await model.preview(for: asset)) ??
                LoadedPreview(asset: asset, image: nil, format: nil, byteCount: nil, dimensions: nil)
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

struct ReviewPreviewLayout: Layout {
    let height: CGFloat
    let aspects: [CGFloat]
    var minimumColumnWidth: CGFloat = 120

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
        Self.frames(width: width, height: height, aspects: Array(aspects.prefix(subviews.count)),
                    minimumColumnWidth: minimumColumnWidth) { index, width in
            subviews[index].sizeThatFits(.init(width: width, height: 0)).height
        }
    }

    static func frames(width: CGFloat, height: CGFloat, aspects: [CGFloat],
                       minimumColumnWidth: CGFloat = 120, captionHeight: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        let width = max(1, width)
        let spacing: CGFloat = 12
        let aspects = aspects.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let captions = aspects.indices.map { captionHeight($0, width) }
        let idealHeights = aspects.map { width / $0 }
        let gap = aspects.count == 2 ? spacing : 0
        let availableHeight = max(100, height - captions.reduce(0, +) - gap)
        let scale = min(1, availableHeight / max(1, idealHeights.reduce(0, +)))
        let stackedImages = idealHeights.map { min($0, max(128, $0 * scale)) }
        let first = CGRect(x: 0, y: 0, width: width, height: captions[0] + stackedImages[0])

        guard aspects.count == 2 else { return [first] }
        let second = CGRect(x: 0, y: first.maxY + gap, width: width, height: captions[1] + stackedImages[1])
        guard width >= spacing + 2 * minimumColumnWidth else { return [first, second] }

        // Compare the actual fitted image area after reserving room for each card's text.
        let rowWidth = width - spacing
        let minimumColumnWidth = min(minimumColumnWidth, rowWidth / 2)
        let proportionalWidth = rowWidth * aspects[0] / (aspects[0] + aspects[1])
        let firstWidth = min(rowWidth - minimumColumnWidth, max(minimumColumnWidth, proportionalWidth))
        let columnWidths = [firstWidth, rowWidth - firstWidth]
        let rowCaptions = columnWidths.indices.map { captionHeight($0, columnWidths[$0]) }
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
    let preview: LoadedPreview?
    let model: ReviewModel
    let zoom: Binding<ReviewZoom>
    let active: Bool
    let select: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ReviewZoomPhoto(asset: asset, model: model, preview: preview, active: active, zoom: zoom, select: select)
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
                            .allowsHitTesting(false)
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
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .contentShape(shape)
            VStack(alignment: .leading, spacing: 6) {
                PhotoMetadataView(preview: preview)
                if showFilename { Text(asset.name).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
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

struct LoadedPreview: Sendable {
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

    nonisolated static func load(asset: PhotoAsset, file: URL) async throws -> LoadedPreview {
        try Task.checkCancellation()
        return try autoreleasepool {
            // Mapping avoids a separate full-file heap buffer when the provider supports safe mapping.
            let data = try NSData(contentsOf: file, options: .mappedIfSafe)
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            return load(asset: asset, source: source, byteCount: data.length, orientation: nil)
        }
    }

    nonisolated static func load(asset: PhotoAsset, input: AssetImage) async -> LoadedPreview {
        let source = CGImageSourceCreateWithData(input.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        return load(asset: asset, source: source, byteCount: input.data.count, orientation: input.orientation)
    }

    private nonisolated static func load(asset: PhotoAsset, source: CGImageSource?, byteCount: Int?,
                                         orientation: CGImagePropertyOrientation?) -> LoadedPreview {
        guard let source else {
            return LoadedPreview(asset: asset, image: nil, format: nil, byteCount: byteCount, dimensions: nil)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let embedded = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let effectiveOrientation = orientation?.rawValue ?? embedded
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        let dimensions: String?
        if let width, let height {
            dimensions = effectiveOrientation >= 5 ? "\(height) × \(width)" : "\(width) × \(height)"
        } else {
            dimensions = nil
        }
        let format = CGImageSourceGetType(source).flatMap {
            UTType($0 as String)?.preferredFilenameExtension?.uppercased()
        }
        let override = orientation.flatMap { $0.rawValue == embedded ? nil : $0 }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: override == nil,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        if let pixels = image, let override, override != .up {
            let oriented = CIImage(cgImage: pixels).oriented(override)
            image = CIContext(options: [.cacheIntermediates: false]).createCGImage(oriented, from: oriented.extent)
        }
        return LoadedPreview(asset: asset, image: image, format: format, byteCount: byteCount, dimensions: dimensions)
    }
}
