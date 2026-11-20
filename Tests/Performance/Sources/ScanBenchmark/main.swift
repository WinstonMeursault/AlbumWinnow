import AlbumWinnowCore
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
        let source = FileSystemSource(directory: root.appending(path: "photos"))
        let cache = state.appending(path: "scan.sqlite")
        var metrics = [[String: Any]]()

        func record(_ phase: String, start: Date, result: ScanResult, cache: URL) throws {
            guard result.issues.isEmpty, result.scanned + result.reused == count,
                  result.groups.count == count / 20 else {
                throw BenchmarkError.invalid("Incorrect result in \(phase): \(result.groups.count) groups, \(result.issues.count) issues")
            }
            var actual = Set<[String]>()
            for group in result.groups {
                guard group.duplicates.count == 1, group.match == .exactDuplicate else {
                    throw BenchmarkError.invalid("Unexpected group in \(phase)")
                }
                actual.insert(([group.preferred.name] + group.duplicates.map { $0.asset.name }).sorted())
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
            let entry: [String: Any] = ["phase": phase, "seconds": Date().timeIntervalSince(start),
                "process_peak_rss_bytes": usage.ru_maxrss, "cache_bytes": bytes, "scanned": result.scanned,
                "reused": result.reused, "groups": result.groups.count, "issues": result.issues.count]
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
            let cold = try await engine.scan([source])
            guard cold.scanned == count, cold.reused == 0 else { throw BenchmarkError.invalid("Cold cache was not empty") }
            try record("cold", start: start, result: cold, cache: cache)
            start = Date()
            let warm = try await engine.scan([source])
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
            let changed = try await engine.scan([source])
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
        let recovery = try ScanEngine(cacheURL: recoveryCache)
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let threshold = min(1024, count / 2)
        let interrupted = Task {
            defer { continuation.finish() }
            return try await recovery.scan([source]) { continuation.yield($0) }
        }
        for await update in updates {
            if case .fingerprinting(let done, _) = update, done >= threshold {
                interrupted.cancel()
                break
            }
        }
        do {
            _ = try await interrupted.value
            throw BenchmarkError.invalid("Cancellation did not interrupt scan")
        } catch is CancellationError { }
        continuation.finish()
        start = Date()
        let resumed = try await recovery.scan([source])
        guard resumed.reused >= threshold, resumed.scanned > 0 else { throw BenchmarkError.invalid("Interrupted cache was not reused") }
        try record("resume_after_cancellation", start: start, result: resumed, cache: recoveryCache)
    }
}
