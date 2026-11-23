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
        migrator.registerMigration("reviewStateV3") { db in
            try db.execute(sql: "CREATE TABLE review_decisions (signature TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE review_position (id INTEGER PRIMARY KEY, anchor TEXT, position INTEGER)")
            if let row = try Row.fetchOne(db, sql: "SELECT schema, payload FROM review_state WHERE id = 1") {
                guard (row["schema"] as Int) == 2 else { throw CleanupError.unavailableProtection }
                var state = try JSONDecoder().decode(ReviewState.self, from: row["payload"] as Data)
                try Self.validate(state)
                for (signature, decision) in state.decisions {
                    try db.execute(sql: "INSERT INTO review_decisions VALUES (?, ?)", arguments: [signature, try JSONEncoder().encode(decision)])
                }
                state.decisions = [:]
                try db.execute(sql: "UPDATE review_state SET schema = 3, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
            }
        }
        try migrator.migrate(database)
    }

    public func load() throws -> ReviewState {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT schema, payload FROM review_state WHERE id = 1") else {
                return ReviewState()
            }
            guard (row["schema"] as Int) == 3 else { throw CleanupError.unavailableProtection }
            var state = try JSONDecoder().decode(ReviewState.self, from: row["payload"] as Data)
            try Self.validate(state)
            for row in try Row.fetchAll(db, sql: "SELECT signature, payload FROM review_decisions") {
                state.decisions[row["signature"]] = try JSONDecoder().decode(ReviewDecision.self, from: row["payload"] as Data)
            }
            if let position = try Row.fetchOne(db, sql: "SELECT anchor, position FROM review_position WHERE id = 1") {
                state.anchor = position["anchor"]
                state.anchorIndex = position["position"]
            }
            return state
        }
    }

    private static func validate(_ state: ReviewState) throws {
        guard state.locked.allSatisfy({ id in
            !id.source.hasPrefix("folder:") || state.lockedRevisions?[id].map(FileSystemSource.isValidRevision) == true
        }), state.readOnlySources?.isEmpty != false || state.readOnlyRevisions != nil,
        (state.readOnlyRevisions ?? [:]).values.allSatisfy(FileSystemSource.isValidRevision) else {
            throw CleanupError.unavailableProtection
        }
    }

    // previous is the caller's last committed snapshot. Omitting it replaces all decisions.
    public func save(_ state: ReviewState, replacing previous: ReviewState? = nil) throws {
        try Self.validate(state)
        var metadata = state
        metadata.decisions = [:]
        let payload = try JSONEncoder().encode(metadata)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO review_state (id, schema, payload) VALUES (1, 3, ?)
                ON CONFLICT (id) DO UPDATE SET schema = excluded.schema, payload = excluded.payload
                """, arguments: [payload])
            if let previous {
                for signature in previous.decisions.keys where state.decisions[signature] == nil {
                    try db.execute(sql: "DELETE FROM review_decisions WHERE signature = ?", arguments: [signature])
                }
            } else {
                try db.execute(sql: "DELETE FROM review_decisions")
            }
            for (signature, decision) in state.decisions where previous?.decisions[signature] != decision {
                try db.execute(sql: "INSERT OR REPLACE INTO review_decisions VALUES (?, ?)", arguments: [signature, try JSONEncoder().encode(decision)])
            }
            try db.execute(sql: "DELETE FROM review_position")
        }
    }

    public func savePosition(anchor: String, index: Int?) throws {
        try database.write { db in
            // A position cannot create or repair a missing/corrupt protection state.
            guard let row = try Row.fetchOne(db, sql: "SELECT schema FROM review_state WHERE id = 1"),
                  (row["schema"] as Int) == 3 else { throw CleanupError.unavailableProtection }
            try db.execute(sql: "INSERT OR REPLACE INTO review_position VALUES (1, ?, ?)", arguments: [anchor, index])
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
        return SHA256.hash(data: try encoder.encode(Evidence(version: DuplicateDetector.reviewSignatureVersion + (comparisonSides == nil ? 0 : 1), members: members, edges: comparisonSides == nil && duplicates.allSatisfy { $0.match == .exactDuplicate } ? [] : edges, sides: comparisonSides, scene: sceneAlgorithm)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
