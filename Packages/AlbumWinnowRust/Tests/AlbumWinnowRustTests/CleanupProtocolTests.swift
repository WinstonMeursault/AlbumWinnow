import AlbumWinnowRust
import Foundation
import Testing

private func scannedReview(_ root: URL) throws -> (RustReviewSession, CoreReviewGroup, String) {
    let session = try RustReviewSession(databasePath: root.appending(path: "review.sqlite").path, initialized: false)
    let group = try reviewFixture(session)
    try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: "scan")
    try session.appendScanGroups(operationId: "scan", groups: [group], cancellation: CancellationHandle())
    _ = try session.finishScan(operationId: "scan", cancellation: CancellationHandle())
    return (session, group, try #require(session.queryPage(offset: 0, limit: 1).first).signature)
}
private func nativeFacts(_ asset: CoreReviewAsset, source: CoreSourceRecord) -> CoreRemovalFacts {
    CoreRemovalFacts(asset: asset, sourceNamespace: source.nativeNamespace, sourceIdentity: source.nativeIdentity,
        accessible: true, inScanScope: true, independentlyRemovable: true, insideReadOnlyRoot: false,
        matchesSavedLock: false, protectionComplete: true)
}
private func validation(_ item: CoreCleanupItem, source: CoreSourceRecord, all: Bool) -> CoreCleanupValidation {
    CoreCleanupValidation(key: item.key, facts: CorePairFacts(keep: item.pair.keep.map { nativeFacts($0, source: source) },
        remove: nativeFacts(item.pair.remove, source: source), proof: all ? .wholeGroup : .pixels(kind: .exactDuplicate)))
}

// Controlled facts/outcomes only. Actual Trash/PhotoKit integration has separate tests.
@Test func controlledCleanupTicketsPreflightAndPartialCancellationCrossSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-cleanup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, group, signature) = try scannedReview(root)
    let source = try #require(session.sourcesPage(offset: 0, limit: 1).first)
    let confirmed = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature, commandId: "all", intent: .confirmDeleteAll)
    let plan = try session.startCleanup(expectedRevision: confirmed.metadata.revision)
    #expect(plan.itemCount == 2 && plan.groupCount == 1)
    #expect(try session.cleanupGroupsPage(operation: plan.operation, offset: 0, limit: 1).first?.deleteAll == true)
    let items = try session.cleanupItemsPage(operation: plan.operation, group: 0, offset: 0, limit: 16)
    let first = validation(items[0], source: source, all: true)
    #expect(try session.authorizeCleanup(operation: plan.operation, items: [first], cancellation: CancellationHandle()).rejection == .invalidSelection)
    #expect(try session.beginCleanupPreflight(operation: plan.operation, group: 0) == nil)
    #expect(try session.appendCleanupPreflight(operation: plan.operation, group: 0, facts: [nativeFacts(group.members[0], source: source)], cancellation: CancellationHandle()) == nil)
    #expect(try session.finishCleanupPreflight(operation: plan.operation, group: 0) == .invalidSelection)
    #expect(try session.appendCleanupPreflight(operation: plan.operation, group: 0, facts: [nativeFacts(group.members[1], source: source)], cancellation: CancellationHandle()) == nil)
    #expect(try session.finishCleanupPreflight(operation: plan.operation, group: 0) == nil)
    let ticket = try #require(session.authorizeCleanup(operation: plan.operation, items: [first], cancellation: CancellationHandle()).ticket)
    #expect(try session.validateCleanupTicket(ticket: ticket) == nil)
    #expect(throws: BridgeError.InvalidState) {
        try session.setLocked(expectedRevision: confirmed.metadata.revision, asset: group.members[1], locked: true)
    }
    #expect(try session.reportCleanup(ticket: ticket, outcomes: [.movedToTrash]).recorded)
    #expect(try !session.reportCleanup(ticket: ticket, outcomes: [.movedToTrash]).recorded)
    #expect(try session.cancelCleanup(operation: plan.operation) == nil)
    #expect(try session.authorizeCleanup(operation: plan.operation, items: [validation(items[1], source: source, all: true)], cancellation: CancellationHandle()).rejection == .cancelled)
    let finished = try session.finishCleanup(operation: plan.operation)
    #expect(finished.decisionCount == 0)
    #expect(try session.queryCount() == 0)
    let results = try session.cleanupResultsPage(operation: plan.operation, completed: true, offset: 0, limit: 256)
    #expect(results.map(\.outcome) == [.movedToTrash, .skipped(reason: .cancelled)])
    #expect(try session.validateCleanupTicket(ticket: ticket) == .stalePlan)
}

