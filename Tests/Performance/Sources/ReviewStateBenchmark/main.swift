import AlbumWinnowRust
import Darwin
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func milliseconds(_ action: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock(), start = ContinuousClock.now
    try action()
    let duration = start.duration(to: clock.now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
    return UInt64(info.resident_size)
}
var results: [[String: Any]] = []
for count in [100, 1_000, 10_000] {
    let url = root.appending(path: "\(UUID()).sqlite")
    var positions: [Double] = [], decisions: [Double] = []
    var changed = [String]()
    do {
        let session = try RustReviewSession(databasePath: url.path, initialized: false)
        let source = try session.registerSource(expectedRevision: 1, input: CoreSourceInput(kind: .controlledTest,
            namespace: "review.benchmark.v2", identity: Data([1]), bookmark: Data(), label: "Benchmark"))
        func member(_ item: String) -> CoreReviewAsset {
            CoreReviewAsset(id: CoreAssetKey(sourceId: source.id, itemId: item), name: item, revision: "opaque-fixture-revision",
                kind: .controlledTest, properties: nil, byteCount: 10_485_760, captureDate: nil,
                burst: nil, nativeIdentity: nil, linkCount: nil)
        }
        try session.beginScan(expectedRevision: session.header().metadata.revision, operationId: "fixture")
        for start in stride(from: 0, to: count, by: 16) {
            let groups = (start..<min(start + 16, count)).map { index in
                let a = member("\(index)-a.jpg"), b = member("\(index)-b.jpg")
                return CoreReviewGroup(preferred: a.id, members: [a, b],
                    duplicates: [CoreReviewDuplicate(asset: b.id, kind: .exactDuplicate)], edges: nil, sides: nil,
                    scene: nil, recommendation: nil, hasQualityRecommendation: true, sceneRecommendationReason: nil,
                    sceneQuality: [], sceneMatches: [], evidence: [])
            }
            try session.appendScanGroups(operationId: "fixture", groups: groups, cancellation: CancellationHandle())
        }
        _ = try session.finishScan(operationId: "fixture", cancellation: CancellationHandle())
        for start in stride(from: 0, to: count, by: 256) {
            for summary in try session.queryPage(offset: UInt64(start), limit: 256) {
                _ = try session.applyIntent(expectedRevision: session.header().metadata.revision,
                    signature: summary.signature, commandId: "initial-\(summary.ordinal)", intent: .confirmKeep(keep: summary.preferred))
            }
        }
        let prepared = try session.header()
        precondition(prepared.metadata.decisionCount == UInt64(count))
        var revision = prepared.metadata.revision
        for (index, summary) in try session.queryPage(offset: 0, limit: 5).enumerated() {
            positions.append(try milliseconds {
                try session.savePosition(expectedRevision: revision, sequence: UInt64(index + 1),
                    anchor: summary.signature, position: UInt64(index))
            })
            decisions.append(try milliseconds {
                let committed = try session.applyIntent(expectedRevision: revision,
                    signature: summary.signature, commandId: "defer-\(index)", intent: .setStatus(status: .deferred))
                revision = committed.metadata.revision
            })
            changed.append(summary.signature)
        }
    }
    do {
        let reopened = try RustReviewSession(databasePath: url.path, initialized: true)
        let header = try reopened.header()
        precondition(header.metadata.decisionCount == UInt64(count))
        for signature in changed {
            let detail = try reopened.groupDetail(signature: signature)
            precondition(detail.decision?.status == .deferred)
        }
        let anchor = try reopened.resumeSignature()
        precondition(anchor == changed.last)
    }
    var afterClose: [UInt64] = []
    var allocatedAfterClose: [UInt64] = []
    for _ in 0..<6 {
        try autoreleasepool {
            let session = try RustReviewSession(databasePath: url.path, initialized: true)
            let page = try session.queryPage(offset: 0, limit: 16)
            for index in 0..<128 {
                let detail = try session.groupDetail(signature: page[index % page.count].signature)
                precondition(detail.group.members.count == 2)
            }
        }
        afterClose.append(try residentBytes())
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        allocatedAfterClose.append(UInt64(statistics.size_in_use))
    }
    // Diagnostic only: preserve the six ordinary close samples above. This
    // separates reclaimable allocator pages from live objects, without changing
    // application behavior or the navigation/decision measurements.
    let relieved = malloc_zone_pressure_relief(nil, 0)
    let afterRelief = try residentBytes()
    results.append(["groups": count, "positionMilliseconds": positions, "decisionMilliseconds": decisions,
                    "resident_after_close_bytes": afterClose, "allocated_after_close_bytes": allocatedAfterClose,
                    "allocator_pressure_relief_bytes": relieved, "resident_after_allocator_relief_bytes": afterRelief])
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
