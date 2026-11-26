import AlbumWinnowApple
import AlbumWinnowRust
import Darwin
import Foundation

private enum BenchmarkError: Error { case invalid(String) }

@main
struct Benchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let count = Int(args[2]), count > 0, count.isMultiple(of: 200) else {
            throw BenchmarkError.invalid("Usage: ScanBenchmark DATASET_ROOT COUNT OUTPUT_JSON")
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let output = URL(fileURLWithPath: args[3])
        let fm = FileManager.default
        let state = root.appending(path: "run-\(count)", directoryHint: .isDirectory)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let reviewURL = state.appending(path: "review-v2.sqlite")
        let review = try RustReviewSession(databasePath: reviewURL.path, initialized: fm.fileExists(atPath: reviewURL.path))
        let directory = root.appending(path: "photos")
        let sourceRecord = try review.registerSource(expectedRevision: review.header().metadata.revision,
            input: CoreSourceInput(kind: .fileSystem, namespace: FileSystemSource.sourceIdentityNamespace,
                identity: try FileSystemSource.sourceIdentity(directory: directory), bookmark: Data(), label: "Benchmark"))
        let source = FileSystemSource(directory: directory, id: sourceRecord.id)
        let native = try AppleAssetSources(sources: [source], registered: [sourceRecord])
        let cache = state.appending(path: "scan.sqlite")
        var metrics = [[String: Any]]()
        var cancellationToDrainSeconds: Double?

        func record(_ phase: String, start: Date, result: AppleScanReceipt, cache: URL) throws {
            guard result.issues.isEmpty, result.cacheMaintenance == .completed, result.scanned + result.reused == count,
                  result.unavailableSources.isEmpty, try review.queryCount() == UInt64(count / 20) else {
                throw BenchmarkError.invalid("Incorrect result in \(phase): \(result.issues.count) issues")
            }
            var actual = Set<[String]>()
            var offset: UInt64 = 0
            while true {
                let page = try review.queryPage(offset: offset, limit: 256)
                for summary in page {
                    let group = try review.groupDetail(signature: summary.signature).group
                    guard group.members.count == 2, summary.kind == .exactDuplicate else {
                        throw BenchmarkError.invalid("Unexpected group in \(phase)")
                    }
                    actual.insert(group.members.map(\.name).sorted())
                }
                offset += UInt64(page.count)
                if page.count < 256 { break }
            }
            let expected = Set(stride(from: 0, to: count, by: 20).map {
                [String(format: "asset-%06d.jpg", $0), String(format: "asset-%06d.jpg", $0 + 1)]
            })
            guard actual == expected else { throw BenchmarkError.invalid("Label mismatch in \(phase)") }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let bytes = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
                sum + ((try? fm.attributesOfItem(atPath: cache.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            var entry: [String: Any] = ["phase": phase, "seconds": Date().timeIntervalSince(start),
                "process_peak_rss_bytes": usage.ru_maxrss, "cache_bytes": bytes, "scanned": result.scanned,
                "reused": result.reused, "groups": actual.count, "issues": result.issues.count]
            entry["resident_bytes"] = try residentBytes()
            if let cancellationToDrainSeconds { entry["cancellation_to_drain_seconds"] = cancellationToDrainSeconds }
            metrics.append(entry)
            print(String(data: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
            try JSONSerialization.data(withJSONObject: ["count": count, "phases": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }

        let originals = state.appending(path: "originals", directoryHint: .isDirectory)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        var replacements = [(URL, URL)]()
        defer {
            for (target, backup) in replacements {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: backup, to: target)
            }
        }
        var start = Date()
        do {
            let engine = try ScanEngine(cacheURL: cache)
            let cold = try await engine.scan(native, review: review)
            guard cold.scanned == count, cold.reused == 0 else { throw BenchmarkError.invalid("Cold cache was not empty") }
            try record("cold", start: start, result: cold, cache: cache)
            start = Date()
            let warm = try await engine.scan(native, review: review)
            guard warm.scanned == 0, warm.reused == count else { throw BenchmarkError.invalid("Cache reuse failed") }
            try record("unchanged", start: start, result: warm, cache: cache)

            for pair in 0..<(count / 200) {
                for offset in 0...1 {
                    let name = String(format: "asset-%06d.jpg", pair * 20 + offset)
                    let target = source.directory.appending(path: name)
                    let backup = originals.appending(path: name)
                    try fm.copyItem(at: target, to: backup)
                    replacements.append((target, backup))
                    try fm.removeItem(at: target)
                    try fm.copyItem(at: root.appending(path: String(format: "edits/edit-%06d.jpg", pair)), to: target)
                }
            }
            start = Date()
            let changed = try await engine.scan(native, review: review)
            guard changed.scanned == count / 100, changed.reused == count - count / 100 else {
                throw BenchmarkError.invalid("Changed files did not invalidate fingerprints")
            }
            try record("changed_one_percent", start: start, result: changed, cache: cache)
        }
        // Metrics are already saved; keep only one full-size cache on disk.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: cache.path + suffix)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }

        let recoveryCache = state.appending(path: "recovery.sqlite")
        // Each measurement needs a cold interruption cache, including repeated runs.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: recoveryCache.path + suffix)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        let recovery = try ScanEngine(cacheURL: recoveryCache)
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let threshold = min(1024, count / 2)
        let interrupted = Task {
            defer { continuation.finish() }
            return try await recovery.scan(native, review: review) { continuation.yield($0) }
        }
        var cancellationStarted: Date?
        for await update in updates {
            if case .fingerprinting(let done, _) = update, done >= threshold {
                cancellationStarted = Date()
                interrupted.cancel()
                break
            }
        }
        do {
            _ = try await interrupted.value
            throw BenchmarkError.invalid("Cancellation did not interrupt scan")
        } catch is CancellationError { }
        guard let cancellationStarted else { throw BenchmarkError.invalid("Cancellation threshold was never reached") }
        cancellationToDrainSeconds = Date().timeIntervalSince(cancellationStarted)
        continuation.finish()
        start = Date()
        let resumed = try await recovery.scan(native, review: review)
        guard resumed.reused >= threshold, resumed.scanned > 0 else { throw BenchmarkError.invalid("Interrupted cache was not reused") }
        try record("resume_after_cancellation", start: start, result: resumed, cache: recoveryCache)
    }

    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw BenchmarkError.invalid("Resident memory measurement failed: \(status)") }
        return UInt64(info.resident_size)
    }
}
