import Foundation
import ImageIO
import Testing
@testable import AlbumWinnowCore

private func reviewAsset(_ item: String, bytes: Int64? = nil, date: Date? = nil) -> PhotoAsset {
    PhotoAsset(id: AssetID(source: "evidence", item: item), name: item, revision: "1", byteCount: bytes, captureDate: date)
}

private func evidenceGroup(_ item: String, bytes: Int64? = nil, date: Date? = nil) -> DuplicateGroup {
    let a = reviewAsset(item, bytes: bytes, date: date)
    return DuplicateGroup(preferred: a, duplicates: [DuplicateMember(asset: reviewAsset(item + "-copy", bytes: bytes, date: date), match: .exactDuplicate)], preferredDimensions: nil)
}

@Test func recommendationDoesNotTurnMissingBitDepthIntoAnEightBitClaim() {
    var group = evidenceGroup("a")
    let a = group.preferred.id, b = group.duplicates[0].id
    group.evidence = [
        a: PhotoEvidence(width: 1600, height: 900, bitDepth: 16, hasWideColor: false, edgeContrast: 1),
        b: PhotoEvidence(width: 800, height: 450, bitDepth: nil, hasWideColor: false, edgeContrast: 1),
    ]
    #expect(group.recommendationReasons.contains(.higherResolution))
    #expect(!group.recommendationReasons.contains(.higherBitDepth))
    group.evidence?[b] = PhotoEvidence(width: 800, height: 450, bitDepth: 8, hasWideColor: false, edgeContrast: 1)
    #expect(group.recommendationReasons.contains(.higherBitDepth))
    group.evidence = nil
    #expect(group.recommendationReasons == [.noQualityAdvantage])
}

@Test func unknownDatesStayLastInEitherDirectionAndStableTiesRemainStable() {
    let unknown = evidenceGroup("unknown")
    let old = evidenceGroup("old", date: Date(timeIntervalSince1970: 100))
    let new = evidenceGroup("new", date: Date(timeIntervalSince1970: 200))
    var query = ReviewResultQuery()
    query.sort = .newest
    #expect(query.apply(to: [unknown, old, new]).map(\.id) == [new.id, old.id, unknown.id])
    query.sort = .oldest
    #expect(query.apply(to: [unknown, old, new]).map(\.id) == [old.id, new.id, unknown.id])
    query.sort = .count
    #expect(query.apply(to: [new, unknown, old]).map(\.id) == [new.id, unknown.id, old.id])
}

@Test func sizeEstimatesDistinguishPartialUnknownProtectedAndOverflow() {
    let a = reviewAsset("a", bytes: 1024), b = reviewAsset("b"), c = reviewAsset("c", bytes: -10)
    let group = DuplicateGroup(preferred: a, duplicates: [DuplicateMember(asset: b, match: .exactDuplicate),
        DuplicateMember(asset: c, match: .exactDuplicate)], preferredDimensions: nil)
    let partial = group.sizeEstimate(removing: [a.id, b.id])
    #expect(partial.knownBytes == 1024 && partial.unknownCount == 1 && partial.knownCount == 1)
    #expect(group.sizeEstimate(removing: [b.id, c.id]).knownCount == 0)
    #expect(group.sizeEstimate(removing: []).knownBytes == 0)
    let maximum = evidenceGroup("maximum", bytes: Int64.max)
    let overflowing = maximum.sizeEstimate(removing: [maximum.preferred.id, maximum.duplicates[0].id])
    #expect(overflowing.knownBytes == Int64.max)
    #expect(overflowing.overflowed)
}

@Test func resultFiltersDoNotMutateDecisionsAndSortSizeUsesKnownLowerBounds() {
    let unknown = evidenceGroup("unknown")
    let small = evidenceGroup("small", bytes: 10)
    let large = evidenceGroup("large", bytes: 20)
    var query = ReviewResultQuery()
    query.sort = .bytes
    let removals = Dictionary(uniqueKeysWithValues: [unknown, small, large].map { ($0.id, Set([$0.duplicates[0].id])) })
    #expect(query.apply(to: [unknown, small, large], removals: removals).map(\.id) == [large.id, small.id, unknown.id])
    let emptyRemovals: [AssetID: Set<AssetID>] = [small.id: [], large.id: []]
    #expect(query.apply(to: [unknown, small, large], removals: emptyRemovals).map(\.id) == [small.id, large.id, unknown.id])
    query.status = .kept
    let statuses = [large.id: ReviewStatus.confirmed, small.id: .kept]
    #expect(query.apply(to: [unknown, small, large], statuses: statuses).map(\.id) == [small.id])
    #expect(statuses[large.id] == .confirmed)
    query.status = .all
    query.source = "unavailable"
    #expect(query.apply(to: [unknown, small, large], statuses: statuses).isEmpty)
}

@Test func exifCaptureDateRequiresItsOwnOffsetAndRejectsInvalidDates() {
    #expect(ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:21 12:00:00"]) == nil)
    let date = ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:21 12:00:00",
                                               kCGImagePropertyExifOffsetTimeOriginal: "+08:00"])
    #expect(date == ISO8601DateFormatter().date(from: "2026-11-21T04:00:00Z"))
    #expect(ImageMetadata.captureDate(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:02:30 12:00:00",
                                            kCGImagePropertyExifOffsetTimeOriginal: "+08:00"]) == nil)
}
