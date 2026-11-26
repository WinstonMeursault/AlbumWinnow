import AlbumWinnowRust
import Foundation
import ImageIO
import Testing
@testable import AlbumWinnowApple

private final class EvidenceReview {
    let root = TestFiles.root.appending(path: UUID().uuidString)
    let session: RustReviewSession
    let source: CoreSourceRecord

    init() throws {
        session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
        source = try session.registerSource(expectedRevision: session.header().metadata.revision,
            input: CoreSourceInput(kind: .controlledTest, namespace: "evidence.fixture.v2",
                identity: Data([1]), bookmark: Data(), label: "Evidence"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func asset(_ item: String, bytes: Int64? = nil, date: Double? = nil) -> CoreReviewAsset {
        PhotoAsset(id: AssetID(source: source.id, item: item), name: item, revision: "1", byteCount: bytes,
            captureDate: date.map(Date.init(timeIntervalSince1970:))).reviewValue(kind: .controlledTest)
    }

    func group(_ item: String, bytes: Int64? = nil, date: Double? = nil) -> CoreReviewGroup {
        let a = asset(item, bytes: bytes, date: date), b = asset(item + "-copy", bytes: bytes, date: date)
        return CoreReviewGroup(preferred: a.id, members: [a, b],
            duplicates: [CoreReviewDuplicate(asset: b.id, kind: .exactDuplicate)], edges: nil, sides: nil,
            scene: nil, recommendation: nil, hasQualityRecommendation: true, sceneRecommendationReason: nil,
            sceneQuality: [], sceneMatches: [], evidence: [])
    }

    func scan(_ groups: [CoreReviewGroup]) throws {
        let operation = UUID().uuidString
        try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: operation)
        try session.appendScanGroups(operationId: operation, groups: groups, cancellation: CancellationHandle())
        _ = try session.finishScan(operationId: operation, cancellation: CancellationHandle())
    }

    func query(sort: CoreReviewSort = .stable, status: CoreReviewStatusFilter = .all,
               source: String? = nil) throws -> [CoreGroupSummary] {
        var settings = try session.header().settings
        settings.query = CoreReviewQuery(collection: .duplicates, status: status, kind: nil, source: source, sort: sort)
        _ = try session.saveSettings(expectedRevision: session.header().metadata.revision, settings: settings)
        return try session.queryPage(offset: 0, limit: 256)
    }

    func status(_ status: CoreReviewStatus, signature: String) throws {
        _ = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature,
            commandId: UUID().uuidString, intent: .setStatus(status: status))
    }
}

@Test func recommendationDoesNotTurnMissingBitDepthIntoAnEightBitClaim() throws {
    let fixture = try EvidenceReview()
    var group = fixture.group("a")
    group.evidence = [
        CoreReviewEvidence(asset: group.members[0].id, width: 1600, height: 900, bitDepth: 16,
            wideColor: false, edgeDetail: 1, captureDate: nil),
        CoreReviewEvidence(asset: group.members[1].id, width: 800, height: 450, bitDepth: nil,
            wideColor: false, edgeDetail: 1, captureDate: nil),
    ]
    func reasons() throws -> [CoreRecommendationReason] {
        try fixture.scan([group])
        let summary = try #require(fixture.query().first)
        return try fixture.session.groupDetail(signature: summary.signature).reasons
    }
    let unknown = try reasons()
    #expect(unknown.contains(.higherResolution))
    #expect(!unknown.contains(.higherBitDepth))
    group.evidence[1].bitDepth = 8
    #expect(try reasons().contains(.higherBitDepth))
    group.evidence = []
    #expect(try reasons() == [.noQualityAdvantage])
}

@Test func unknownDatesStayLastInEitherDirectionAndStableTiesRemainStable() throws {
    let fixture = try EvidenceReview()
    let unknown = fixture.group("unknown"), old = fixture.group("old", date: 100), new = fixture.group("new", date: 200)
    try fixture.scan([unknown, old, new])
    #expect(try fixture.query(sort: .newest).map(\.preferred) == [new.preferred, old.preferred, unknown.preferred])
    #expect(try fixture.query(sort: .oldest).map(\.preferred) == [old.preferred, new.preferred, unknown.preferred])
    try fixture.scan([new, unknown, old])
    #expect(try fixture.query(sort: .count).map(\.preferred) == [new.preferred, unknown.preferred, old.preferred])
}

@Test func sizeEstimatesDistinguishPartialUnknownProtectedAndOverflow() throws {
    let fixture = try EvidenceReview()
    let a = fixture.asset("a", bytes: 1024), b = fixture.asset("b"), c = fixture.asset("c", bytes: -10)
    #expect(c.byteCount == nil)
    var group = fixture.group("group")
    group.preferred = c.id
    group.members = [c, a, b]
    group.duplicates = [a, b].map { CoreReviewDuplicate(asset: $0.id, kind: .exactDuplicate) }
    try fixture.scan([group])
    let partial = try #require(fixture.query().first)
    #expect(partial.estimate.knownBytes == 1024 && partial.estimate.knownCount == 1 && partial.estimate.unknownCount == 1)
    _ = try fixture.session.setLocked(expectedRevision: fixture.session.header().metadata.revision, asset: a, locked: true)
    let protected = try #require(fixture.query().first)
    #expect(protected.estimate.knownCount == 0 && protected.estimate.unknownCount == 1)
    try fixture.status(.kept, signature: partial.signature)
    let empty = try #require(fixture.query().first)
    #expect(empty.estimate.knownBytes == 0 && empty.estimate.unknownCount == 0)
    var maximum = fixture.group("maximum", bytes: Int64.max)
    let extra = fixture.asset("maximum-extra", bytes: Int64.max)
    maximum.members.append(extra)
    maximum.duplicates.append(CoreReviewDuplicate(asset: extra.id, kind: .exactDuplicate))
    try fixture.scan([maximum])
    let overflowing = try #require(fixture.query().first).estimate
    #expect(overflowing.knownBytes == UInt64(Int64.max))
    #expect(overflowing.overflowed)
}

@Test func resultFiltersDoNotMutateDecisionsAndSortSizeUsesKnownLowerBounds() throws {
    let fixture = try EvidenceReview()
    let unused = try fixture.session.registerSource(expectedRevision: fixture.session.header().metadata.revision,
        input: CoreSourceInput(kind: .controlledTest, namespace: "evidence.fixture.v2",
            identity: Data([2]), bookmark: Data(), label: "No matching groups"))
    let unknown = fixture.group("unknown"), small = fixture.group("small", bytes: 10), large = fixture.group("large", bytes: 20)
    try fixture.scan([unknown, small, large])
    let initial = try fixture.query(sort: .bytes)
    #expect(initial.map(\.preferred) == [large.preferred, small.preferred, unknown.preferred])
    let largeSignature = try #require(initial.first { $0.preferred == large.preferred }).signature
    let smallSignature = try #require(initial.first { $0.preferred == small.preferred }).signature
    try fixture.status(.kept, signature: smallSignature)
    try fixture.status(.kept, signature: largeSignature)
    #expect(try fixture.query(sort: .bytes).map(\.preferred) == [small.preferred, large.preferred, unknown.preferred])
    _ = try fixture.session.applyIntent(expectedRevision: fixture.session.header().metadata.revision,
        signature: largeSignature, commandId: "confirm-large", intent: .confirmKeep(keep: large.preferred))
    #expect(try fixture.query(status: .kept).map(\.preferred) == [small.preferred])
    let before = try fixture.session.groupDetail(signature: largeSignature).decision
    #expect(before?.status == .confirmed)
    #expect(try fixture.query(source: unused.id).isEmpty)
    let header = try fixture.session.header()
    #expect(throws: BridgeError.InvalidValue) { try fixture.query(source: "unregistered") }
    #expect(try fixture.session.header() == header)
    #expect(try fixture.session.groupDetail(signature: largeSignature).decision == before)
}

@Test func exifCaptureDateRequiresItsOwnOffsetAndRejectsInvalidDates() {
    #expect(ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:21 12:00:00"]) == nil)
    let date = ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:21 12:00:00",
                                               kCGImagePropertyExifOffsetTimeOriginal: "+08:00"])
    #expect(date == ISO8601DateFormatter().date(from: "2026-11-21T04:00:00Z"))
    #expect(ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:02:30 12:00:00",
                                            kCGImagePropertyExifOffsetTimeOriginal: "+08:00"]) == nil)
}
