import Foundation
import CSQLCipher

public enum ReceiveError: Error, CustomStringConvertible {
    case missingSource, permissionDenied, incompatibleSchema, sourceLimit, database(Int32), unsafeStore, staleClaim, sinkFailed
    public var description: String {
        switch self {
        case .missingSource: return "Notification database not found; specify --notification-db."
        case .permissionDenied: return "Notification database is unreadable. Grant Full Disk Access to the invoking terminal/binary in System Settings, then retry. No permissions were changed."
        case .incompatibleSchema: return "Unsupported database schema; checkpoint unchanged."
        case .sourceLimit: return "Notification snapshot exceeds safety limit; checkpoint unchanged."
        case .database(let code): return "Receive SQLite operation failed (code \(code)); no payload or SQL logged."
        case .unsafeStore: return "Receive store must be an owned, private directory (0700), with regular non-symlink files (0600)."
        case .staleClaim: return "Delivery lease no longer belongs to this worker."
        case .sinkFailed: return "Stdout write failed or timed out; delivery not acknowledged."
        }
    }
}

// One instance is confined to a single worker thread. SQLite transactions coordinate processes.
final class ReceiveSQLite {
    var handle: OpaquePointer?
    init(path: String, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw ReceiveError.database(result) }
        sqlite3_busy_timeout(handle, 250)
    }
    deinit { sqlite3_close(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw ReceiveError.database(rc) }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let result: Int32
            if let value { result = sqlite3_bind_text(statement, Int32(i+1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            else { result = sqlite3_bind_null(statement, Int32(i+1)) }
            guard result == SQLITE_OK else { throw ReceiveError.database(result) }
        }
        var output = [[String?]]()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return output }
            guard step == SQLITE_ROW else { throw ReceiveError.database(step) }
            output.append((0..<sqlite3_column_count(statement)).map { col in
                sqlite3_column_text(statement, col).map { String(cString: $0) }
            })
        }
    }
    func exec(_ sql: String, _ values: [String?] = []) throws { _ = try rows(sql, values) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let value = try body(); try exec("COMMIT"); return value }
        catch { try? exec("ROLLBACK"); throw error }
    }
}
