import Foundation
import Darwin

public struct ReceiveClaim {
    public let eventId: String
    public let revision: Int
    public let payload: Data
    let token: String
}

/// Durable at-least-once stdout outbox. Snapshot identities, not rec_id watermarks,
/// survive record replacement and source row-id reuse. Instances are thread-confined.
public final class ReceiveStore {
    private let db: ReceiveSQLite
    public init(path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Refuse symlink ancestors and shared directories rather than chmod user files.
        var ancestor = parent
        while ancestor.path != "/" {
            var s = stat()
            guard lstat(ancestor.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR else { throw ReceiveError.unsafeStore }
            ancestor.deleteLastPathComponent()
        }
        var p = stat()
        guard lstat(parent.path, &p) == 0, p.st_uid == getuid(), p.st_mode & 0o777 == 0o700 else { throw ReceiveError.unsafeStore }
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if fd >= 0 { Darwin.close(fd) } else if errno != EEXIST { throw ReceiveError.unsafeStore }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var s = stat()
            if lstat(url.path + suffix, &s) == 0 {
                guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & 0o777 == 0o600 else { throw ReceiveError.unsafeStore }
            } else if errno != ENOENT { throw ReceiveError.unsafeStore }
        }
        db = try ReceiveSQLite(path: url.path, readOnly: false)
        try db.transaction {
            let version = try db.rows("PRAGMA user_version").first?.first ?? nil
            guard version == "0" || version == "1" else { throw ReceiveError.incompatibleSchema }
            if version == "0" {
                guard try db.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw ReceiveError.incompatibleSchema }
                try db.exec("CREATE TABLE checkpoints(account TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(account,source))")
                try db.exec("CREATE TABLE observations(event_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, revision INTEGER NOT NULL, baseline INTEGER NOT NULL)")
                try db.exec("CREATE TABLE deliveries(event_id TEXT NOT NULL, revision INTEGER NOT NULL, account TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, available REAL NOT NULL DEFAULT 0, token TEXT, PRIMARY KEY(event_id,revision))")
                try db.exec("PRAGMA user_version=1")
            }
        }
        try validateSchema()
        try db.exec("PRAGMA synchronous=FULL")
    }

    private func validateSchema() throws {
        let expected: [String: [(String, String, String, String)]] = [
            "checkpoints": [("account","TEXT","1","1"),("source","TEXT","1","2")],
            "observations": [("event_id","TEXT","0","1"),("fingerprint","TEXT","1","0"),("revision","INTEGER","1","0"),("baseline","INTEGER","1","0")],
            "deliveries": [("event_id","TEXT","1","1"),("revision","INTEGER","1","2"),("account","TEXT","1","0"),("payload","TEXT","1","0"),("state","TEXT","1","0"),("attempts","INTEGER","1","0"),("available","REAL","1","0"),("token","TEXT","0","0")]
        ]
        for (table, columns) in expected {
            let rows = try db.rows("PRAGMA table_info(\(table))")
            guard rows.count == columns.count else { throw ReceiveError.incompatibleSchema }
            for (row, column) in zip(rows, columns) {
                guard row.count >= 6, row[1] == column.0, row[2] == column.1,
                      row[3] == column.2, row[5] == column.3 else { throw ReceiveError.incompatibleSchema }
            }
        }
    }

    private func positiveRevision(_ value: String?) throws -> Int {
        guard let value, let number = Int(value), number > 0, number < Int.max else { throw ReceiveError.corruptStore }
        return number
    }

    public func ingest(_ observations: [NotificationObservation], account: String, source: String, replay: Bool, now: Double) throws {
        try db.transaction {
            let first = try db.rows("SELECT 1 FROM checkpoints WHERE account=? AND source=?", [account, source]).isEmpty
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // A notification may have several retained records; the reader orders
            // oldest to newest. Only the last observation per identity is current.
            var latest: [String: Int] = [:]
            for (index, observation) in observations.enumerated() {
                latest[observation.chatId + "/" + observation.logId] = index
            }
            for (index, observation) in observations.enumerated() {
                guard latest[observation.chatId + "/" + observation.logId] == index else { continue }
                var event = ReceiveEvent(account: account, observation: observation, observedAt: Date(timeIntervalSince1970: now))
                let fingerprint = ReceiveEvent.digest(String(decoding: try encoder.encode(observation), as: UTF8.self))
                let previous = try db.rows("SELECT fingerprint,revision,baseline FROM observations WHERE event_id=?", [event.eventId]).first
                if let previous {
                    guard previous.count == 3, previous[0] != nil, ["0", "1"].contains(previous[2]) else { throw ReceiveError.corruptStore }
                    event.revision = try positiveRevision(previous[1]) + 1
                    if previous[0] == fingerprint { continue }
                }
                let baseline = previous == nil && first && !replay
                try db.exec("INSERT INTO observations VALUES(?,?,?,?) ON CONFLICT(event_id) DO UPDATE SET fingerprint=excluded.fingerprint, revision=excluded.revision, baseline=excluded.baseline", [event.eventId, fingerprint, String(event.revision), baseline ? "1" : "0"])
                if !baseline {
                    try db.exec("INSERT INTO deliveries(event_id,revision,account,payload) VALUES(?,?,?,?)", [event.eventId, String(event.revision), account, String(decoding: try event.json(), as: UTF8.self)])
                }
            }
            try db.exec("INSERT OR IGNORE INTO checkpoints VALUES(?,?)", [account, source])
        }
    }

    public func claim(account: String, now: Double, lease: Double = 30) throws -> ReceiveClaim? {
        try db.transaction {
            guard let row = try db.rows("SELECT event_id,revision,payload FROM deliveries d WHERE account=? AND state IN ('pending','leased') AND available<=? AND NOT EXISTS (SELECT 1 FROM deliveries older WHERE older.event_id=d.event_id AND older.revision<d.revision AND older.state IN ('pending','leased')) ORDER BY rowid LIMIT 1", [account, String(now)]).first else { return nil }
            guard row.count == 3, let eventId = row[0], !eventId.isEmpty, let payload = row[2],
                  let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  object["event_id"] as? String == eventId,
                  object["account_namespace"] as? String == account else { throw ReceiveError.corruptStore }
            let revision = try positiveRevision(row[1])
            guard object["revision"] as? Int == revision else { throw ReceiveError.corruptStore }
            let token = UUID().uuidString
            try db.exec("UPDATE deliveries SET state='leased',token=?,available=?,attempts=attempts+1 WHERE event_id=? AND revision=?", [token, String(now + lease), row[0], row[1]])
            return ReceiveClaim(eventId: eventId, revision: revision, payload: Data(payload.utf8), token: token)
        }
    }

    /// Cooperative shutdown is not a sink failure and must not consume retry budget.
    public func release(_ claim: ReceiveClaim) throws {
        try db.exec("UPDATE deliveries SET state='pending',token=NULL,available=0,attempts=max(0,attempts-1) WHERE event_id=? AND revision=? AND token=? AND state='leased'", [claim.eventId, String(claim.revision), claim.token])
        guard db.changes == 1 else { throw ReceiveError.staleClaim }
    }

    public func complete(_ claim: ReceiveClaim, now: Double) throws {
        try db.exec("UPDATE deliveries SET state='delivered',token=NULL WHERE event_id=? AND revision=? AND token=? AND state='leased' AND available>?", [claim.eventId, String(claim.revision), claim.token, String(now)])
        guard db.changes == 1 else { throw ReceiveError.staleClaim }
    }

    public func fail(_ claim: ReceiveClaim, now: Double, maxAttempts: Int = 8) throws {
        try db.exec("UPDATE deliveries SET state=CASE WHEN attempts>=? THEN 'dead_letter' ELSE 'pending' END, available=? + min(300,pow(2,attempts)),token=NULL WHERE event_id=? AND revision=? AND token=? AND state='leased' AND available>?", [String(maxAttempts), String(now), claim.eventId, String(claim.revision), claim.token, String(now)])
        guard db.changes == 1 else { throw ReceiveError.staleClaim }
    }

    public func deliveryCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try db.rows("SELECT state,count(*) FROM deliveries GROUP BY state") {
            guard row.count == 2, let state = row[0], let text = row[1], let count = Int(text), count >= 0 else { throw ReceiveError.corruptStore }
            counts[state] = count
        }
        return counts
    }
}
