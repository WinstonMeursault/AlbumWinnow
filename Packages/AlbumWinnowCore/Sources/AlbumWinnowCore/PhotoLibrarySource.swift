import Foundation
import ImageIO
import Photos
#if os(macOS)
import AppKit
#else
import CoreImage
import UIKit
#endif

public enum PhotoLibraryReadError: Error, Sendable {
    case authorizationRequired
}

public struct PhotoLibrarySource: AssetSource {
    public enum DownloadUpdate: Sendable {
        case transferring(AssetID, fraction: Double)
        case finished(AssetID, available: Bool)
    }

    public let id = "photos-library"
    private let downloads: Set<AssetID>
    private let downloadUpdate: @Sendable (DownloadUpdate) -> Void

    public init(downloads: Set<AssetID> = [], downloadUpdate: @escaping @Sendable (DownloadUpdate) -> Void = { _ in }) {
        self.downloads = downloads
        self.downloadUpdate = downloadUpdate
    }

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
            assets.append(Self.describe(fetch.object(at: index)))
        }
        try checkAuthorization()
        return AssetSnapshot(assets: assets)
    }

    public func imageData(for asset: PhotoAsset) async throws -> Data {
        try await image(for: asset).data
    }

    public func image(for asset: PhotoAsset) async throws -> AssetImage {
        let allowDownload = permitsDownload(for: asset.id)
        var available = false
        defer {
            if allowDownload && !Task.isCancelled {
                downloadUpdate(.finished(asset.id, available: available))
            }
        }
        let current = try currentAsset(for: asset)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowDownload
        let request = PhotoImageRequest()
        if allowDownload {
            options.progressHandler = { fraction, error, _, _ in
                if let error {
                    request.complete(.failure(PhotoLibraryDownloadError(error as NSError)), cancellingRequest: true)
                } else {
                    downloadUpdate(.transferring(asset.id, fraction: fraction))
                }
            }
        }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.begin(continuation) else { return }
                let requestID = PHImageManager.default().requestImageDataAndOrientation(for: current, options: options) {
                    data, _, orientation, info in
                    request.complete(data: data, orientation: orientation, info: info, allowsDownload: allowDownload)
                }
                request.bind(requestID)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        _ = try currentAsset(for: asset)
        available = true
        return result
    }

    public func thumbnail(for asset: PhotoAsset, maxPixelSize: Int) async throws -> CGImage {
        try Task.checkCancellation()
        let current = try currentAsset(for: asset)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        let side = CGFloat(max(1, maxPixelSize))
        let request = PhotoRequest<CGImage>()
        let thumbnail = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.begin(continuation) else { return }
                let id = PHImageManager.default().requestImage(
                    for: current, targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFit, options: options
                ) { image, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        request.complete(.failure(CancellationError()))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        request.complete(.failure(error))
                    } else if image == nil, info?[PHImageResultIsInCloudKey] as? Bool == true {
                        request.complete(.failure(AssetAccessError.cloudDownloadRequired))
                    } else if info?[PHImageResultIsDegradedKey] as? Bool == true {
                        return
                    } else if let image, let thumbnail = Self.thumbnailCGImage(image) {
                        request.complete(.success(thumbnail))
                    } else {
                        request.complete(.failure(info?[PHImageErrorKey] as? Error ?? AssetAccessError.inaccessible))
                    }
                }
                request.bind(id)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        _ = try currentAsset(for: asset)
        return thumbnail
    }

    #if os(macOS)
    private static func thumbnailCGImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    #else
    private static let thumbnailContext = CIContext(options: [.cacheIntermediates: false])

    private static func thumbnailCGImage(_ image: UIImage) -> CGImage? {
        guard let pixels = image.cgImage else { return nil }
        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: return pixels
        case .upMirrored: orientation = .upMirrored
        case .down: orientation = .down
        case .downMirrored: orientation = .downMirrored
        case .left: orientation = .left
        case .leftMirrored: orientation = .leftMirrored
        case .right: orientation = .right
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: return pixels
        }
        let oriented = CIImage(cgImage: pixels).oriented(orientation)
        return thumbnailContext.createCGImage(oriented, from: oriented.extent)
    }
    #endif

    func permitsDownload(for id: AssetID) -> Bool { downloads.contains(id) }

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
        guard Self.describe(current).revision == asset.revision else { throw AssetAccessError.changedDuringScan }
        return current
    }

    func removableAsset(for asset: PhotoAsset) throws -> PHAsset {
        let current = try currentAsset(for: asset)
        guard Self.describe(current).photoProperties?.hasAssociatedResources != true else {
            throw CleanupError.protectedResources
        }
        guard current.canPerform(.delete) else { throw AssetAccessError.inaccessible }
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

    private static func describe(_ asset: PHAsset) -> PhotoAsset {
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
            id: AssetID(source: "photos-library", item: asset.localIdentifier),
            name: resources.first { $0.type == .photo }?.originalFilename ?? asset.localIdentifier,
            revision: "\(version):\(asset.pixelWidth):\(asset.pixelHeight):\(asset.mediaSubtypes.rawValue):\(resourceSignature)",
            photoProperties: properties
        )
    }

    private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var assets = PHAsset.fetchAssets(with: .image, options: nil)

        init(continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            let changed = lock.withLock {
                guard let details = changeInstance.changeDetails(for: assets) else { return false }
                assets = details.fetchResultAfterChanges
                guard details.hasIncrementalChanges else { return true }
                if !details.insertedObjects.isEmpty || !details.removedObjects.isEmpty || details.hasMoves { return true }
                guard let indexes = details.changedIndexes else { return !details.changedObjects.isEmpty }
                return indexes.contains { index in
                    let asset = details.fetchResultBeforeChanges.object(at: index)
                    guard let change = changeInstance.changeDetails(for: asset) else { return true }
                    let before = change.objectBeforeChanges
                    guard let after = change.objectAfterChanges else { return true }
                    return change.assetContentChanged || Self.changed(before, after)
                }
            }
            if changed { continuation.yield(()) }
        }

        private static func changed(_ before: PHAsset, _ after: PHAsset) -> Bool {
            PhotoLibrarySource.describe(before) != PhotoLibrarySource.describe(after)
        }
    }
}

