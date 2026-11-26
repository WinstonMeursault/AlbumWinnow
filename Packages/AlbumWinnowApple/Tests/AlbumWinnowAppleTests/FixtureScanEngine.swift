import AlbumWinnowRust
import Foundation
@testable import AlbumWinnowApple

// Existing recognition fixtures retain their readable IDs and expected groups.
// Only this test adapter materializes all pages; production scan returns a receipt.
struct FixtureScanEngine: Sendable {
    private let engine: ScanEngine
    private let database: URL

    init(cacheURL: URL, parallelism: Int = 2) throws {
        engine = try ScanEngine(cacheURL: cacheURL, parallelism: parallelism)
        database = cacheURL.appendingPathExtension("fixture-review.sqlite")
    }

    func clearCache() async throws { try await engine.clearCache() }

    func fixtureScan(_ sources: [any AssetSource], refreshing: Set<AssetID> = [],
                     comparisonSides: ComparisonSides? = nil, preferredSource: String? = nil,
                     includeSimilarScenes: Bool = false,
                     progress: @Sendable (ScanProgress) -> Void = { _ in },
                     accounting: @Sendable (ScanAccounting) -> Void = { _ in }) async throws -> ScanResult {
        guard Set(sources.map(\.id)).count == sources.count else { throw ScanError.duplicateSourceID }
        try comparisonSides?.validate(sources: Set(sources.map(\.id)))
        let review = try RustReviewSession(databasePath: database.path,
            initialized: FileManager.default.fileExists(atPath: database.path))
        var originals = [String: String]()
        var native = [any AssetSource]()
        for source in sources {
            let input: CoreSourceInput
            if let folder = source as? FileSystemSource {
                input = CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
                    identity: try folder.sourceIdentity(), bookmark: Data(), label: source.id)
            } else {
                input = CoreSourceInput(kind: .controlledTest, namespace: "controlled.fixture.v2",
                    identity: Data(source.id.utf8), bookmark: Data(), label: source.id)
            }
            let record = try review.registerSource(expectedRevision: review.header().metadata.revision, input: input)
            originals[record.id] = source.id
            if let folder = source as? FileSystemSource {
                native.append(FileSystemSource(directory: folder.directory, id: record.id))
            } else { native.append(FixtureSource(id: record.id, original: source)) }
        }
        // Inactive fixture inputs must disappear from the successful scan cache too.
        var offset: UInt64 = 0
        var catalog = [CoreSourceRecord]()
        while true {
            let page = try review.sourcesPage(offset: offset, limit: 256)
            catalog.append(contentsOf: page)
            offset += UInt64(page.count)
            if page.count < 256 { break }
        }
        for record in catalog where record.active && originals[record.id] == nil {
            _ = try review.setSourceActive(expectedRevision: review.header().metadata.revision, source: record.id, active: false)
        }
        catalog = try review.sourcesPage(offset: 0, limit: 256)
        // Fixtures have at most a few sources; assert rather than silently truncate.
        guard catalog.count < 256 else { throw ScanError.invalidSourceSnapshot }
        let remapped = Dictionary(uniqueKeysWithValues: originals.map { ($0.value, $0.key) })
        var settings = try review.header().settings
        settings.sides = comparisonSides.map { CoreComparisonSides(first: remapped[$0.first]!, second: remapped[$0.second]!) }
        settings.preferredSource = preferredSource.flatMap { remapped[$0] }
        settings.similarScenesEnabled = includeSimilarScenes
        _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
        let receipt = try await engine.scan(AppleAssetSources(sources: native, registered: catalog), review: review,
            refreshing: Set(refreshing.map { AssetID(source: remapped[$0.source] ?? $0.source, item: $0.item) }),
            progress: progress, accounting: accounting)
        guard receipt.cacheMaintenance == .completed else { throw ScanError.invalidSourceSnapshot }
        var groups = [DuplicateGroup]()
        for collection in [CoreReviewCollection.duplicates, .similarScenes] {
            settings.query.collection = collection
            settings.query.status = .all
            _ = try review.saveSettings(expectedRevision: review.header().metadata.revision, settings: settings)
            var offset: UInt64 = 0
            while true {
                let page = try review.queryPage(offset: offset, limit: 256)
                for summary in page {
                    groups.append(try fixtureGroup(review.groupDetail(signature: summary.signature).group, kind: summary.kind, originals: originals))
                }
                offset += UInt64(page.count)
                if page.count < 256 { break }
            }
        }
        return ScanResult(groups: groups, issues: receipt.issues.map {
            AssetIssue(id: AssetID(source: originals[$0.id.source] ?? $0.id.source, item: $0.id.item), reason: $0.reason, detail: $0.detail)
        }, scanned: receipt.scanned, reused: receipt.reused)
    }
}

