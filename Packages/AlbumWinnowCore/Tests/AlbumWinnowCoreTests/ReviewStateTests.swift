import XCTest
@testable import AlbumWinnowCore

final class ReviewStateTests: XCTestCase {
    private func asset(_ item: String, revision: String = "1") -> PhotoAsset {
        PhotoAsset(id: AssetID(source: "test", item: item), name: item, revision: revision)
    }

    private func group(_ a: PhotoAsset, _ b: PhotoAsset, match: DuplicateMatch = .exactDuplicate) -> DuplicateGroup {
        DuplicateGroup(preferred: a, duplicates: [DuplicateMember(asset: b, match: match)], preferredDimensions: nil)
    }

    func testSignatureIgnoresRecommendationAndOrderButRejectsChangedEvidence() throws {
        let a = asset("a"), b = asset("b")
        XCTAssertEqual(try group(a, b).reviewSignature(), try group(b, a).reviewSignature())
        XCTAssertNotEqual(try group(a, b).reviewSignature(), try group(a, asset("b", revision: "2")).reviewSignature())
        XCTAssertNotEqual(try group(a, b).reviewSignature(), try group(a, b, match: .similarPhoto).reviewSignature())
        let enlarged = DuplicateGroup(preferred: a, duplicates: [DuplicateMember(asset: b, match: .exactDuplicate),
            DuplicateMember(asset: asset("c"), match: .exactDuplicate)], preferredDimensions: nil)
        XCTAssertNotEqual(try group(a, b).reviewSignature(), try enlarged.reviewSignature())
    }

    func testReopenAndResetPreserveLocks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "review.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = asset("a"), b = asset("b"), g = group(a, b)
        let store = try ReviewStateStore(url: url)
        var state = ReviewState()
        let signature = try g.reviewSignature()
        state.decisions[signature] = ReviewDecision(status: .confirmed, keepID: a.id, removals: [b.id])
        state.locked.insert(b.id)
        state.anchor = signature
        try store.save(state)
        let reopened = try ReviewStateStore(url: url)
        XCTAssertEqual(try reopened.load(), state)
        state.resetProgress()
        try reopened.save(state)
        XCTAssertEqual(try store.load().locked, [b.id])
        XCTAssertTrue(try store.load().decisions.isEmpty)
    }

    func testCorruptDatabaseIsNotRecreatedAsUnprotectedState() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a database".utf8).write(to: url)
        XCTAssertThrowsError(try ReviewStateStore(url: url))
    }

    func testLockedAndAliasedFilesCannotReachRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "a.png"), alias = directory.appending(path: "b.png")
        try Data([1]).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)
        let source = FileSystemSource(directory: directory)
        let assets = try await source.snapshot().assets.sorted { $0.name < $1.name }
        let protection = CleanupProtection(locked: [assets[0].id])
        do {
            try await AssetMutationService.validateRemovals([assets[1]], sources: [source], protection: protection)
            XCTFail("A hard link must not bypass a lock")
        } catch { XCTAssertEqual(error as? CleanupError, .userProtected) }
        let outcomes = try await AssetMutationService().apply(
            [CleanupPair(remove: assets[0], fromWholeGroup: assets[0].id),
             CleanupPair(remove: assets[1], fromWholeGroup: assets[0].id)], sources: [source], protection: protection)
        XCTAssertTrue(outcomes.allSatisfy { $0.status == .skipped })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        let durableProtection = CleanupProtection(locked: [assets[0].id], lockedRevisions: [assets[0].id: assets[0].revision])
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(durableProtection.validateForReview(assets[1]), "An unavailable locked path must not unlock its surviving hard link")
    }
}
