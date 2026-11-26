import AlbumWinnowApple
import CoreGraphics
import SwiftUI

struct ReviewZoomPhoto: View {
    let asset: PhotoAsset
    let model: ReviewModel
    let preview: LoadedPreview?
    let active: Bool
    @Binding var zoom: ReviewZoom
    let select: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var detail: CGImage?
    @State private var detailFinished = false
    @State private var pinchStart: ReviewZoom?
    @State private var panStart: ReviewZoom?

    private var requested: Bool { zoom.scale > 1.001 }
    private var needsDetail: Bool { active && visible && requested && scenePhase == .active }

    var body: some View {
        GeometryReader { geometry in
            let image = detail ?? preview?.image
            let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let fit = ReviewZoom.fittedSize(image: size, viewport: geometry.size)
            let pixelLimit = fit.width > 0 && fit.height > 0 ?
                max(1, min(4, min(size.width / (fit.width * displayScale), size.height / (fit.height * displayScale)))) : 1
            let rendered = zoom.clamped(image: size, viewport: geometry.size, maximumScale: pixelLimit)
            let offset = rendered.offset(image: size, viewport: geometry.size)
            ZStack {
                Color.clear
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .scaleEffect(rendered.scale)
                        .position(x: geometry.size.width / 2 + offset.width,
                                  y: geometry.size.height / 2 + offset.height)
                } else if preview != nil {
                    Label(L10n.text("app_preview_unavailable"), systemImage: "photo.badge.exclamationmark").font(.caption)
                } else { ProgressView() }
            }
            .contentShape(.rect)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if requested {
                    Text(detailStatus(limit: pixelLimit))
                        .font(.caption2).padding(5).background(.regularMaterial, in: .capsule).padding(6)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard active else { return }
                    zoom = requested ? ReviewZoom() : rendered.magnified(by: 2, at: value.location,
                        image: size, viewport: geometry.size)
                }.exclusively(before: SpatialTapGesture().onEnded { _ in if active { select() } })
            )
            .simultaneousGesture(
                MagnifyGesture().onChanged { value in
                    guard active else { return }
                    if pinchStart == nil { pinchStart = rendered }
                    zoom = (pinchStart ?? rendered).magnified(by: value.magnification, at: value.startLocation,
                        image: size, viewport: geometry.size)
                }.onEnded { _ in pinchStart = nil }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { value in
                    guard active, requested, rendered.scale > 1.001 else { return }
                    if panStart == nil { panStart = rendered }
                    zoom = (panStart ?? rendered).panned(by: value.translation, image: size, viewport: geometry.size)
                }.onEnded { _ in panStart = nil }, including: requested ? .all : .subviews
            )
        }
        .allowsHitTesting(active)
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        .task(id: needsDetail) {
            detail = nil
            detailFinished = false
            guard needsDetail else { return }
            do {
                let image = try await model.thumbnail(for: asset, pixelSize: 2560)
                guard !Task.isCancelled else { return }
                detail = image
                detailFinished = true
            } catch {
                guard !Task.isCancelled else { return }
                detailFinished = true
            }
        }
        .onDisappear { detail = nil; pinchStart = nil; panStart = nil }
    }

    private func detailStatus(limit: CGFloat) -> String {
        if !detailFinished { return L10n.text("app_loading_detail_preview") }
        if detail == nil { return L10n.text("app_detail_not_loaded") }
        if zoom.scale > limit + 0.01 { return L10n.text("app_detail_limited_to_arg1", Double(limit).formatted(.number.precision(.fractionLength(1)))) }
        return L10n.text("app_arg1_relative_position", Double(zoom.scale).formatted(.number.precision(.fractionLength(1))))
    }
}
