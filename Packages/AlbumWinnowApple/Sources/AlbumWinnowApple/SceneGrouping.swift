import AlbumWinnowRust
import Foundation

struct SceneItem {
    let asset: PhotoAsset
    let evidence: PhotoEvidence
    let feature: SceneFeature
    var nativeIdentity: String? = nil
    var bitDepth: Int? = nil
    var captureDate: Date? { asset.captureDate ?? evidence.captureDate }

    var coreValue: CoreSceneAsset {
        get throws {
            guard let width = UInt32(exactly: evidence.width), let height = UInt32(exactly: evidence.height),
                  let depth = UInt16(exactly: bitDepth ?? evidence.bitDepth ?? 8) else {
                throw RustCoreFailure(underlying: BridgeError.InvalidValue)
            }
            return CoreSceneAsset(asset: asset.id.coreValue, revision: asset.revision, provider: SceneFeature.provider,
                                  quality: feature.quality.coreValue, keys: feature.keys, width: width, height: height,
                                  bitDepth: depth, wideColor: evidence.hasWideColor, edgeDetail: evidence.edgeContrast ?? 0,
                                  associatedResources: asset.photoProperties?.hasAssociatedResources == true,
                                  nativeIdentity: nativeIdentity, burst: asset.burstIdentifier,
                                  date: captureDate?.timeIntervalSince1970)
        }
    }
}

// Native observations stay in the host. Rust requests each needed distance outside its state lock.
struct SceneGrouping {
    static func detect(_ items: [SceneItem], operation: String, sides: ComparisonSides?, preferredSource: String?,
                       cancellation: CancellationHandle, validate: (PhotoAsset) throws -> Void,
                       progress: (Int) -> Void) throws -> RustSceneSession {
        let session = try coreResult {
            try RustSceneSession(operationId: operation, provider: SceneFeature.provider,
                                 sides: sides.map { CoreComparisonSides(first: $0.first, second: $0.second) },
                                 preferredSource: preferredSource, cancellation: cancellation)
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.asset.id, $0) })
        for start in stride(from: 0, to: items.count, by: 16) {
            try Task.checkCancellation()
            try coreResult { try session.appendPrepared(items: items[start..<min(start + 16, items.count)].map { try $0.coreValue }) }
        }
        try coreResult { try session.completePreparation() }
        var lastProgress = -1
        while true {
            try Task.checkCancellation()
            let work = try coreResult { try session.nextWork() }
            if Int(work.completed) != lastProgress {
                lastProgress = Int(work.completed)
                progress(lastProgress)
                try Task.checkCancellation()
            }
            guard let request = work.request else { break }
            guard let first = byID[AssetID(request.first)], let second = byID[AssetID(request.second)],
                  first.asset.revision == request.firstRevision, second.asset.revision == request.secondRevision else {
                throw ScanError.invalidSourceSnapshot
            }
            try validate(first.asset)
            try validate(second.asset)
            let distance = try first.feature.distance(to: second.feature)
            try Task.checkCancellation()
            try validate(first.asset)
            try validate(second.asset)
            try coreResult { try session.submitDistance(operationId: operation, taskId: request.taskId, distance: distance) }
        }
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let page = try coreResult { try session.finalValidationPage(offset: offset, limit: 16) }
            if page.isEmpty { break }
            var facts = [CoreAssetValidation]()
            for key in page {
                guard let item = byID[AssetID(key)] else { throw ScanError.invalidSourceSnapshot }
                try validate(item.asset)
                facts.append(CoreAssetValidation(asset: key, revision: item.asset.revision, accessible: true))
            }
            try coreResult { try session.submitFinalValidations(operationId: operation, validations: facts) }
            offset += UInt64(page.count)
        }
        return session
    }

}
