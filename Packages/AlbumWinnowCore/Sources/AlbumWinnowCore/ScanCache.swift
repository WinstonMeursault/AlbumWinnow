import Foundation
import GRDB

struct ScanCache: Sendable {
    private static let fingerprintVersion = 2
    private let database: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try DatabaseQueue(path: url.path)
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
        try migrator.migrate(database)
    }

    func signatures(source: String) throws -> [String: (revision: String, signature: ImageFingerprint)] {
        try database.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT item, revision, signature FROM fingerprints WHERE source = ? AND version = ?
                """, arguments: [source, Self.fingerprintVersion])
            let decoder = JSONDecoder()
            var signatures: [String: (String, ImageFingerprint)] = [:]
            while let row = try rows.next() {
                let signature: Data = row["signature"]
                signatures[row["item"]] = (row["revision"], try decoder.decode(ImageFingerprint.self, from: signature))
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

    func finish(_ result: ScanResult, assetIDs: Set<AssetID>, sources: [String]) throws {
        let encode = JSONEncoder()
        let encoded = try encode.encode(result)
        let scope = try encode.encode(sources.sorted())
        try database.write { db in
            let delete = try db.cachedStatement(sql: "DELETE FROM fingerprints WHERE source = ? AND item = ?")
            for source in sources {
                let cachedIDs = try String.fetchAll(db, sql: "SELECT item FROM fingerprints WHERE source = ?", arguments: [source])
                for item in cachedIDs where !assetIDs.contains(AssetID(source: source, item: item)) {
                    try delete.execute(arguments: [source, item])
                }
            }
            try db.execute(sql: """
                INSERT INTO scans (scope, version, result) VALUES (?, ?, ?)
                ON CONFLICT (scope) DO UPDATE SET version = excluded.version, result = excluded.result
                """, arguments: [scope, Self.fingerprintVersion, encoded])
        }
    }

    func lastResult(sources: [String]) throws -> ScanResult? {
        let scope = try JSONEncoder().encode(sources.sorted())
        return try database.read { db in
            let data = try Data.fetchOne(db, sql: "SELECT result FROM scans WHERE scope = ? AND version = ?",
                                        arguments: [scope, Self.fingerprintVersion])
            return try data.map { try JSONDecoder().decode(ScanResult.self, from: $0) }
        }
    }
}
