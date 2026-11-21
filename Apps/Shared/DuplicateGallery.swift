import AlbumWinnowCore
import SwiftUI

struct DuplicateMasonry {
    struct Tile: Identifiable {
        let id: Int
        let frame: CGRect
    }

    let tiles: [Tile]
    let height: CGFloat
    private let tallestTile: CGFloat

    init(groups: [DuplicateGroup] = [], width: CGFloat = 0, columns: Int = 1, captionHeight: CGFloat = 0) {
        let gap: CGFloat = 12
        let inset: CGFloat = 16
        let cardWidth = max(1, (width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns))
        var nextTop = Array(repeating: inset, count: columns)
        var placements: [Tile] = []
        placements.reserveCapacity(groups.count)
        var tallest: CGFloat = 0
        for (index, group) in groups.enumerated() {
            let column = nextTop.indices.min { nextTop[$0] < nextTop[$1] } ?? 0
            let aspect = group.preferredDimensions.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 0.86
            let imageHeight = min(400, cardWidth * min(1.45, max(0.62, aspect)))
            let tileHeight = imageHeight + captionHeight
            let frame = CGRect(x: inset + CGFloat(column) * (cardWidth + gap), y: nextTop[column],
                               width: cardWidth, height: tileHeight)
            nextTop[column] = frame.maxY + gap
            placements.append(Tile(id: index, frame: frame))
            tallest = max(tallest, tileHeight)
        }
        tiles = placements
        height = groups.isEmpty ? 0 : (nextTop.max() ?? inset) - gap + inset
        tallestTile = tallest
    }

    func visible(in range: Range<CGFloat>) -> ArraySlice<Tile> {
        let first = boundary(at: range.lowerBound - tallestTile)
        let end = boundary(at: range.upperBound)
        return tiles[first..<end]
    }

    func anchor(at offset: CGFloat) -> Tile? {
        visible(in: offset..<(offset + 1)).first { $0.frame.maxY >= offset }
            ?? tiles.dropFirst(boundary(at: offset)).first
    }

    private func boundary(at top: CGFloat) -> Int {
        var low = 0
        var high = tiles.count
        while low < high {
            let mid = low + (high - low) / 2
            if tiles[mid].frame.minY < top { low = mid + 1 }
            else { high = mid }
        }
        return low
    }
}

struct DuplicateGallery<Header: View>: View {
    let groups: [DuplicateGroup]
    let model: ReviewModel
    let selectedGroup: AssetID?
    let narrowed: Bool
    let isActive: Bool
    let bottomRequest: Int
    let header: () -> Header
    let open: (DuplicateGroup) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var captionHeight: CGFloat = 52
    @State private var masonry = DuplicateMasonry()
    @State private var viewport = CGRect.zero
    @State private var position = ScrollPosition(edge: .top)
    @State private var overviewAnchor: Anchor?
    @State private var pendingBottomScroll = false

    private struct Configuration: Equatable {
        let width: CGFloat
        let columns: Int
        let captionHeight: CGFloat
        let narrowed: Bool
        let bottomRequest: Int
    }

