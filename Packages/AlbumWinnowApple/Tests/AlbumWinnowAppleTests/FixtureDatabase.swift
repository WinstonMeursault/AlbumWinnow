import Foundation
import SQLite3

// Fault injection inspects only disposable test databases; production storage is Rust-owned.
final class FixtureDatabase {
    enum Value { case text(String), blob(Data) }
    private let database: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        database = handle
    }

    deinit { sqlite3_close(database) }

    func execute(_ sql: String, bindings: [Value] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    func integer(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        return sqlite3_column_int64(statement, 0)
    }

    func namedBlobs(_ sql: String) throws -> [(String, Data)] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows = [(String, Data)]()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, let name = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 1) else { throw CocoaError(.fileReadCorruptFile) }
            rows.append((String(cString: name), Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
        }
    }

    private func prepare(_ sql: String, bindings: [Value] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            for (index, value) in bindings.enumerated() {
                let result: Int32
                switch value {
                case .text(let text):
                    result = sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
                case .blob(let data):
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32($0.count), Self.transient)
                    }
                }
                guard result == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }
}
