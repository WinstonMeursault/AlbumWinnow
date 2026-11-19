import CoreGraphics
import XCTest
@testable import AlbumWinnowAcceptance

final class PreviewLayoutTests: XCTestCase {
    func testReviewUsesImageAreaAndCleanupKeepsCompactRows() {
        let landscape: [CGFloat] = [16 / 9, 16 / 9]
        let portrait: [CGFloat] = [0.2, 0.2]
        let reviewLandscape = ReviewPreviewLayout.frames(width: 390, height: 700, aspects: landscape) { _, _ in 40 }
        XCTAssertEqual(reviewLandscape[0].minX, reviewLandscape[1].minX)
        XCTAssertLessThan(reviewLandscape[0].minY, reviewLandscape[1].minY)
        let reviewPortrait = ReviewPreviewLayout.frames(width: 390, height: 700, aspects: portrait) { _, _ in 40 }
        XCTAssertEqual(reviewPortrait[0].minY, reviewPortrait[1].minY)
        XCTAssertLessThan(reviewPortrait[0].minX, reviewPortrait[1].minX)
        let cleanupPortrait = CleanupPreviewLayout.frames(width: 390, heightBudget: 360, aspects: portrait) { _, _ in 80 }
        XCTAssertEqual(cleanupPortrait[0].minY, cleanupPortrait[1].minY)
        let panorama = CleanupPreviewLayout.frames(width: 390, heightBudget: 360, aspects: [4.2, 4.2]) { _, _ in 80 }
        XCTAssertEqual(panorama[0].minX, panorama[1].minX)
        XCTAssertLessThan(panorama[0].minY, panorama[1].minY)
    }

    func testNarrowWindowsMixedAspectsAndLargeCaptionsStayReadable() {
        for width: CGFloat in [1, 120, 279, 280, 390, 768, 1200] {
            for height: CGFloat in [100, 360, 700] {
                for fontHeight: CGFloat in [24, 80, 180] {
                    // Model text wrapping at narrow widths and large Dynamic Type sizes.
                    let caption: (Int, CGFloat) -> CGFloat = { index, width in
                        fontHeight * ceil(CGFloat(100 + index * 20) / max(1, width))
                    }
                    for aspects: [CGFloat] in [[], [1], [0.1, 8], [1, 1], [0.2, 0.2], [4.2, 4.2]] {
                        let review = ReviewPreviewLayout.frames(width: width, height: height, aspects: aspects,
                                                                captionHeight: caption)
                        assertValid(review, width: width, caption: caption)
                        XCTAssertEqual(review.count, aspects.count)
                        let cleanup = CleanupPreviewLayout.frames(width: width, heightBudget: height, aspects: aspects,
                                                                  captionHeight: caption)
                        assertValid(cleanup, width: width, caption: caption)
                        XCTAssertEqual(cleanup.count, aspects.count)
                    }
                }
            }
        }
    }

    func testCleanupOddRowsAndLoadingAspects() {
        let aspects: [CGFloat] = [1, 0.2, 5, 1, 0.5, .nan, 0]
        let frames = CleanupPreviewLayout.frames(width: 768, heightBudget: 400, aspects: aspects) { _, _ in 96 }
        XCTAssertEqual(frames.count, aspects.count)
        assertValid(frames, width: 768) { _, _ in 96 }
        let review = ReviewPreviewLayout.frames(width: 320, height: 500, aspects: [.nan, 0]) { _, _ in 80 }
        assertValid(review, width: 320) { _, _ in 80 }
    }

    func testLargeTextColumnMinimumUsesTheFullWidth() {
        XCTAssertEqual(CleanupPreviewLayout.columns(width: 390, minimumColumnWidth: 500), 1)
        let cleanup = CleanupPreviewLayout.frames(width: 390, heightBudget: 360, aspects: [1, 1],
                                                  minimumColumnWidth: 500) { _, _ in 180 }
        XCTAssertEqual(cleanup[0].width, 390)
        XCTAssertEqual(cleanup[1].width, 390)
        let review = ReviewPreviewLayout.frames(width: 390, height: 700, aspects: [0.2, 0.2],
                                                minimumColumnWidth: 400) { _, _ in 180 }
        XCTAssertEqual(review[0].width, 390)
        XCTAssertEqual(review[1].width, 390)
    }

    private func assertValid(_ frames: [CGRect], width: CGFloat,
                             caption: (Int, CGFloat) -> CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite,
                          file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, caption(index, frame.width), file: file, line: line)
            for other in frames.dropFirst(index + 1) {
                XCTAssertFalse(frame.insetBy(dx: 0.01, dy: 0.01).intersects(other.insetBy(dx: 0.01, dy: 0.01)),
                               file: file, line: line)
            }
        }
    }
}
