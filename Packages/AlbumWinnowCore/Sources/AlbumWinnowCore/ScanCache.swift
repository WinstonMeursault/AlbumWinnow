import Foundation
import GRDB

struct ScanCache: Sendable {
    private static let fingerprintVersion = 4
    private let database: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            database = try Self.openDatabase(at: url)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            database = try Self.openDatabase(at: url)
        }
    }

    private static func openDatabase(at url: URL) throws -> DatabaseQueue {
        let database = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("scanCache") { db in
            try db.create(table: "fingerprints", options: .withoutRowID) { table in
                table.column("source", .text).notNull()
                table.column("item", .text).notNull()
                table.column("revision", .text).notNull()
                table.column("version", .integer).notNull()
                table.column("signature", .blob).notNull()
                table.column("sample", .blob).notNull()
                table.primaryKey(["source", "item"])
            }
            try db.create(table: "scans") { table in
                table.column("scope", .blob).primaryKey()
                table.column("version", .integer).notNull()
                table.column("result", .blob).notNull()
            }
        }
        migrator.registerMigration("byteIdentityAndBoundedImages") { db in
            try db.execute(sql: "DELETE FROM fingerprints")
            try db.execute(sql: "DELETE FROM scans")
        }
        migrator.registerMigration("fingerprintsOnly") { db in
            try db.drop(table: "scans")
        }
        try migrator.migrate(database)
        return database
    }

    func signatures(source: String) throws -> [String: (revision: String, signature: ImageFingerprint)] {
        try database.write { db in
            var signatures: [String: (String, ImageFingerprint)] = [:]
            var invalid: [String] = []
            do {
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT item, revision, signature, sample FROM fingerprints WHERE source = ? AND version = ?
                    """, arguments: [source, Self.fingerprintVersion])
                let decoder = JSONDecoder()
                while let row = try rows.next() {
                    let item: String = row["item"]
                    let valid = autoreleasepool { () -> ImageFingerprint? in
                        let signature: Data = row["signature"]
                        let sample: Data = row["sample"]
                        guard let value = try? decoder.decode(ImageFingerprint.self, from: signature),
                              value.fileHash.count == 32, value.meanRGBA.count == 4,
                              value.width > 0, value.height > 0, value.width <= 150_000_000 / value.height,
                              (1...64).contains(value.bitDepth), value.edgeDetail.isFinite, value.edgeDetail >= 0,
                              let pixels = try? (sample as NSData).decompressed(using: .lzfse),
                              pixels.length == PreparedImage.comparisonSize * PreparedImage.comparisonSize * 4 else {
                            return nil
                        }
                        return value
                    }
                    if let valid {
                        signatures[item] = (row["revision"], valid)
                    } else {
                        invalid.append(item)
                    }
                }
            }
            for item in invalid {
                try db.execute(sql: "DELETE FROM fingerprints WHERE source = ? AND item = ?", arguments: [source, item])
            }
            return signatures
        }
    }

    func sample(for asset: PhotoAsset) throws -> [UInt8] {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: """
                SELECT sample FROM fingerprints WHERE source = ? AND item = ? AND revision = ? AND version = ?
                """, arguments: [asset.id.source, asset.id.item, asset.revision, Self.fingerprintVersion]) else {
                throw AssetAccessError.changedDuringScan
            }
            let pixels = try (data as NSData).decompressed(using: .lzfse) as Data
            let size = PreparedImage.comparisonSize
            guard pixels.count == size * size * 4 else { throw ImageReadError.unreadableImage }
            return Array(pixels)
        }
    }

    func store(_ prepared: [(PhotoAsset, PreparedImage)]) throws {
        let encoder = JSONEncoder()
        let encoded = try prepared.map { asset, image in
            let signature = try encoder.encode(image.fingerprint)
            let sample = try (Data(image.comparisonPixels) as NSData).compressed(using: .lzfse) as Data
            return (asset, signature, sample)
        }
        try database.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO fingerprints (source, item, revision, version, signature, sample) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (source, item) DO UPDATE SET revision = excluded.revision,
                    version = excluded.version, signature = excluded.signature, sample = excluded.sample
                """)
            for (asset, signature, sample) in encoded {
                try statement.execute(arguments: [
                    asset.id.source, asset.id.item, asset.revision, Self.fingerprintVersion, signature, sample,
                ])
            }
        }
    }

    func finish(assetIDs: Set<AssetID>, sources: [String]) throws {
        try database.write { db in
            let placeholders = sources.map { _ in "?" }.joined(separator: ",")
            if sources.isEmpty {
                try db.execute(sql: "DELETE FROM fingerprints")
            } else {
                try db.execute(sql: "DELETE FROM fingerprints WHERE source NOT IN (\(placeholders))",
                               arguments: StatementArguments(sources))
            }
            let delete = try db.cachedStatement(sql: "DELETE FROM fingerprints WHERE source = ? AND item = ?")
            for source in sources {
                let cachedIDs = try String.fetchAll(db, sql: "SELECT item FROM fingerprints WHERE source = ?", arguments: [source])
                for item in cachedIDs where !assetIDs.contains(AssetID(source: source, item: item)) {
                    try delete.execute(arguments: [source, item])
                }
            }
        }
    }

    func clear() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM fingerprints") }
        try database.vacuum()
    }
}
