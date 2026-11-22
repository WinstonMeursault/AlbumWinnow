import CryptoKit
import Foundation
import GRDB

public enum ReviewStatus: String, Codable, Sendable, CaseIterable {
    case pending, deferred, confirmed, kept
}

public struct ReviewDecision: Codable, Equatable, Sendable {
    public var sceneAlgorithm: String? = nil
    public var status: ReviewStatus
    public var keepID: AssetID?
    public var removals: Set<AssetID>
    public var deleteAll: Bool
    public var members: [PhotoAsset]?
    public var invalidated: Bool?

    public init(status: ReviewStatus, keepID: AssetID? = nil, removals: Set<AssetID> = [], deleteAll: Bool = false, members: [PhotoAsset]? = nil, sceneAlgorithm: String? = nil) {
        self.sceneAlgorithm = sceneAlgorithm
        self.status = status
        self.keepID = keepID
        self.removals = removals
        self.deleteAll = deleteAll
        self.members = members
        self.invalidated = false
    }
}

public struct ReviewState: Codable, Equatable, Sendable {
    public var decisions: [String: ReviewDecision] = [:]
    public var locked: Set<AssetID> = []
    public var lockedRevisions: [AssetID: String]?
    public var anchor: String?
    public var anchorIndex: Int?
    public var resultQuery: ReviewResultQuery?
    public var scanCancelledByUser: Bool?
    public var similarScenesEnabled: Bool?
    public var photoScope: PhotoScope?
    public var comparisonSides: ComparisonSides?
    public var preferredSource: String?
    public var readOnlySources: Set<String>?
    public var readOnlyRevisions: [AssetID: String]?

    public init() {}

    public mutating func resetProgress() {
        decisions.removeAll()
        anchor = nil
        anchorIndex = nil
    }
}

public struct ReviewStateStore: Sendable {
    private let database: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("reviewStateV1") { db in
            try db.create(table: "review_state") { table in
                table.column("id", .integer).primaryKey()
                table.column("schema", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("reviewStateV2") { db in
            try db.execute(sql: "UPDATE review_state SET schema = 2 WHERE schema = 1")
        }
        try migrator.migrate(database)
    }

    public func load() throws -> ReviewState {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT schema, payload FROM review_state WHERE id = 1") else {
                return ReviewState()
            }
            guard (row["schema"] as Int) == 2 else { throw CleanupError.unavailableProtection }
            let state = try JSONDecoder().decode(ReviewState.self, from: row["payload"] as Data)
            guard state.locked.allSatisfy({ !$0.source.hasPrefix("folder:") || state.lockedRevisions?[$0] != nil }) else {
                throw CleanupError.unavailableProtection
            }
            guard state.readOnlySources?.isEmpty != false || state.readOnlyRevisions != nil else {
                throw CleanupError.unavailableProtection
            }
            guard (state.readOnlyRevisions ?? [:]).values.allSatisfy({ revision in
                let fields = revision.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 7 else { return false }
                return Int32(fields[0]) != nil && UInt64(fields[1]) != nil &&
                    Int64(fields[2]).map { $0 >= 0 } == true && Int64(fields[3]) != nil &&
                    Int64(fields[4]).map { (0..<1_000_000_000).contains($0) } == true && Int64(fields[5]) != nil &&
                    Int64(fields[6]).map { (0..<1_000_000_000).contains($0) } == true
            }) else { throw CleanupError.unavailableProtection }
            return state
        }
    }

    public func save(_ state: ReviewState) throws {
        let payload = try JSONEncoder().encode(state)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO review_state (id, schema, payload) VALUES (1, 2, ?)
                ON CONFLICT (id) DO UPDATE SET payload = excluded.payload
                """, arguments: [payload])
        }
    }
}

public extension DuplicateGroup {
    func reviewSignature() throws -> String {
        struct Member: Encodable { let id: AssetID; let revision: String; let properties: PhotoProperties? }
        struct Edge: Encodable { let ends: [AssetID]; let match: DuplicateMatch }
        struct Evidence: Encodable { let version: Int; let members: [Member]; let edges: [Edge]; let sides: ComparisonSides?; let scene: String? }
        func precedes(_ a: AssetID, _ b: AssetID) -> Bool {
            a.source == b.source ? a.item < b.item : a.source < b.source
        }
        let members = ([preferred] + duplicates.map(\.asset)).sorted { precedes($0.id, $1.id) }
            .map { Member(id: $0.id, revision: $0.revision, properties: $0.photoProperties) }
        let edges = (self.edges ?? duplicates.map { MatchEdge(first: preferred.id, second: $0.id, match: $0.match) }).map { Edge(ends: [$0.first, $0.second].sorted(by: precedes), match: $0.match) }
            .sorted { lhs, rhs in
                if lhs.ends[0] != rhs.ends[0] { return precedes(lhs.ends[0], rhs.ends[0]) }
                return precedes(lhs.ends[1], rhs.ends[1])
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(Evidence(version: comparisonSides == nil ? 1 : 2, members: members, edges: comparisonSides == nil && duplicates.allSatisfy { $0.match == .exactDuplicate } ? [] : edges, sides: comparisonSides, scene: sceneAlgorithm)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
