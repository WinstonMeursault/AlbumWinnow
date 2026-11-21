import Foundation

public enum ScopeError: LocalizedError, Sendable {
    case invalidDateRange, unavailableAlbum, invalidComparison
    public var errorDescription: String? {
        switch self {
        case .invalidDateRange: "Choose a valid capture-date range."
        case .unavailableAlbum: "A selected album is unavailable or renamed. Review Photo Albums and Dates; the scan has not expanded to all photos."
        case .invalidComparison: "Choose two different available sources for cross-side comparison."
        }
    }
}

public struct CaptureRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public var includesUnknown: Bool

    public init(firstDay: Date, lastDay: Date, calendar: Calendar = .current, includesUnknown: Bool = false) throws {
        guard firstDay.timeIntervalSince1970.isFinite, lastDay.timeIntervalSince1970.isFinite else { throw ScopeError.invalidDateRange }
        let start = calendar.startOfDay(for: firstDay)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)), end > start else {
            throw ScopeError.invalidDateRange
        }
        self.start = start
        self.end = end
        self.includesUnknown = includesUnknown
    }

    public func contains(_ date: Date?) throws -> Bool {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else {
            throw ScopeError.invalidDateRange
        }
        guard let date, date.timeIntervalSince1970.isFinite else { return includesUnknown }
        return date >= start && date < end
    }
}

public struct PhotoScope: Codable, Equatable, Sendable {
    // nil means all accessible photos; an empty selection intentionally scans nothing.
    public var albums: [String: String]?
    public var dates: CaptureRange?
    public init() {}
}

public struct ComparisonSides: Codable, Equatable, Sendable {
    public let first: String
    public let second: String
    public init(first: String, second: String) { self.first = first; self.second = second }
    public func permits(_ a: AssetID, _ b: AssetID) -> Bool {
        a != b && ((a.source == first && b.source == second) || (a.source == second && b.source == first))
    }
    public func validate(sources: Set<String>) throws {
        guard first != second, sources.contains(first), sources.contains(second) else { throw ScopeError.invalidComparison }
    }
}

public struct MatchEdge: Codable, Equatable, Sendable {
    public let first: AssetID
    public let second: AssetID
    public let match: DuplicateMatch
    public init(first: AssetID, second: AssetID, match: DuplicateMatch) {
        self.first = first; self.second = second; self.match = match
    }
    public func connects(_ a: AssetID, _ b: AssetID) -> Bool {
        (first == a && second == b) || (first == b && second == a)
    }
}

public extension DuplicateGroup {
    var recommendation: PhotoAsset { assets.first { $0.id == recommendedID } ?? preferred }

    func match(between a: AssetID, and b: AssetID) -> DuplicateMatch? {
        if a == b { return nil }
        if let edges { return edges.first { $0.connects(a, b) }?.match }
        if a == preferred.id { return duplicates.first { $0.id == b }?.match }
        if b == preferred.id { return duplicates.first { $0.id == a }?.match }
        // Byte equality is transitive; approximate matches are not.
        if duplicates.allSatisfy({ $0.match == .exactDuplicate }), assets.contains(where: { $0.id == a }),
           assets.contains(where: { $0.id == b }) { return .exactDuplicate }
        return nil
    }

    func removalPairs(keeping keepID: AssetID, protection: CleanupProtection) -> [CleanupPair] {
        let assets = assets
        guard let selected = assets.first(where: { $0.id == keepID }) else { return [] }
        func protected(_ asset: PhotoAsset) -> Bool {
            asset.photoProperties?.hasAssociatedResources == true || !protection.validateForReview(asset)
        }
        if edges == nil, duplicates.allSatisfy({ $0.match == .exactDuplicate }) {
            return assets.filter { $0.id != keepID && !protected($0) }.map { CleanupPair(keep: selected, remove: $0) }
        }
        let edges = edges ?? duplicates.map { MatchEdge(first: preferred.id, second: $0.id, match: $0.match) }
        var adjacent: [AssetID: [AssetID]] = [:]
        for edge in edges where edge.match != .distinct {
            adjacent[edge.first, default: []].append(edge.second)
            adjacent[edge.second, default: []].append(edge.first)
        }
        var retained = Dictionary(uniqueKeysWithValues: assets.filter { $0.id == keepID || protected($0) }.map { ($0.id, $0) })
        var pairs: [CleanupPair] = []
        for asset in assets where asset.id != keepID && retained[asset.id] == nil {
            if let keep = (adjacent[asset.id] ?? []).lazy.compactMap({ retained[$0] }).first {
                pairs.append(CleanupPair(keep: keep, remove: asset))
            } else { retained[asset.id] = asset }
        }
        return pairs
    }
}