@Test func lockAfterCleanupPlanningRejectsTheOldPlanThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-cleanup-lock-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, group, signature) = try scannedReview(root)
    let source = try #require(session.sourcesPage(offset: 0, limit: 1).first)
    let decision = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature, commandId: "keep", intent: .confirmKeep(keep: group.preferred))
    let plan = try session.startCleanup(expectedRevision: decision.metadata.revision)
    let item = try #require(session.cleanupItemsPage(operation: plan.operation, group: 0, offset: 0, limit: 1).first)
    _ = try session.setLocked(expectedRevision: decision.metadata.revision, asset: group.members[1], locked: true)
    #expect(try session.authorizeCleanup(operation: plan.operation, items: [validation(item, source: source, all: false)], cancellation: CancellationHandle()).rejection == .stalePlan)
    #expect(try session.cancelCleanup(operation: plan.operation) == nil)
    _ = try session.finishCleanup(operation: plan.operation)
    #expect(try session.header().lockedCount == 1)
    #expect(try session.groupDetail(signature: signature).decision?.removals.isEmpty == true)
}

@Test func boundedReadOnlyCancellationNeverPublishesPartialPolicyThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-policy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, group, _) = try scannedReview(root)
    let before = try session.header().metadata
    try session.beginReadOnlySnapshot(expectedRevision: before.revision, operationId: "policy", source: group.preferred.sourceId)
    #expect(throws: BridgeError.InvalidBuffer) {
        try session.appendReadOnlySnapshot(operationId: "policy", members: Array(repeating: group.members[0], count: 17), cancellation: CancellationHandle())
    }
    try session.appendReadOnlySnapshot(operationId: "policy", members: group.members, cancellation: CancellationHandle())
    #expect(throws: BridgeError.InvalidValue) {
        try session.appendReadOnlySnapshot(operationId: "policy", members: [group.members[0]], cancellation: CancellationHandle())
    }
    let cancel = CancellationHandle()
    cancel.cancel()
    #expect(throws: BridgeError.Cancelled) { try session.finishReadOnlySnapshot(operationId: "policy", complete: true, cancellation: cancel) }
    #expect(try session.header().metadata == before)
    #expect(try session.header().readOnlySources.isEmpty)
    try session.discardReadOnlySnapshot(operationId: "policy")
}

@Test func actualReportedOutcomeRemainsReadableAfterProtectionStorageIsLostThroughSwift() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AlbumWinnow-v2-outcomes-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, group, signature) = try scannedReview(root)
    let source = try #require(session.sourcesPage(offset: 0, limit: 1).first)
    let decision = try session.applyIntent(expectedRevision: session.header().metadata.revision, signature: signature, commandId: "keep", intent: .confirmKeep(keep: group.preferred))
    let plan = try session.startCleanup(expectedRevision: decision.metadata.revision)
    let item = try #require(session.cleanupItemsPage(operation: plan.operation, group: 0, offset: 0, limit: 1).first)
    let ticket = try #require(session.authorizeCleanup(operation: plan.operation, items: [validation(item, source: source, all: false)], cancellation: CancellationHandle()).ticket)
    try FileManager.default.removeItem(at: root.appending(path: "review.sqlite"))
    #expect(try session.reportCleanup(ticket: ticket, outcomes: [.movedToTrash]).recorded)
    #expect(throws: BridgeError.ProtectionUnavailable) { try session.finishCleanup(operation: plan.operation) }
    #expect(!session.isHealthy())
    #expect(try session.cleanupResultsPage(operation: plan.operation, completed: false, offset: 0, limit: 1).first?.outcome == .movedToTrash)
}
