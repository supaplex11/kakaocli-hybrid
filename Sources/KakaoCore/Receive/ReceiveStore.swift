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
        try db.exec("PRAGMA synchronous=FULL")
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
                if previous?[0] == fingerprint { continue }
                event.revision = previous.flatMap { Int($0[1] ?? "") }.map { $0 + 1 } ?? 1
                let baseline = previous?[2] == "1" || (previous == nil && first && !replay)
                try db.exec("INSERT INTO observations VALUES(?,?,?,?) ON CONFLICT(event_id) DO UPDATE SET fingerprint=excluded.fingerprint, revision=excluded.revision", [event.eventId, fingerprint, String(event.revision), baseline ? "1" : "0"])
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
            let token = UUID().uuidString
            try db.exec("UPDATE deliveries SET state='leased',token=?,available=?,attempts=attempts+1 WHERE event_id=? AND revision=?", [token, String(now + lease), row[0], row[1]])
            return ReceiveClaim(eventId: row[0]!, revision: Int(row[1]!)!, payload: Data(row[2]!.utf8), token: token)
        }
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
        Dictionary(uniqueKeysWithValues: try db.rows("SELECT state,count(*) FROM deliveries GROUP BY state").map { ($0[0]!, Int($0[1]!)!) })
    }
}
