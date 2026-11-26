import AlbumWinnowRust
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
        do {
            return try coreCaptureRangeContains(range: CoreCaptureRange(start: start.timeIntervalSince1970,
                end: end.timeIntervalSince1970, includesUnknown: includesUnknown),
                date: date.flatMap { $0.timeIntervalSince1970.isFinite ? $0.timeIntervalSince1970 : nil })
        } catch { throw ScopeError.invalidDateRange }
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