    private struct Anchor {
        let tile: Int
        let offset: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width.rounded(.down)
            let configuration = Configuration(width: width, columns: columnCount(at: width),
                                              captionHeight: captionHeight, narrowed: narrowed,
                                              bottomRequest: bottomRequest)
            let top = max(0, viewport.minY)
            let bottom = top + max(viewport.height, geometry.size.height)
            let loadedRange = max(0, top - 220)..<(bottom + 220)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    ForEach(masonry.visible(in: loadedRange)) { tile in
                        if groups.indices.contains(tile.id), tile.frame.maxY >= loadedRange.lowerBound {
                            let group = groups[tile.id]
                            GalleryCard(group: group, model: model, isOpen: group.id == selectedGroup,
                                        imageHeight: tile.frame.height - configuration.captionHeight,
                                        captionHeight: configuration.captionHeight,
                                        pixelSize: pixelSize(for: tile.frame, captionHeight: configuration.captionHeight),
                                        isActive: isActive) { open(group) }
                                .frame(width: tile.frame.width, height: tile.frame.height)
                                .position(x: tile.frame.midX, y: tile.frame.midY)
                                .accessibilitySortPriority(-Double(tile.id))
                        }
                    }
                }
                .frame(width: width, height: masonry.height, alignment: .topLeading)
            }
            .accessibilityIdentifier("duplicate-gallery")
            .scrollClipDisabled()
            .safeAreaInset(edge: .top, spacing: 0, content: header)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, rect in
                if isActive { viewport = rect }
            }
            .onChange(of: configuration, initial: true) { old, new in
                let anchor = masonry.anchor(at: top).map { Anchor(tile: $0.id, offset: top - $0.frame.minY) }
                if old.narrowed != new.narrowed, new.narrowed { overviewAnchor = anchor }
                rebuild(new)
                if old.bottomRequest != new.bottomRequest {
                    pendingBottomScroll = true
                } else {
                    restore(old.narrowed && !new.narrowed ? overviewAnchor ?? anchor : anchor)
                }
                if !new.narrowed { overviewAnchor = nil }
            }
            .onChange(of: groups) {
                overviewAnchor = nil
                pendingBottomScroll = false
                rebuild(configuration)
                restore(nil)
            }
            .task(id: isActive && pendingBottomScroll) {
                guard isActive && pendingBottomScroll else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                position.scrollTo(edge: .bottom)
                pendingBottomScroll = false
            }
        }
        .clipped()
    }

    private func columnCount(at width: CGFloat) -> Int {
        if dynamicTypeSize.isAccessibilitySize || width < 305 { return 1 }
        if width >= 1_000 { return 4 }
        if width >= 710 { return 3 }
        return 2
    }

    private func pixelSize(for frame: CGRect, captionHeight: CGFloat) -> Int {
        let longestEdge = max(frame.width, frame.height - captionHeight)
        return min(768, max(128, Int(ceil(longestEdge * displayScale / 128)) * 128))
    }

    private func rebuild(_ configuration: Configuration) {
        masonry = DuplicateMasonry(groups: groups, width: configuration.width,
                                    columns: configuration.columns, captionHeight: configuration.captionHeight)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, masonry.tiles.indices.contains(anchor.tile) else {
            position.scrollTo(edge: .top)
            return
        }
        let y = max(0, masonry.tiles[anchor.tile].frame.minY + anchor.offset)
        position.scrollTo(y: y)
    }
}

private struct GalleryCard: View {
    let group: DuplicateGroup
    let model: ReviewModel
    let isOpen: Bool
    let imageHeight: CGFloat
    let captionHeight: CGFloat
    let pixelSize: Int
    let isActive: Bool
    let open: () -> Void

    @State private var thumbnail: CGImage?
    @State private var loadedKey: GalleryThumbnailKey?
    @State private var failed = false

    private var hasVisualMatch: Bool { group.match != .exactDuplicate }

    private var matchDescription: Text {
        group.match == .similarPhoto ? Text("Similar photos") : Text("Possible same image")
    }

    var body: some View {
        let selection = model.selection(for: group.id)
        let asset = selection.keepID.flatMap { id in group.duplicates.first { $0.id == id }?.asset } ?? group.preferred
        let key = isActive ? GalleryThumbnailKey(asset: asset, pixelSize: pixelSize) : nil
        let count = group.duplicates.count + 1
        let selected = selection.selected.count

        Button(action: open) {
            VStack(spacing: 0) {
                Color.secondary.opacity(0.1)
                    .overlay {
                        if let thumbnail, key == loadedKey {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else if failed && key == loadedKey {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(height: imageHeight)
                    .clipped()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { counts(total: count, selected: selected) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) { counts(total: count, selected: selected) }
                    }
                    if hasVisualMatch {
                        matchDescription.foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: captionHeight)
            }
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected > 0 || isOpen ? Color.accentColor : .secondary.opacity(0.18),
                                  lineWidth: selected > 0 || isOpen ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(count) photos"))
        .accessibilityValue(accessibilityStatus(selected: selected))
        .accessibilityHint(Text("Opens the duplicate group for review"))
        .accessibilityIdentifier("duplicate-group-\(group.preferred.name)")
        .task(id: key) {
            thumbnail = nil
            failed = false
            loadedKey = key
            guard let key else { return }
            do {
                let image = try await model.thumbnail(for: asset, pixelSize: key.pixelSize)
                try Task.checkCancellation()
                thumbnail = image
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    @ViewBuilder private func counts(total: Int, selected: Int) -> some View {
        Text("\(total) photos").fontWeight(.semibold)
        if selected > 0 {
            Text("\(selected) selected")
                .foregroundStyle(.tint)
        }
    }

    private func accessibilityStatus(selected: Int) -> Text {
        if failed && selected > 0 {
            return hasVisualMatch ? Text("\(selected) selected, \(matchDescription), preview unavailable") : Text("\(selected) selected, preview unavailable")
        }
        if failed { return hasVisualMatch ? Text("\(matchDescription), preview unavailable") : Text("Preview unavailable") }
        if selected > 0 {
            return hasVisualMatch ? Text("\(selected) selected, \(matchDescription)") : Text("\(selected) selected")
        }
        return hasVisualMatch ? matchDescription : Text("")
    }
}
