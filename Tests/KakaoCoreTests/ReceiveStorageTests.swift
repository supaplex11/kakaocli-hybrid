import XCTest
import CSQLCipher
@testable import KakaoCore

func scratch() throws -> URL {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch/kakaocli-synthetic-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
func fixtureDB(_ path: String, sql: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
}
func synthetic(_ id: String = "1_2", body: String = "synthetic") throws -> NotificationObservation {
    let data = try PropertyListSerialization.data(fromPropertyList: ["req": ["iden": id, "body": body]], format: .binary, options: 0)
    return try XCTUnwrap(NotificationParser.parse(data))
}
final class ReceiveReaderTests: XCTestCase {
    func testReadOnlyFilteringAndSchema() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("source").path
        let blob = try PropertyListSerialization.data(fromPropertyList: ["req": ["iden": "1_2"]], format: .binary, options: 0).map { String(format: "%02x", $0) }.joined()
        try fixtureDB(path, sql: "CREATE TABLE app(app_id INTEGER, identifier TEXT); CREATE TABLE record(rec_id INTEGER, app_id INTEGER, data BLOB); INSERT INTO app VALUES(1,'com.kakao.KakaoTalkMac'),(2,'other'); INSERT INTO record VALUES(2,1,X'\(blob)'),(1,2,X'\(blob)');")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let reader = try NotificationReader(path: path)
        XCTAssertEqual(try reader.snapshot().observations.count, 1)
        XCTAssertEqual(before, try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertThrowsError(try NotificationReader(path: dir.appendingPathComponent("absent").path))
        let wrong = dir.appendingPathComponent("wrong").path
        try fixtureDB(wrong, sql: "CREATE TABLE unrelated(x)")
        XCTAssertThrowsError(try NotificationReader(path: wrong))
    }
}
final class ReceiveStoreTests: XCTestCase {
    func testRetentionBoundaryIsolationAndReplay() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        let store = try ReceiveStore(path: path)
        let rows = [try synthetic("1_1"), try synthetic("1_2"), try synthetic("1_3"), try synthetic("1_4"), try synthetic("1_5")]
        for account in ["a", "b"] {
            try store.ingest(rows, account: account, source: "fixture", replay: true, now: 0)
            try store.complete(XCTUnwrap(store.claim(account: account, now: 0)), now: 1)
            try store.fail(XCTUnwrap(store.claim(account: account, now: 0)), now: 1, maxAttempts: 1)
        }
        let active = try XCTUnwrap(store.claim(account: "a", now: 0, lease: 1000))
        _ = try XCTUnwrap(store.claim(account: "a", now: 0, lease: 2)) // expired but unacknowledged
        XCTAssertEqual(try store.prune(account: "a", now: 10.999, retention: 10), 0)
        XCTAssertEqual(try store.prune(account: "a", now: 11, retention: 10), 2)
        XCTAssertEqual(try store.deliveryCounts(), ["delivered": 1, "dead_letter": 1, "leased": 2, "pending": 4])
        let db = try ReceiveSQLite(path: path, readOnly: true)
        XCTAssertEqual(try db.rows("SELECT count(*) FROM deliveries WHERE account='a' AND state IN ('delivered','dead_letter')").first?.first, "0")
        let reopened = try ReceiveStore(path: path)
        try reopened.ingest(rows, account: "a", source: "replacement-source", replay: true, now: 12)
        XCTAssertEqual(try reopened.deliveryCounts(), try store.deliveryCounts())
        try reopened.complete(active, now: 12) // retention did not steal the active lease
        try reopened.ingest([try synthetic("1_1", body: "changed")], account: "a", source: "fixture", replay: true, now: 13)
        XCTAssertEqual(try db.rows("SELECT revision FROM deliveries WHERE event_id=?", [ReceiveEvent(account: "a", observation: rows[0], observedAt: Date()).eventId]).first?.first, "2")
        XCTAssertEqual(try reopened.prune(account: "b", now: 11, retention: 10), 2)
        for invalid in [-1.0, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try store.prune(account: "a", now: 20, retention: invalid))
        }
        XCTAssertThrowsError(try store.prune(account: "a", now: .nan, retention: 10))
    }

    func testRetentionMigratesLegacyTerminalConservatively() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        do {
            let store = try ReceiveStore(path: path)
            try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0)
            try store.complete(XCTUnwrap(store.claim(account: "a", now: 0)), now: 1)
        }
        try fixtureDB(path, sql: "ALTER TABLE deliveries DROP COLUMN terminal_at; PRAGMA user_version=1")
        let store = try ReceiveStore(path: path)
        XCTAssertEqual(try store.prune(account: "a", now: 1000, retention: 10), 0)
        XCTAssertEqual(try store.prune(account: "a", now: 1009, retention: 10), 0)
        XCTAssertEqual(try store.prune(account: "a", now: 1010, retention: 10), 1)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 1011)
        XCTAssertNil(try store.claim(account: "a", now: 1011))
    }

    func testZeroRetentionPreservesBaselineAndPending() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ReceiveStore(path: dir.appendingPathComponent("owned/inbox.sqlite").path)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: false, now: 0)
        try store.ingest([try synthetic("1_3"), try synthetic("1_4")], account: "a", source: "fixture", replay: true, now: 1)
        try store.complete(XCTUnwrap(store.claim(account: "a", now: 1)), now: 2)
        XCTAssertEqual(try store.prune(account: "a", now: 2, retention: 0), 1)
        try store.ingest([try synthetic(), try synthetic("1_3"), try synthetic("1_4")], account: "a", source: "fixture", replay: true, now: 3)
        XCTAssertEqual(try store.deliveryCounts(), ["pending": 1])
    }

    func testBaselineReplayReopenAndRevisions() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        let o = try synthetic()
        do {
            let store = try ReceiveStore(path: path)
            try store.ingest([o], account: "a", source: "fixture", replay: false, now: 0)
            XCTAssertNil(try store.claim(account: "a", now: 0))
            try store.ingest([o, try synthetic("1_3")], account: "a", source: "fixture", replay: false, now: 1)
        }
        let store = try ReceiveStore(path: path)
        let c = try XCTUnwrap(store.claim(account: "a", now: 1))
        XCTAssertNil(try store.claim(account: "a", now: 2))
        try store.complete(c, now: 2)
        try store.ingest([o], account: "a", source: "fixture", replay: true, now: 3)
        XCTAssertNil(try store.claim(account: "a", now: 3)) // replay never resurrects baselined observations
        try store.ingest([try synthetic("1_3", body: "updated")], account: "a", source: "fixture", replay: false, now: 4)
        let update = try XCTUnwrap(store.claim(account: "a", now: 4))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: update.payload) as? [String: AnyHashable] != nil, true)
        XCTAssertEqual(update.revision, 2)
        try store.ingest([o], account: "b", source: "fixture", replay: true, now: 4)
        XCTAssertNotNil(try store.claim(account: "b", now: 4))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testBaselineChangeEmitsUpdateAfterReopen() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        do {
            let store = try ReceiveStore(path: path)
            try store.ingest([try synthetic()], account: "a", source: "fixture", replay: false, now: 0)
        }
        let store = try ReceiveStore(path: path)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 1)
        XCTAssertNil(try store.claim(account: "a", now: 1))
        try store.ingest([try synthetic(body: "changed")], account: "a", source: "fixture", replay: false, now: 2)
        let claim = try XCTUnwrap(store.claim(account: "a", now: 2))
        XCTAssertEqual(claim.revision, 2)
        try store.complete(claim, now: 3)
        try store.ingest([try synthetic(body: "changed")], account: "a", source: "fixture", replay: true, now: 4)
        XCTAssertNil(try store.claim(account: "a", now: 4))
    }
    func testVersionOneSchemaAndCorruptRevisionAreChecked() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        let store = try ReceiveStore(path: path)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0)
        try fixtureDB(path, sql: "UPDATE deliveries SET revision='not-a-number'")
        XCTAssertThrowsError(try store.claim(account: "a", now: 0)) { error in
            XCTAssertEqual(String(describing: error), ReceiveError.corruptStore.description)
        }
        XCTAssertEqual(try store.deliveryCounts()["pending"], 1)
        try fixtureDB(path, sql: "UPDATE observations SET revision='not-a-number'")
        XCTAssertThrowsError(try store.ingest([try synthetic(body: "changed")], account: "a", source: "fixture", replay: true, now: 1))
        try fixtureDB(path, sql: "UPDATE observations SET revision=9223372036854775807")
        XCTAssertThrowsError(try store.ingest([try synthetic(body: "changed")], account: "a", source: "fixture", replay: true, now: 1))
        try fixtureDB(path, sql: "ALTER TABLE deliveries RENAME COLUMN payload TO wrong")
        XCTAssertThrowsError(try ReceiveStore(path: path)) { error in
            XCTAssertEqual(String(describing: error), ReceiveError.incompatibleSchema.description)
        }
    }
    func testShutdownReleaseDoesNotExhaustRetries() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ReceiveStore(path: dir.appendingPathComponent("owned/inbox.sqlite").path)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0)
        for _ in 0..<10 {
            let claim = try XCTUnwrap(store.claim(account: "a", now: 1))
            try store.release(claim)
        }
        let claim = try XCTUnwrap(store.claim(account: "a", now: 1))
        try store.fail(claim, now: 2)
        XCTAssertEqual(try store.deliveryCounts()["pending"], 1)
    }
    func testLeaseExpiryStaleAckRetryAndQuarantine() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        let a = try ReceiveStore(path: path), b = try ReceiveStore(path: path)
        try a.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0)
        let old = try XCTUnwrap(a.claim(account: "a", now: 0, lease: 10))
        XCTAssertNil(try b.claim(account: "a", now: 9))
        let fresh = try XCTUnwrap(b.claim(account: "a", now: 11))
        XCTAssertThrowsError(try a.complete(old, now: 11))
        try b.fail(fresh, now: 11, maxAttempts: 2)
        XCTAssertNil(try a.claim(account: "a", now: 1_000))
        XCTAssertEqual(try a.deliveryCounts()["dead_letter"], 1)
    }
    func testRepeatedSourceRowsDoNotOscillate() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ReceiveStore(path: dir.appendingPathComponent("owned/inbox.sqlite").path)
        let rows = [try synthetic(body: "old"), try synthetic(body: "latest")]
        try store.ingest(rows, account: "a", source: "fixture", replay: true, now: 0)
        let claim = try XCTUnwrap(store.claim(account: "a", now: 0))
        try store.complete(claim, now: 1)
        try store.ingest(rows, account: "a", source: "fixture", replay: false, now: 2)
        XCTAssertNil(try store.claim(account: "a", now: 2))
    }
    func testRetryDelayAndExpiredAck() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ReceiveStore(path: dir.appendingPathComponent("owned/inbox.sqlite").path)
        try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0)
        let first = try XCTUnwrap(store.claim(account: "a", now: 0))
        try store.fail(first, now: 1)
        XCTAssertNil(try store.claim(account: "a", now: 2))
        let retry = try XCTUnwrap(store.claim(account: "a", now: 3, lease: 5))
        XCTAssertEqual(first.eventId, retry.eventId)
        XCTAssertEqual(first.payload, retry.payload)
        XCTAssertThrowsError(try store.complete(retry, now: 8))
        let recovered = try XCTUnwrap(store.claim(account: "a", now: 8))
        try store.complete(recovered, now: 9)
        XCTAssertEqual(try store.deliveryCounts()["delivered"], 1)
    }
    func testUnsafeStoreAndStdout() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try ReceiveStore(path: shared.appendingPathComponent("inbox").path))
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        XCTAssertThrowsError(try ReceiveStore(path: link.appendingPathComponent("inbox").path))
        let out = dir.appendingPathComponent("output")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        try ReceiveStdout.write(Data("{\"synthetic\":true}".utf8), fd: handle.fileDescriptor)
        try handle.close()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "{\"synthetic\":true}\n")
        XCTAssertThrowsError(try ReceiveStdout.write(Data(), fd: -1))
    }
    func testRollbackAndMigrationGuard() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owned/inbox.sqlite").path
        let store = try ReceiveStore(path: path)
        try fixtureDB(path, sql: "CREATE TRIGGER reject_checkpoint BEFORE INSERT ON checkpoints BEGIN SELECT RAISE(ABORT,'synthetic'); END;")
        XCTAssertThrowsError(try store.ingest([try synthetic()], account: "a", source: "fixture", replay: true, now: 0))
        XCTAssertNil(try store.claim(account: "a", now: 0))
        try fixtureDB(path, sql: "PRAGMA user_version=99")
        XCTAssertThrowsError(try ReceiveStore(path: path))
    }
}
