import AlbumWinnowCore
import CoreGraphics
import Foundation

struct GalleryThumbnailKey: Hashable, Sendable {
    let assetID: AssetID
    let revision: String
    let pixelSize: Int

    init(asset: PhotoAsset, pixelSize: Int) {
        assetID = asset.id
        revision = asset.revision
        self.pixelSize = pixelSize
    }
}

actor GalleryThumbnails {
    private final class CacheKey: NSObject {
        let value: GalleryThumbnailKey

        init(_ value: GalleryThumbnailKey) { self.value = value }

        override var hash: Int { value.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? CacheKey)?.value == value
        }
    }

    private let cache: NSCache<CacheKey, CGImage>
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init() {
        let cache = NSCache<CacheKey, CGImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1024 * 1024
        self.cache = cache
    }

    func image(for key: GalleryThumbnailKey, load: @Sendable () async throws -> CGImage) async throws -> CGImage {
        try Task.checkCancellation()
        let cacheKey = CacheKey(key)
        if let cached = cache.object(forKey: cacheKey) { return cached }

        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let image = try await load()
        try Task.checkCancellation()
        cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }

    func clear() { cache.removeAllObjects() }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if active < 4 {
                    active += 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
