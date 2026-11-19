import Foundation

struct CandidateIndex {
    private var files: [Data: [Int]] = [:]
    private let perceptual: HammingBuckets
    private let difference: HammingBuckets

    init(_ fingerprints: [ImageFingerprint]) {
        for (index, value) in fingerprints.enumerated() {
            files[value.fileHash, default: []].append(index)
        }
        perceptual = HammingBuckets(hashes: fingerprints.map(\.perceptualHash), radius: DuplicateDetector.perceptualRadius)
        difference = HammingBuckets(hashes: fingerprints.map(\.differenceHash), radius: DuplicateDetector.differenceRadius)
    }

    func candidates(for fingerprint: ImageFingerprint, after index: Int) -> [Int] {
        var matches = Set<Int>()
        matches.formUnion((files[fingerprint.fileHash] ?? []).lazy.filter { $0 > index })
        perceptual.collect(fingerprint.perceptualHash, after: index, into: &matches)
        difference.collect(fingerprint.differenceHash, after: index, into: &matches)
        return matches.sorted()
    }
}

private struct HammingBuckets {
    private static let flipMasks: [[UInt16]] = (0...3).map { radius in
        (0...UInt16.max).filter { $0.nonzeroBitCount <= radius }
    }
    private let hashes: [UInt64]
    private let radius: Int
    private var buckets = [[UInt16: [Int]]](repeating: [:], count: 4)

    init(hashes: [UInt64], radius: Int) {
        self.hashes = hashes
        self.radius = radius
        for (index, hash) in hashes.enumerated() {
            for band in buckets.indices {
                let key = UInt16(truncatingIfNeeded: hash >> (band * 16))
                buckets[band][key, default: []].append(index)
            }
        }
    }

    func collect(_ hash: UInt64, after index: Int, into matches: inout Set<Int>) {
        // Missing every band requires at least radius + 1 differing bits overall.
        let minimumMisses = radius + 1
        for band in buckets.indices {
            let bandRadius = minimumMisses / 4 + (band < minimumMisses % 4 ? 1 : 0) - 1
            let key = UInt16(truncatingIfNeeded: hash >> (band * 16))
            for mask in Self.flipMasks[bandRadius] {
                guard let candidates = buckets[band][key ^ mask] else { continue }
                for candidate in candidates where candidate > index && (hashes[candidate] ^ hash).nonzeroBitCount <= radius {
                    matches.insert(candidate)
                }
            }
        }
    }
}
