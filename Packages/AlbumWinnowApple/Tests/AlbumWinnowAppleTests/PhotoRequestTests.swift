import Foundation
import Photos
import Testing
@testable import AlbumWinnowApple

@Test func photoRequestNetworkOptInAndRetry() async throws {
    let selected = AssetID(source: "controlled.fixture.photos", item: "cloud-a")
    let other = AssetID(source: "controlled.fixture.photos", item: "cloud-b")
    #expect(!PhotoLibrarySource(id: selected.source).permitsDownload(for: selected))
    let source = PhotoLibrarySource(downloads: [selected], id: selected.source)
    #expect(source.permitsDownload(for: selected))
    #expect(!source.permitsDownload(for: other))

    await #expect(throws: AssetAccessError.cloudDownloadRequired) {
        try await deliver(data: nil, allowsDownload: false, inCloud: true)
    }
    await #expect(throws: PhotoLibraryDownloadError.self) {
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

@Test(arguments: [false, true]) func degradedCloudResultWaitsForFinalImage(hasPreview: Bool) async throws {
    let image = try await withCheckedThrowingContinuation { continuation in
        let request = PhotoImageRequest()
        _ = request.begin(continuation)
        request.complete(data: hasPreview ? Data([1]) : nil, orientation: .up,
                         info: [PHImageResultIsDegradedKey: true, PHImageResultIsInCloudKey: true], allowsDownload: true)
        request.complete(data: Data([4, 5, 6]), orientation: .right, info: nil, allowsDownload: true)
    }
    #expect(image.data == Data([4, 5, 6]))
    #expect(image.orientation == .right)
}

@Test func cloudFailureRetainsSystemDiagnostics() async {
    do {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            let request = PhotoImageRequest()
            _ = request.begin(continuation)
            request.complete(data: nil, orientation: .up, info: [PHImageErrorKey:
                NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "Offline"])
            ], allowsDownload: true)
        }
        Issue.record("Expected a download failure")
    } catch {
        #expect(error.localizedDescription.contains(NSURLErrorDomain))
        #expect(error.localizedDescription.contains("-1009"))
    }
}

@Test func progressFailureCancelsRequestBoundAfterCallback() async {
    let cancelled = RequestIDs()
    let request = PhotoImageRequest(cancelRequest: { cancelled.append($0) })
    do {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            _ = request.begin(continuation)
            request.complete(.failure(PhotoLibraryDownloadError(NSError(domain: "Cloud", code: 7))), cancellingRequest: true)
            request.bind(42)
            request.complete(data: Data([1]), orientation: .up, info: nil, allowsDownload: true)
        }
        Issue.record("Expected progress failure")
    } catch {
        #expect(error.localizedDescription.contains("Cloud"))
        #expect(cancelled.values == [42])
    }
}

@Test func progressFailureCancelsBoundRequest() async {
    let cancelled = RequestIDs()
    let request = PhotoImageRequest(cancelRequest: { cancelled.append($0) })
    await #expect(throws: PhotoLibraryDownloadError.self) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            _ = request.begin(continuation)
            request.bind(43)
            request.complete(.failure(PhotoLibraryDownloadError(NSError(domain: "Cloud", code: 8))), cancellingRequest: true)
            request.cancel()
        }
    }
    #expect(cancelled.values == [43])
}

private final class RequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PHImageRequestID] = []
    var values: [PHImageRequestID] { lock.withLock { stored } }
    func append(_ id: PHImageRequestID) { lock.withLock { stored.append(id) } }
}

private struct FailingDownloadSource: AssetSource {
    let id = "download-error-fixture"
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: [PhotoAsset(id: AssetID(source: id, item: "one"), name: "one", revision: "1")])
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        throw PhotoLibraryDownloadError(NSError(domain: NSURLErrorDomain, code: -1009,
                                               userInfo: [NSLocalizedDescriptionKey: "Offline"]))
    }
}

@Test func downloadDiagnosticsSurviveScanAndRetry() async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = try FixtureScanEngine(cacheURL: scratch.appending(path: "cache.sqlite"))
    for _ in 0..<2 {
        let scan = try await engine.fixtureScan([FailingDownloadSource()])
        #expect(scan.scanned == 0)
        #expect(scan.reused == 0)
        #expect(scan.issues.first?.reason == .cloudDownloadFailed)
        #expect(scan.issues.first?.detail?.contains("-1009") == true)
        let restored = try JSONDecoder().decode([AssetIssue].self, from: JSONEncoder().encode(scan.issues))
        #expect(restored == scan.issues)
    }
}

@Test func offlineDegradedCloudResultDoesNotWaitForUnavailableOriginal() async {
    await #expect(throws: AssetAccessError.cloudDownloadRequired) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            let request = PhotoImageRequest()
            _ = request.begin(continuation)
            request.complete(data: nil, orientation: .up,
                info: [PHImageResultIsDegradedKey: true, PHImageResultIsInCloudKey: true], allowsDownload: false)
        }
    }
}

private enum VerificationFailure: Sendable { case required, failed, system }

private actor VerificationDownloadSource: AssetSource {
    let failure: VerificationFailure
    init(failure: VerificationFailure) { self.failure = failure }
    nonisolated let id = "verification-download-fixture"
    private var reads: [AssetID: Int] = [:]
    func snapshot() async throws -> AssetSnapshot {
        AssetSnapshot(assets: ["landscape.jpg", "landscape-small.png"].map {
            PhotoAsset(id: AssetID(source: id, item: $0), name: $0, revision: "1")
        })
    }
    func imageData(for asset: PhotoAsset) async throws -> Data {
        reads[asset.id, default: 0] += 1
        if reads[asset.id, default: 0] > 1 {
            switch failure {
            case .required: throw AssetAccessError.cloudDownloadRequired
            case .failed: throw AssetAccessError.cloudDownloadFailed
            case .system: throw PhotoLibraryDownloadError(NSError(domain: "CloudVerification", code: 17))
            }
        }
        return try Data(contentsOf: TestFiles.fixtures.appending(path: asset.name))
    }
}

@Test(arguments: [VerificationFailure.required, .failed, .system])
private func verificationDownloadFailureIdentifiesThePhotoThatNeedsRetry(failure: VerificationFailure) async throws {
    let scratch = TestFiles.root.appending(path: "scratch/\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = VerificationDownloadSource(failure: failure)
    let result = try await FixtureScanEngine(cacheURL: scratch.appending(path: "scan.sqlite")).fixtureScan([source])
    #expect(result.groups.isEmpty)
    #expect(result.issues.count == 1)
    #expect(result.issues.first?.id.item == "landscape.jpg")
    #expect(result.issues.first?.reason == (failure == .required ? .cloudDownloadRequired : .cloudDownloadFailed))
    if failure == .system { #expect(result.issues.first?.detail?.contains("CloudVerification") == true) }
}

@Test func photosCancellationWithoutTaskCancellationRemainsRetryable() async {
    await #expect(throws: PhotoLibraryDownloadError.self) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            let request = PhotoImageRequest()
            _ = request.begin(continuation)
            request.complete(data: nil, orientation: .up, info: [PHImageCancelledKey: true], allowsDownload: true)
        }
    }
}

@Test func photosCancellationWithoutNetworkDoesNotCancelTheScanTask() async {
    await #expect(throws: AssetAccessError.inaccessible) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AssetImage, any Error>) in
            let request = PhotoImageRequest()
            _ = request.begin(continuation)
            request.complete(data: nil, orientation: .up, info: [PHImageCancelledKey: true], allowsDownload: false)
        }
    }
}
