import Foundation
import ImageIO
import Photos

public enum PhotoLibraryReadError: Error, Sendable {
    case authorizationRequired
}

public struct PhotoLibrarySource: AssetSource {
    public let id = "photos-library"

    public init() {}

    public static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public func snapshot() async throws -> AssetSnapshot {
        try checkAuthorization()
        let fetch = PHAsset.fetchAssets(with: .image, options: nil)
        var assets = [PhotoAsset]()
        assets.reserveCapacity(fetch.count)
        for index in 0..<fetch.count {
            try Task.checkCancellation()
            assets.append(describe(fetch.object(at: index)))
        }
        try checkAuthorization()
        return AssetSnapshot(assets: assets)
    }

    public func imageData(for asset: PhotoAsset) async throws -> Data {
        try await image(for: asset).data
    }

    public func image(for asset: PhotoAsset) async throws -> AssetImage {
        let current = try currentAsset(for: asset)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        let request = PhotoImageRequest()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.begin(continuation) else { return }
                let requestID = PHImageManager.default().requestImageDataAndOrientation(for: current, options: options) {
                    data, _, orientation, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        request.complete(.failure(CancellationError()))
                    } else if data == nil, info?[PHImageResultIsInCloudKey] as? Bool == true {
                        request.complete(.failure(AssetAccessError.cloudDownloadRequired))
                    } else if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        if let data, !data.isEmpty {
                            request.complete(.success(AssetImage(data: data, orientation: orientation)))
                        } else {
                            request.complete(.failure(info?[PHImageErrorKey] as? Error ?? AssetAccessError.inaccessible))
                        }
                    }
                }
                request.bind(requestID)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        _ = try currentAsset(for: asset)
        return result
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = LibraryObserver(continuation: continuation)
        continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        PHPhotoLibrary.shared().register(observer)
        return stream
    }

    func currentAsset(for asset: PhotoAsset) throws -> PHAsset {
        try checkAuthorization()
        guard asset.id.source == id,
              let current = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id.item], options: nil).firstObject,
              current.mediaType == .image else {
            throw AssetAccessError.inaccessible
        }
        guard describe(current).revision == asset.revision else { throw AssetAccessError.changedDuringScan }
        return current
    }

    private func checkAuthorization() throws {
        switch Self.authorizationStatus() {
        case .authorized, .limited:
            return
        default:
            throw PhotoLibraryReadError.authorizationRequired
        }
    }

    private func describe(_ asset: PHAsset) -> PhotoAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let kinds = Set(resources.map(\.type))
        let properties = PhotoProperties(
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive) || kinds.contains(.pairedVideo),
            hasEdits: kinds.contains(.adjustmentData) || kinds.contains(.fullSizePhoto),
            hasAlternatePhoto: kinds.contains(.alternatePhoto)
        )
        let resourceSignature = resources.map { "\($0.type.rawValue):\($0.uniformTypeIdentifier):\($0.originalFilename)" }
            .sorted().joined(separator: "|")
        let version = asset.modificationDate?.timeIntervalSinceReferenceDate
            ?? asset.creationDate?.timeIntervalSinceReferenceDate ?? 0
        return PhotoAsset(
            id: AssetID(source: id, item: asset.localIdentifier),
            name: resources.first { $0.type == .photo }?.originalFilename ?? asset.localIdentifier,
            revision: "\(version):\(asset.pixelWidth):\(asset.pixelHeight):\(asset.mediaSubtypes.rawValue):\(resourceSignature)",
            photoProperties: properties
        )
    }

    private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
        let continuation: AsyncStream<Void>.Continuation

        init(continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            continuation.yield(())
        }
    }
}

private final class PhotoImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AssetImage, any Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    func begin(_ continuation: CheckedContinuation<AssetImage, any Error>) -> Bool {
        let active = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            return true
        }
        if !active { continuation.resume(throwing: CancellationError()) }
        return active
    }

    func bind(_ id: PHImageRequestID) {
        let shouldCancel = lock.withLock {
            if cancelled { return true }
            if continuation != nil { requestID = id }
            return false
        }
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    func complete(_ result: Result<AssetImage, any Error>) {
        let next = lock.withLock {
            defer {
                continuation = nil
                requestID = nil
            }
            return continuation
        }
        next?.resume(with: result)
    }

    func cancel() {
        let (next, id) = lock.withLock {
            cancelled = true
            defer {
                continuation = nil
                requestID = nil
            }
            return (continuation, requestID)
        }
        next?.resume(throwing: CancellationError())
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}
