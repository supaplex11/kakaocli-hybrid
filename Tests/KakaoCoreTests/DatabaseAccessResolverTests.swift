import XCTest
import CSQLCipher
@testable import KakaoCore

final class DatabaseAccessResolverTests: XCTestCase {
    private let uuid = "00000000-0000-0000-0000-000000000001"
    private func fixture(key: String? = nil, userId: Int = 42) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("synthetic.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        if let key {
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA key='\(key.replacingOccurrences(of: "'", with: "''"))'; PRAGMA cipher_compatibility=3", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE NTChatContext(userId INTEGER); INSERT INTO NTChatContext VALUES (\(userId)); CREATE TABLE NTChatRoom(chatId INTEGER); CREATE TABLE NTChatMessage(logId INTEGER)", nil, nil, nil), SQLITE_OK)
        return url
    }
    private func resolver(ids: [Int] = []) -> DatabaseAccessResolver {
        DatabaseAccessResolver(environment: .init(platformUUID: { self.uuid }, candidateUserIds: { ids }, containerPath: { "/nonexistent-synthetic-container" }))
    }
    func testConfiguredIDDerivesAndValidates() throws {
        let key = KeyDerivation.secureKey(userId: 42, uuid: uuid)
        let url = try fixture(key: key)
        let before = try Data(contentsOf: url)
        let access = try resolver().resolve(.init(databasePath: url.path, userId: 42))
        XCTAssertEqual(access.userId, 42)
        XCTAssertFalse(String(describing: access).contains(key))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testWrongAccountFailsClosedEvenWithWorkingKey() throws {
        let url = try fixture(key: "synthetic-secret")
        XCTAssertThrowsError(try resolver(ids: [42]).resolve(.init(databasePath: url.path, key: "synthetic-secret", userId: 99))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .accountMismatch)
        }
    }
    func testBadKeyAndUnreadableAreSeparateAndRedacted() throws {
        let url = try fixture(key: "synthetic-secret")
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: url.path, key: "wrong-secret"))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .invalidKeyOrDatabase)
            XCTAssertFalse(String(describing: $0).contains("wrong-secret"))
            XCTAssertFalse(String(describing: $0).contains(url.path))
        }
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: "/missing-synthetic-db", key: "secret"))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .unreadableDatabase)
        }
    }
    func testMissingIDAndExpiredDeadline() throws {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try resolver().resolve(.init())) {
            XCTAssertEqual($0 as? DatabaseAccessError, .missingUserId)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        XCTAssertThrowsError(try resolver().resolve(.init(timeout: 0))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .deadlineExceeded)
        }
    }
    func testExplicitPlaintextCompatibilityAndInvalidID() throws {
        let url = try fixture()
        XCTAssertEqual(try resolver().resolve(.init(databasePath: url.path)).userId, 42)
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: url.path, userId: -1))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .invalidConfiguration)
        }
    }
    func testProtectedConfigAndPermissions() throws {
        let db = try fixture(key: "synthetic'quoted-key")
        let config = db.deletingLastPathComponent().appendingPathComponent("access.json")
        let data = try JSONSerialization.data(withJSONObject: ["databasePath": db.path, "userId": 42, "key": "synthetic'quoted-key"])
        try data.write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        XCTAssertEqual(try resolver().resolve(.init(configPath: config.path)).userId, 42)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        XCTAssertThrowsError(try resolver().resolve(.init(configPath: config.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .unsafeConfiguration)
        }
    }
    func testNoDiscoveryForExplicitCredentialsAndWrongDerivedID() throws {
        let key = KeyDerivation.secureKey(userId: 42, uuid: uuid)
        let url = try fixture(key: key)
        let isolated = DatabaseAccessResolver(environment: .init(platformUUID: {
            XCTFail("Explicit DB/key must not inspect device identity")
            return self.uuid
        }, candidateUserIds: {
            XCTFail("Explicit DB/key must not read preferences or auth cache")
            return []
        }, containerPath: {
            XCTFail("Explicit DB/key must not inspect container")
            return ""
        }))
        XCTAssertEqual(try isolated.resolve(.init(databasePath: url.path, key: key)).userId, 42)
        XCTAssertThrowsError(try resolver(ids: [42]).resolve(.init(databasePath: url.path, userId: 99))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .invalidKeyOrDatabase)
        }
    }
    func testInjectedDeadlineAndCandidateCap() throws {
        var time: TimeInterval = 0
        var pathsChecked = 0
        let bounded = DatabaseAccessResolver(environment: .init(platformUUID: { self.uuid },
            candidateUserIds: { Array(1...100) }, containerPath: {
                pathsChecked += 1
                return "/missing-synthetic-container"
            }, now: { time }))
        XCTAssertThrowsError(try bounded.resolve())
        XCTAssertEqual(pathsChecked, 8)
        let expired = DatabaseAccessResolver(environment: .init(platformUUID: { self.uuid },
            candidateUserIds: { time = 3; return [42] }, containerPath: {
                XCTFail("Discovery must stop at deadline")
                return ""
            }, now: { time }))
        time = 0
        XCTAssertThrowsError(try expired.resolve(.init(timeout: 2))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .deadlineExceeded)
        }
    }
    func testSchemaAndAmbiguousAccountFailClosed() throws {
        let url = try fixture()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO NTChatContext VALUES(99)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: url.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .incompatibleSchema)
        }
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM NTChatContext WHERE userId=99; DROP TABLE NTChatRoom", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: url.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .incompatibleSchema)
        }
    }
    func testSQLValidationDeadlineInterruptsExpensiveSource() throws {
        let url = try fixture()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE NTChatContext; CREATE VIEW NTChatContext AS WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT 42 AS userId FROM n", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try resolver().resolve(.init(databasePath: url.path, timeout: 0.02))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .deadlineExceeded)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }
    func testUnsafeAndMalformedConfigRedaction() throws {
        let db = try fixture()
        let config = db.deletingLastPathComponent().appendingPathComponent("access.json")
        try Data("invalid-secret-content".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        XCTAssertThrowsError(try resolver().resolve(.init(configPath: config.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .invalidConfiguration)
            XCTAssertFalse(String(describing: $0).contains("invalid-secret-content"))
        }
        let link = config.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertThrowsError(try resolver().resolve(.init(configPath: link.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .unsafeConfiguration)
        }
        XCTAssertFalse(String(reflecting: DatabaseAccessRequest(key: "raw-secret")).contains("raw-secret"))
    }
    func testConfigOverrideAndFinalHandleValidation() throws {
        let db = try fixture(key: "synthetic-key")
        let config = db.deletingLastPathComponent().appendingPathComponent("access.json")
        try JSONSerialization.data(withJSONObject: ["databasePath": db.path, "userId": 99, "key": "synthetic-key"])
            .write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let reader = try resolver().open(.init(userId: 42, configPath: config.path))
        defer { reader.close() }
        XCTAssertEqual(try reader.validatedUserId(), 42)
        XCTAssertThrowsError(try resolver().open(.init(configPath: config.path))) {
            XCTAssertEqual($0 as? DatabaseAccessError, .accountMismatch)
        }
    }
    func testHashRecoveryDeadlineIsMonotonicAndBounded() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(DeviceInfo.recoverUserIdFromSHA512(hexHash: String(repeating: "a", count: 128), timeout: 0.01))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }
}
