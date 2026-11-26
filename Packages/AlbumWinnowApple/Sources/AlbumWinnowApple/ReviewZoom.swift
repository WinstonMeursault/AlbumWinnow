import CoreGraphics
import Foundation

public struct ReviewZoom: Equatable, Sendable {
    public var scale: CGFloat
    public var center: CGPoint

    public init(scale: CGFloat = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.scale = scale
        self.center = center
    }

    public static func fittedSize(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width.isFinite, image.height.isFinite, viewport.width.isFinite, viewport.height.isFinite,
              image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * fit, height: image.height * fit)
    }

    public func clamped(image: CGSize, viewport: CGSize, maximumScale: CGFloat = 4) -> ReviewZoom {
        let fit = Self.fittedSize(image: image, viewport: viewport)
        guard fit.width > 0, fit.height > 0 else { return ReviewZoom() }
        let maximum = maximumScale.isFinite ? max(1, maximumScale) : 1
        let scale = scale.isFinite ? min(maximum, max(1, scale)) : 1
        let x = min(0.5, viewport.width / (fit.width * scale) / 2)
        let y = min(0.5, viewport.height / (fit.height * scale) / 2)
        return ReviewZoom(scale: scale, center: CGPoint(
            x: min(1 - x, max(x, center.x.isFinite ? center.x : 0.5)),
            y: min(1 - y, max(y, center.y.isFinite ? center.y : 0.5))))
    }

    public func offset(image: CGSize, viewport: CGSize) -> CGSize {
        let fit = Self.fittedSize(image: image, viewport: viewport)
        return CGSize(width: (0.5 - center.x) * fit.width * scale,
                      height: (0.5 - center.y) * fit.height * scale)
    }

    public func panned(by translation: CGSize, image: CGSize, viewport: CGSize) -> ReviewZoom {
        let base = clamped(image: image, viewport: viewport)
        let fit = Self.fittedSize(image: image, viewport: viewport)
        guard fit.width > 0, fit.height > 0, translation.width.isFinite, translation.height.isFinite else { return base }
        return ReviewZoom(scale: base.scale, center: CGPoint(
            x: base.center.x - translation.width / (fit.width * base.scale),
            y: base.center.y - translation.height / (fit.height * base.scale)))
            .clamped(image: image, viewport: viewport)
    }

    public func magnified(by factor: CGFloat, at anchor: CGPoint, image: CGSize, viewport: CGSize,
                          maximumScale: CGFloat = 4) -> ReviewZoom {
        let base = clamped(image: image, viewport: viewport, maximumScale: maximumScale)
        let fit = Self.fittedSize(image: image, viewport: viewport)
        guard fit.width > 0, fit.height > 0, factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite else { return base }
        let scale = min(max(1, maximumScale), max(1, base.scale * factor))
        let offset = base.offset(image: image, viewport: viewport)
        let displayed = CGSize(width: fit.width * base.scale, height: fit.height * base.scale)
        let startX = viewport.width / 2 + offset.width - displayed.width / 2
        let startY = viewport.height / 2 + offset.height - displayed.height / 2
        let x = min(startX + displayed.width, max(startX, anchor.x)) - viewport.width / 2
        let y = min(startY + displayed.height, max(startY, anchor.y)) - viewport.height / 2
        return ReviewZoom(scale: scale, center: CGPoint(
            x: base.center.x + x / (fit.width * base.scale) - x / (fit.width * scale),
            y: base.center.y + y / (fit.height * base.scale) - y / (fit.height * scale)))
            .clamped(image: image, viewport: viewport, maximumScale: maximumScale)
    }
}
