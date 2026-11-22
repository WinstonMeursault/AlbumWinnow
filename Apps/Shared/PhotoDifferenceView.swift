import AlbumWinnowCore
import CoreGraphics
import SwiftUI

struct PhotoDifferenceView: View {
    let model: ReviewModel
    let group: DuplicateGroup
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false
    @State private var referenceID: AssetID?
    @State private var comparisonID: AssetID?
    @State private var requestID: UUID?
    @State private var result: PhotoDifference?
    @State private var errorMessage: String?
    @State private var showHighlights = false
    @State private var opacity = 0.25

    private var loading: Bool { requestID != nil && result == nil && errorMessage == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose two photos to compare. Your keep choice stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Reference").font(.caption)
                        .accessibilityIdentifier("difference-reference-label")
                    Menu {
                        Picker("Reference", selection: $referenceID) {
                            Text("Choose Photo").tag(nil as AssetID?)
                            ForEach(group.assets) { asset in Text(title(asset)).tag(Optional(asset.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(menuTitle(referenceID)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .accessibilityLabel("Reference")
                    .accessibilityValue(menuTitle(referenceID))
                    .accessibilityIdentifier("difference-reference")
                }
                VStack(alignment: .leading) {
                    Text("Comparison").font(.caption)
                        .accessibilityIdentifier("difference-comparison-label")
                    Menu {
                        Picker("Comparison", selection: $comparisonID) {
                            Text("Choose Photo").tag(nil as AssetID?)
                            ForEach(group.assets.filter { $0.id != referenceID }) { asset in Text(title(asset)).tag(Optional(asset.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(menuTitle(comparisonID)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .accessibilityLabel("Comparison")
                    .accessibilityValue(menuTitle(comparisonID))
                    .accessibilityIdentifier("difference-comparison")
                }
                Button(result == nil ? "Show Differences" : "Refresh Differences") {
                    result = nil
                    errorMessage = nil
                    showHighlights = true
                    requestID = UUID()
                }
                .buttonStyle(.borderedProminent)
                .disabled(referenceID == nil || comparisonID == nil || referenceID == comparisonID ||
                          loading || model.running || model.cleaning || model.resultsStale)
                .accessibilityIdentifier("difference-show")
                if loading { ProgressView("Comparing previews…") }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("difference-unavailable")
                }
                if let result {
                    if let reason = result.unavailableReason {
                        Label("Cannot reliably show differences", systemImage: "rectangle.slash")
                            .accessibilityIdentifier("difference-unavailable")
                        Text(explanation(reason)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Display", selection: $showHighlights) {
                            Text("Original").tag(false)
                            Text("Differences").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("difference-display")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], spacing: 16) {
                        photo(result.reference, label: String(localized: "Reference"), regions: [])
                        photo(result.comparison, label: String(localized: "Comparison"),
                              regions: showHighlights ? result.regions : [])
                    }
                    if result.unavailableReason == nil {
                        if result.regions.isEmpty {
                            Text("No significant local differences at this preview resolution.")
                                .accessibilityIdentifier("difference-region-count")
                        } else {
                            Text(result.regions.count == 1 ? "1 Local Change Region" : "\(result.regions.count) Local Change Regions")
                                .accessibilityIdentifier("difference-region-count")
                            if showHighlights {
                                Text("Highlight Opacity").font(.caption)
                                Slider(value: $opacity, in: 0...0.75) { Text("Highlight Opacity") }
                                    .accessibilityIdentifier("difference-opacity")
                            }
                        }
                    }
                    Text("These are approximate image-change hints from previews up to 512 pixels, with global color and compression noise suppressed. Small details can be missed. Use synchronized zoom in the group to inspect originals. Hints do not change matching, recommendations or cleanup choices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Compare Photos")
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: referenceID) { _, value in
            if comparisonID == value { comparisonID = nil }
            reset()
        }
        .onChange(of: comparisonID) { _, _ in reset() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
        .onChange(of: model.resultsStale) { _, stale in if stale { reset() } }
        .onChange(of: model.running) { _, running in if running { reset() } }
        .onDisappear { reset() }
        .task(id: requestID) {
            guard let request = requestID,
                  let reference = group.assets.first(where: { $0.id == referenceID }),
                  let comparison = group.assets.first(where: { $0.id == comparisonID }) else { return }
            do {
                let value = try await model.difference(reference: reference, comparison: comparison)
                guard !Task.isCancelled, requestID == request else { return }
                result = value
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                errorMessage = message(error)
            }
        }
    }

    private func title(_ asset: PhotoAsset) -> String {
        if showFilenames { return asset.name }
        return String(localized: "Photo \((group.assets.firstIndex(of: asset) ?? 0) + 1)")
    }

    private func menuTitle(_ id: AssetID?) -> String {
        group.assets.first { $0.id == id }.map { title($0) } ?? String(localized: "Choose Photo")
    }

    private func reset() {
        requestID = nil
        result = nil
        errorMessage = nil
        showHighlights = false
    }

    private func photo(_ image: CGImage, label: String, regions: [CGRect]) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.headline)
            GeometryReader { geometry in
                let fit = ReviewZoom.fittedSize(image: CGSize(width: image.width, height: image.height), viewport: geometry.size)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .overlay {
                        ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                            Rectangle()
                                .fill(.orange.opacity(opacity))
                                .overlay { Rectangle().stroke(.orange, lineWidth: 2) }
                                .frame(width: rect.width * fit.width, height: rect.height * fit.height)
                                .position(x: rect.midX * fit.width, y: rect.midY * fit.height)
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 280)
            .background(.quaternary, in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(label) preview"))
        }
    }

    private func explanation(_ reason: DifferenceUnavailableReason) -> String {
        switch reason {
        case .geometry: return String(localized: "The image proportions differ. Crops or changed viewpoints require manual comparison.")
        case .insufficientDetail: return String(localized: "There is not enough stable detail to verify alignment. Inspect the photos with synchronized zoom in the group.")
        case .alignment: return String(localized: "The framing or image details do not agree closely enough for a reliable overlay. Inspect the originals manually.")
        }
    }

    private func message(_ error: Error) -> String {
        switch error {
        case AssetAccessError.changedDuringScan, ScopeError.unavailableAlbum:
            return String(localized: "The photos or their scope changed. Return to the overview and scan again.")
        case AssetAccessError.cloudDownloadRequired, AssetAccessError.cloudDownloadFailed:
            return String(localized: "A local preview is unavailable. Download and rescan from the group menu before comparing again.")
        case is CancellationError: return String(localized: "Difference preview cancelled. Try again when the photos are available.")
        default: return String(localized: "Cannot read or verify these previews. Return to the group and check access before trying again.")
        }
    }
}
