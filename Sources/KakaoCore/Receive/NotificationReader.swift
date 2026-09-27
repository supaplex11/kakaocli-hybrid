// Schema/query behavior adapted from OpenKakao, MIT; see THIRD_PARTY_NOTICES.md.
import Foundation
import CSQLCipher
import Darwin

public struct NotificationSnapshot {
    public let observations: [NotificationObservation]
    public let malformedCount: Int
}

public final class NotificationReader {
    private let db: ReceiveSQLite
    private let query: String
    public let sourceId: String
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        var paths = [home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path]
        // Older macOS: use the current user's Darwin directory, never scan other users' stores.
        let size = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        if size > 0 && size < 8192 {
            var buffer = [CChar](repeating: 0, count: size)
            confstr(_CS_DARWIN_USER_DIR, &buffer, size)
            paths.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "com.apple.notificationcenter/db2/db")
        }
        for path in paths {
            var info = stat()
            if lstat(path, &info) == 0 { return path }
            if errno == EACCES || errno == EPERM { throw ReceiveError.permissionDenied }
        }
        throw ReceiveError.missingSource
    }
    public init(path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == EACCES || errno == EPERM { throw ReceiveError.permissionDenied }
            throw ReceiveError.missingSource
        }
        guard access(path, R_OK) == 0 else { throw ReceiveError.permissionDenied }
        do { db = try ReceiveSQLite(path: path, readOnly: true) }
        catch { throw ReceiveError.permissionDenied }
        let records = Set(try db.rows("PRAGMA table_info(record)").compactMap { $0[1] })
        let apps = Set(try db.rows("PRAGMA table_info(app)").compactMap { $0[1] })
        guard records.isSuperset(of: ["rec_id", "app_id", "data"]), apps.isSuperset(of: ["app_id", "identifier"]) else { throw ReceiveError.incompatibleSchema }
        let dates = ["request_last_date", "request_date", "delivered_date"].filter { records.contains($0) }.map { "r." + $0 }
        let order = dates.isEmpty ? "r.rec_id" : "COALESCE(" + (dates + ["0"]).joined(separator: ",") + "), r.rec_id"
        query = "SELECT r.data FROM record r JOIN app a ON r.app_id=a.app_id WHERE lower(a.identifier)=? AND r.data IS NOT NULL ORDER BY \(order) LIMIT 10001"
        sourceId = "notification:" + ReceiveEvent.digest(URL(fileURLWithPath: path).standardized.path)
    }
    public func snapshot() throws -> NotificationSnapshot {
        // Bounds even hostile/huge schemas, sorting and scans; busy timeout separately bounds locks.
        var deadline = ProcessInfo.processInfo.systemUptime + 2
        return try withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(db.handle, 1000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db.handle, query, -1, &stmt, nil)
            guard rc == SQLITE_OK else { throw ReceiveError.database(rc) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, "com.kakao.kakaotalkmac", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var observations = [NotificationObservation](), malformed = 0, count = 0, bytes = 0
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw ReceiveError.database(step) }
                count += 1
                let length = Int(sqlite3_column_bytes(stmt, 0)); bytes += length
                guard count <= 10000, bytes <= 32 * 1024 * 1024 else { throw ReceiveError.sourceLimit }
                guard length <= 1_048_576, let blob = sqlite3_column_blob(stmt, 0) else { malformed += 1; continue }
                if let o = NotificationParser.parse(Data(bytes: blob, count: length)) { observations.append(o) }
                else { malformed += 1 }
            }
            return NotificationSnapshot(observations: observations, malformedCount: malformed)
        }
    }
}
