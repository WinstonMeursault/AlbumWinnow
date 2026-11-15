import Foundation
import GRDB

struct CleanupJournal: Sendable {
    private let database: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("cleanupJournal") { db in
            try db.create(table: "runs") { table in
                table.column("id", .text).primaryKey()
                table.column("started", .double).notNull()
            }
            try db.create(table: "items", options: .withoutRowID) { table in
                table.column("runID", .text).notNull().references("runs", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("pair", .blob).notNull()
                table.column("status", .text).notNull()
                table.column("detail", .text)
                table.primaryKey(["runID", "position"])
            }
        }
        try migrator.migrate(database)
    }

    func begin(_ pairs: [CleanupPair], id: UUID, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO runs (id, started) VALUES (?, ?)",
                           arguments: [id.uuidString, date.timeIntervalSinceReferenceDate])
            let insert = try db.cachedStatement(sql: "INSERT INTO items (runID, position, pair, status) VALUES (?, ?, ?, ?)")
            let encoder = JSONEncoder()
            for (position, pair) in pairs.enumerated() {
                try insert.execute(arguments: [id.uuidString, position, try encoder.encode(pair), CleanupStatus.pending.rawValue])
            }
        }
    }

    func record(_ entries: [(Int, CleanupItem)], run: UUID) throws {
        try database.write { db in
            let update = try db.cachedStatement(sql: "UPDATE items SET status = ?, detail = ? WHERE runID = ? AND position = ?")
            for (position, item) in entries {
                try update.execute(arguments: [item.status.rawValue, item.detail, run.uuidString, position])
            }
        }
    }

    func recentRuns(limit: Int) throws -> [CleanupRun] {
        try database.read { db in
            let recent = try Row.fetchAll(db, sql: "SELECT id, started FROM runs ORDER BY started DESC LIMIT ?", arguments: [limit])
            let decoder = JSONDecoder()
            return try recent.map { run in
                let id: String = run["id"]
                let started: Double = run["started"]
                guard let uuid = UUID(uuidString: id) else { throw CocoaError(.fileReadCorruptFile) }
                let rows = try Row.fetchAll(db, sql: "SELECT pair, status, detail FROM items WHERE runID = ? ORDER BY position",
                                            arguments: [id])
                let items = try rows.map { row in
                    let pair = try decoder.decode(CleanupPair.self, from: row["pair"])
                    guard let status = CleanupStatus(rawValue: row["status"]) else { throw CocoaError(.fileReadCorruptFile) }
                    return CleanupItem(pair: pair, status: status, detail: row["detail"])
                }
                return CleanupRun(id: uuid, startedAt: Date(timeIntervalSinceReferenceDate: started), items: items)
            }
        }
    }
}