typealias PhotoImageRequest = PhotoRequest<AssetImage>

final class PhotoRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void

    init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void = { PHImageManager.default().cancelImageRequest($0) }) {
        self.cancelRequest = cancelRequest
    }

    func begin(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
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
        if shouldCancel { cancelRequest(id) }
    }

    func complete(_ result: Result<Value, any Error>, cancellingRequest: Bool = false) {
        let (next, id) = lock.withLock {
            if cancellingRequest { cancelled = true }
            defer {
                continuation = nil
                requestID = nil
            }
            return (continuation, cancellingRequest ? requestID : nil)
        }
        next?.resume(with: result)
        if let id { cancelRequest(id) }
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
        if let id { cancelRequest(id) }
    }
}

extension PhotoRequest where Value == AssetImage {
    func complete(data: Data?, orientation: CGImagePropertyOrientation, info: [AnyHashable: Any]?, allowsDownload: Bool) {
        let result: Result<AssetImage, any Error>
        if info?[PHImageCancelledKey] as? Bool == true {
            result = .failure(allowsDownload
                ? PhotoLibraryDownloadError(message: "Photos cancelled this download before returning image data. Please retry.")
                : AssetAccessError.inaccessible)
        } else if !allowsDownload, data?.isEmpty != false, info?[PHImageResultIsInCloudKey] as? Bool == true {
            result = .failure(AssetAccessError.cloudDownloadRequired)
        } else if let error = info?[PHImageErrorKey] as? NSError {
            result = .failure(allowsDownload ? PhotoLibraryDownloadError(error) : error)
        } else if info?[PHImageResultIsDegradedKey] as? Bool == true {
            return
        } else if let data, !data.isEmpty {
            result = .success(AssetImage(data: data, orientation: orientation))
        } else if allowsDownload {
            result = .failure(PhotoLibraryDownloadError(message: "Photos returned no image data. Please retry the download."))
        } else {
            result = .failure(info?[PHImageErrorKey] as? Error ?? AssetAccessError.inaccessible)
        }
        complete(result)
    }
}

public struct PhotoLibraryDownloadError: LocalizedError, Sendable {
    public let domain: String?
    public let code: Int?
    public let message: String

    init(_ error: NSError) {
        domain = error.domain
        code = error.code
        message = error.localizedDescription
    }

    init(message: String) {
        domain = nil
        code = nil
        self.message = message
    }

    public var errorDescription: String? {
        guard let domain, let code else { return message }
        return "\(message) (\(domain), \(code))"
    }
}
