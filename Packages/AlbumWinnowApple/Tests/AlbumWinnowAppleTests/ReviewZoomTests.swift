import CoreGraphics
import Testing
@testable import AlbumWinnowApple

@Test func zoomUsesImageContentAndClampsEachAspectIndependently() {
    let viewport = CGSize(width: 400, height: 300)
    let landscape = CGSize(width: 1600, height: 900)
    let portrait = CGSize(width: 900, height: 1600)
    let fit = ReviewZoom.fittedSize(image: landscape, viewport: viewport)
    #expect(fit == CGSize(width: 400, height: 225))
    let requested = ReviewZoom(scale: 2, center: CGPoint(x: 0, y: 0))
    let a = requested.clamped(image: landscape, viewport: viewport)
    let b = requested.clamped(image: portrait, viewport: viewport)
    #expect(a.center.x == 0.25)
    #expect(abs(a.center.y - 1.0 / 3) < 0.001)
    #expect(b.center.x == 0.5)
    #expect(b.center.y == 0.25)
}

@Test func zoomPansWithoutAddingBlackBarsAndKeepsLogicalCenterAcrossRotation() {
    let image = CGSize(width: 1600, height: 900)
    let viewport = CGSize(width: 400, height: 300)
    let zoom = ReviewZoom(scale: 2)
    let moved = zoom.panned(by: CGSize(width: -80, height: 0), image: image, viewport: viewport)
    #expect(abs(moved.center.x - 0.6) < 0.001)
    #expect(moved.center.y == 0.5)
    #expect(moved.clamped(image: image, viewport: CGSize(width: 300, height: 400)).center.x == moved.center.x)
    #expect(ReviewZoom().clamped(image: image, viewport: viewport).center == CGPoint(x: 0.5, y: 0.5))
}

@Test func zoomRejectsInvalidGeometryAndHonorsAvailableDetailLimit() {
    let image = CGSize(width: 1600, height: 900), viewport = CGSize(width: 400, height: 300)
    #expect(ReviewZoom(scale: .nan).clamped(image: image, viewport: viewport).scale == 1)
    #expect(ReviewZoom(scale: 4).clamped(image: image, viewport: viewport, maximumScale: 1.5).scale == 1.5)
    #expect(ReviewZoom(scale: 2).clamped(image: .zero, viewport: viewport) == ReviewZoom())
    let anchored = ReviewZoom().magnified(by: 2, at: CGPoint(x: 300, y: 150), image: image, viewport: viewport)
    #expect(abs(anchored.center.x - 0.625) < 0.001)
    #expect(anchored.center.y == 0.5)
}
