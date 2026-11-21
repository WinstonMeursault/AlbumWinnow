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
    private var waiters: [(id: UUID, units: Int, continuation: CheckedContinuation<Void, any Error>)] = []

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

        let units = key.pixelSize > 1024 ? 4 : 1
        try await acquire(units: units)
        defer { release(units: units) }
        try Task.checkCancellation()
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let image = try await load()
        try Task.checkCancellation()
        // Detail images belong to their visible view and are released when zoom ends.
        if key.pixelSize <= 1024 {
            cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    func clear() { cache.removeAllObjects() }

    func preview(estimatedBytes: Int = 0, load: @Sendable () async throws -> LoadedPreview) async throws -> LoadedPreview {
        let budget = 16 * 1024 * 1024
        let units = min(4, max(1, estimatedBytes / budget + (estimatedBytes % budget > 0 ? 1 : 0)))
        try await acquire(units: units)
        defer { release(units: units) }
        try Task.checkCancellation()
        let preview = try await load()
        try Task.checkCancellation()
        return preview
    }

    private func acquire(units: Int = 1) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters.isEmpty && active + units <= 4 {
                    active += units
                    continuation.resume()
                } else {
                    waiters.append((id, units, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drainWaiters()
    }

    private func release(units: Int) {
        active -= units
        drainWaiters()
    }

    private func drainWaiters() {
        while let next = waiters.first, active + next.units <= 4 {
            active += next.units
            waiters.removeFirst().continuation.resume()
        }
    }
}
