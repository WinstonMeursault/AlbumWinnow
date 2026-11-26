import AlbumWinnowRust
import XCTest
@testable import AlbumWinnowApple

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
        let root = TestFiles.root.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "review.sqlite").path
        var locked: CoreReviewAsset!
        var signature = ""
        do {
            let session = try RustReviewSession(databasePath: path, initialized: false)
            let group = try fixtureReviewGroup(session)
            try commitFixtureGroups([group], to: session)
            signature = try XCTUnwrap(session.queryPage(offset: 0, limit: 1).first).signature
            _ = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature,
                commandId: "confirmed", intent: .confirmKeep(keep: group.preferred))
            locked = group.members[1]
            _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: locked, locked: true)
            try session.savePosition(expectedRevision: session.header().metadata.revision, sequence: 1, anchor: signature, position: 0)
        }
        do {
            let reopened = try RustReviewSession(databasePath: path, initialized: true)
            XCTAssertEqual(try reopened.resumeSignature(), signature)
            XCTAssertEqual(try reopened.lockedPage(offset: 0, limit: 16), [locked])
            XCTAssertTrue(try XCTUnwrap(reopened.groupDetail(signature: signature).decision).removals.isEmpty)
            _ = try reopened.resetProgress(expectedRevision: reopened.header().metadata.revision)
        }
        let final = try RustReviewSession(databasePath: path, initialized: true)
        XCTAssertEqual(try final.lockedPage(offset: 0, limit: 16), [locked])
        XCTAssertEqual(try final.header().metadata.decisionCount, 0)
        XCTAssertNil(try final.header().anchor)
        XCTAssertNil(try final.header().position)
    }

    func testCorruptDatabaseIsNotRecreatedAsUnprotectedState() throws {
        let url = TestFiles.root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("not a database".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try RustReviewSession(databasePath: url.path, initialized: true))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLockedAndAliasedFilesCannotReachRemoval() async throws {
        let root = TestFiles.root.appending(path: UUID().uuidString)
        let directory = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = directory.appending(path: "a.png"), alias = directory.appending(path: "b.png")
        let keepURL = directory.appending(path: "keep.png")
        let bytes = Data([1])
        try bytes.write(to: original)
        try bytes.write(to: keepURL)
        try FileManager.default.linkItem(at: original, to: alias)
        let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
        let record = try session.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .fileSystem,
            namespace: FileSystemSource.sourceIdentityNamespace,
            identity: FileSystemSource.sourceIdentity(directory: directory), bookmark: Data(), label: "Files"))
        let source = FileSystemSource(directory: directory, id: record.id)
        func descriptions() async throws -> [CoreReviewAsset] {
            try await source.snapshot().assets.map {
                try $0.reviewValue(kind: .fileSystem, nativeIdentity: source.nativeIdentity(for: $0), linkCount: source.linkCount(for: $0))
            }
        }
        let assets = try await descriptions()
        let locked = try XCTUnwrap(assets.first { $0.name == "a.png" })
        _ = try session.setLocked(expectedRevision: session.header().metadata.revision, asset: locked, locked: true)
        func assertNoRemoval(_ members: [CoreReviewAsset]) throws {
            let keep = try XCTUnwrap(members.first { $0.name == "keep.png" })
            let group = CoreReviewGroup(preferred: keep.id, members: members,
                duplicates: members.filter { $0.id != keep.id }.map { CoreReviewDuplicate(asset: $0.id, kind: .exactDuplicate) },
                edges: nil, sides: nil, scene: nil, recommendation: nil, hasQualityRecommendation: true,
                sceneRecommendationReason: nil, sceneQuality: [], sceneMatches: [], evidence: [])
            try commitFixtureGroups([group], to: session)
            let summary = try XCTUnwrap(session.queryPage(offset: 0, limit: 1).first)
            let detail = try session.groupDetail(signature: summary.signature)
            XCTAssertTrue(detail.protected.contains { $0.itemId == alias.path })
            let result = try session.applyIntent(expectedRevision: session.header().metadata.revision,
                signature: summary.signature, commandId: UUID().uuidString, intent: .confirmKeep(keep: keep.id))
            XCTAssertTrue(result.decision.removals.isEmpty)
            XCTAssertThrowsError(try session.startCleanup(expectedRevision: result.metadata.revision)) { error in
                guard case BridgeError.InvalidValue = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        try assertNoRemoval(assets)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        try assertNoRemoval(try await descriptions())
        XCTAssertEqual(try Data(contentsOf: alias), bytes)
        XCTAssertEqual(try Data(contentsOf: keepURL), bytes)
    }
}