private struct FixtureSource: AssetSource {
    let id: String
    let original: any AssetSource

    private func asset(_ value: PhotoAsset, source: String) -> PhotoAsset {
        PhotoAsset(id: AssetID(source: source, item: value.id.item), name: value.name, revision: value.revision,
            photoProperties: value.photoProperties, byteCount: value.byteCount, captureDate: value.captureDate,
            burstIdentifier: value.burstIdentifier)
    }

    func snapshot() async throws -> AssetSnapshot {
        let snapshot = try await original.snapshot()
        return AssetSnapshot(assets: snapshot.assets.map { asset($0, source: $0.id.source == original.id ? id : $0.id.source) },
            issues: snapshot.issues.map { AssetIssue(id: AssetID(source: $0.id.source == original.id ? id : $0.id.source,
                item: $0.id.item), reason: $0.reason, detail: $0.detail) })
    }
    func imageData(for value: PhotoAsset) async throws -> Data { try await original.imageData(for: asset(value, source: original.id)) }
    func image(for value: PhotoAsset) async throws -> AssetImage { try await original.image(for: asset(value, source: original.id)) }
    func validateCachedAvailability(for value: PhotoAsset) async throws {
        try await original.validateCachedAvailability(for: asset(value, source: original.id))
    }
    func skipsCloudAsset(_ value: AssetID) -> Bool { original.skipsCloudAsset(AssetID(source: original.id, item: value.item)) }
}

func fixtureGroup(_ value: CoreReviewGroup, kind: CoreMatch, originals: [String: String] = [:]) throws -> DuplicateGroup {
    func id(_ key: CoreAssetKey) -> AssetID { AssetID(source: originals[key.sourceId] ?? key.sourceId, item: key.itemId) }
    let members = Dictionary(uniqueKeysWithValues: value.members.map { member in
        let asset = PhotoAsset(member)
        return (asset.id, PhotoAsset(id: id(member.id), name: asset.name, revision: asset.revision,
            photoProperties: asset.photoProperties, byteCount: asset.byteCount, captureDate: asset.captureDate,
            burstIdentifier: asset.burstIdentifier))
    })
    guard let preferred = members[AssetID(value.preferred)] else { throw ScanError.invalidSourceSnapshot }
    let evidence = Dictionary(uniqueKeysWithValues: value.evidence.map { item in
        var observation = PhotoEvidence(width: Int(item.width), height: Int(item.height), bitDepth: item.bitDepth.map(Int.init),
            hasWideColor: item.wideColor, edgeContrast: item.edgeDetail)
        observation.captureDate = item.captureDate.map(Date.init(timeIntervalSince1970:))
        return (id(item.asset), observation)
    })
    var result = DuplicateGroup(preferred: preferred, duplicates: try value.duplicates.map { duplicate in
        guard let asset = members[AssetID(duplicate.asset)] else { throw ScanError.invalidSourceSnapshot }
        return DuplicateMember(asset: asset, match: DuplicateMatch(duplicate.kind))
    }, preferredDimensions: evidence[preferred.id].map { ImageDimensions(width: $0.width, height: $0.height) })
    result.match = DuplicateMatch(kind)
    result.edges = value.edges?.map { MatchEdge(first: id($0.first), second: id($0.second), match: DuplicateMatch($0.kind)) }
    result.comparisonSides = value.sides.map { ComparisonSides(first: originals[$0.first] ?? $0.first, second: originals[$0.second] ?? $0.second) }
    result.evidence = evidence
    result.recommendedID = value.recommendation.map(id)
    if value.scene != nil {
        result.sceneAlgorithm = SceneFeature.version
        result.hasQualityRecommendation = value.hasQualityRecommendation
        result.sceneQuality = Dictionary(uniqueKeysWithValues: value.sceneQuality.map { item in
            (id(item.asset), SceneQuality(item.quality))
        })
        result.sceneEvidence = value.sceneMatches.map { item in SceneMatchEvidence(
            edge: MatchEdge(first: id(item.first), second: id(item.second), match: .sceneSimilar),
            featureDistance: item.distance, sharedBurst: item.sharedBurst) }
        result.sceneRecommendationReason = value.sceneRecommendationReason.map { reason in
            switch reason {
            case .focusSignal: .focusSignal
            case .exposureSignal: .exposureSignal
            case .sourcePreference: .sourcePreference
            case .associatedResources: .associatedResources
            case .higherResolution: .higherResolution
            case .higherBitDepth: .higherBitDepth
            case .wideColor: .wideColor
            case .edgeContrast: .edgeContrast
            case .noQualityAdvantage: .noQualityAdvantage
            }
        }
    }
    return result
}
