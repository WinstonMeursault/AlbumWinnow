import Foundation
import Photos
import Testing
@testable import AlbumWinnowCore

@Test func photoRequestNetworkOptInAndRetry() async throws {
    let selected = AssetID(source: "photos-library", item: "cloud-a")
    let other = AssetID(source: "photos-library", item: "cloud-b")
    #expect(!PhotoLibrarySource().permitsDownload(for: selected))
    let source = PhotoLibrarySource(downloads: [selected])
    #expect(source.permitsDownload(for: selected))
    #expect(!source.permitsDownload(for: other))

    await #expect(throws: AssetAccessError.cloudDownloadRequired) {
        try await deliver(data: nil, allowsDownload: false, inCloud: true)
    }
    await #expect(throws: AssetAccessError.cloudDownloadFailed) {
        try await deliver(data: nil, allowsDownload: true, inCloud: true)
    }
    let retried = try await deliver(data: Data([1, 2, 3]), allowsDownload: true, inCloud: true)
    #expect(retried.data == Data([1, 2, 3]))
    #expect(retried.orientation == .right)
}

@Test func cancelledPhotoRequestIgnoresLateCompletion() async {
    await #expect(throws: CancellationError.self) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            let request = PhotoImageRequest()
            _ = request.begin(continuation)
            request.cancel()
            request.complete(data: Data([1]), orientation: .up, info: nil, allowsDownload: true)
        }
    }
}

private func deliver(data: Data?, allowsDownload: Bool, inCloud: Bool) async throws -> AssetImage {
    try await withCheckedThrowingContinuation { continuation in
        let request = PhotoImageRequest()
        _ = request.begin(continuation)
        request.complete(data: data, orientation: .right, info: [PHImageResultIsInCloudKey: inCloud], allowsDownload: allowsDownload)
    }
}
