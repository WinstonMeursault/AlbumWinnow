import AlbumWinnowCore
import XCTest
@testable import AlbumWinnowAcceptance

final class CloudDownloadProgressTests: XCTestCase {
    func testConcurrentTransfersAndOutcomes() {
        let first = AssetID(source: "photos-library", item: "first")
        let second = AssetID(source: "photos-library", item: "second")
        var progress = CloudDownloadProgress(total: 3)
        progress.update(.transferring(first, fraction: 0.6))
        progress.update(.transferring(second, fraction: 0.4))
        progress.update(.transferring(first, fraction: 0.1))
        XCTAssertEqual(progress.processed, 1, accuracy: 0.0001)
        XCTAssertEqual(progress.remaining, 3)
        progress.update(.finished(first, available: true))
        progress.update(.finished(second, available: false))
        progress.update(.finished(first, available: false))
        progress.update(.transferring(first, fraction: 0.9))
        XCTAssertEqual(progress.processed, 2)
        XCTAssertEqual(progress.available, 1)
        XCTAssertEqual(progress.failed, 1)
        progress.end(cancelled: false)
        XCTAssertEqual(progress.remaining, 1)
        XCTAssertTrue(progress.ended)
    }

    func testCancelledTransferAndRetry() {
        let asset = AssetID(source: "photos-library", item: "interrupted")
        var progress = CloudDownloadProgress(total: 1)
        progress.update(.transferring(asset, fraction: 0.6))
        progress.end(cancelled: true)
        progress.update(.finished(asset, available: true))
        XCTAssertTrue(progress.cancelled)
        XCTAssertEqual(progress.available, 0)
        XCTAssertEqual(progress.remaining, 1)

        var retry = CloudDownloadProgress(total: 1)
        retry.update(.finished(asset, available: true))
        retry.end(cancelled: false)
        XCTAssertEqual(retry.available, 1)
        XCTAssertEqual(retry.remaining, 0)
    }
}
