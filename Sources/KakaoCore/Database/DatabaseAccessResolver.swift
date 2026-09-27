import Darwin
import Foundation

/// Deliberately payload-free: never wrap SQLite, config decoder or filesystem errors.
public enum DatabaseAccessError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguration, unsafeConfiguration, missingUserId, unreadableDatabase
    case invalidKeyOrDatabase, incompatibleSchema, accountMismatch, deadlineExceeded

    public var description: String {
        switch self {
        case .invalidConfiguration: return "Invalid database access configuration. Use a positive user ID and valid options."
        case .unsafeConfiguration: return "Access config must be an owned, private regular file (0600), not a symlink; maximum 64 KiB."
        case .missingUserId: return "No usable user ID found. Supply --user-id or an explicit protected --access-config; auth caches are never imported."
        case .unreadableDatabase: return "Database is missing or unreadable. Check the selected file and Full Disk Access."
        case .invalidKeyOrDatabase: return "Database could not be decrypted: wrong key, corrupt file, or unsupported cipher."
        case .incompatibleSchema: return "Database lacks the required Kakao schema or a unique positive account ID."
        case .accountMismatch: return "Database account does not match the requested user ID. No fallback was attempted."
        case .deadlineExceeded: return "Database access resolution deadline exceeded. Supply explicit access configuration."
        }
    }
}

public struct DatabaseAccessRequest: CustomStringConvertible {
    public var databasePath: String?
    public var key: String?
    public var userId: Int?
    public var uuid: String?
    public var configPath: String?
    public var timeout: TimeInterval
    public init(databasePath: String? = nil, key: String? = nil, userId: Int? = nil,
                uuid: String? = nil, configPath: String? = nil, timeout: TimeInterval = 2) {
        self.databasePath = databasePath; self.key = key; self.userId = userId
        self.uuid = uuid; self.configPath = configPath; self.timeout = timeout
    }
    public var description: String { "DatabaseAccessRequest(redacted)" }
}

public struct DatabaseAccess: CustomStringConvertible {
    public let databasePath: String
    public let key: String?
    public let userId: Int
    public var description: String { "DatabaseAccess(validated, redacted)" }
}

/// Shared read-only resolver. No login, keychain, auth-cache imports or logging.
/// Deadlines are cooperative: kernel filesystem calls and one native KDF cannot be preempted.
public struct DatabaseAccessResolver {
    public struct Environment {
        public var platformUUID: () throws -> String
        public var candidateUserIds: () throws -> [Int]
        public var containerPath: () -> String
        public var now: () -> TimeInterval
        public init(platformUUID: @escaping () throws -> String = DeviceInfo.platformUUID,
                    candidateUserIds: @escaping () throws -> [Int] = DeviceInfo.detectedUserIds,
                    containerPath: @escaping () -> String = { DeviceInfo.containerPath },
                    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.platformUUID = platformUUID; self.candidateUserIds = candidateUserIds
            self.containerPath = containerPath; self.now = now
        }
    }
    private let environment: Environment
    public init(environment: Environment = .init()) { self.environment = environment }

    private struct Configuration: Decodable {
        let databasePath: String?
        let key: String?
        let userId: Int?
        let uuid: String?
    }

    private func configuration(_ path: String) throws -> Configuration {
        // O_NONBLOCK avoids hanging on a FIFO; fstat validates the opened inode, not a prior pathname check.
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DatabaseAccessError.unsafeConfiguration }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw DatabaseAccessError.unsafeConfiguration }
        var bytes = [UInt8](repeating: 0, count: 65_537)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 65_536 else { throw DatabaseAccessError.unsafeConfiguration }
        do { return try JSONDecoder().decode(Configuration.self, from: Data(bytes.prefix(count))) }
        catch { throw DatabaseAccessError.invalidConfiguration }
    }

    public func resolve(_ request: DatabaseAccessRequest = .init()) throws -> DatabaseAccess {
        guard request.timeout.isFinite, request.timeout >= 0, request.timeout <= 30 else {
            throw DatabaseAccessError.invalidConfiguration
        }
        let deadline = environment.now() + request.timeout
        func check() throws {
            if environment.now() >= deadline { throw DatabaseAccessError.deadlineExceeded }
        }
        try check()
        var request = request
        if let path = request.configPath {
            let config = try configuration(path)
            request.databasePath = request.databasePath ?? config.databasePath
            request.key = request.key ?? config.key
            request.userId = request.userId ?? config.userId
            request.uuid = request.uuid ?? config.uuid
        }
        guard request.userId.map({ $0 > 0 }) ?? true,
              request.key.map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 4096 }) ?? true,
              request.databasePath.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true,
              request.uuid.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw DatabaseAccessError.invalidConfiguration
        }
        try check()

        func validate(path: String, key: String?, expected: Int?) throws -> DatabaseAccess {
            try check()
            let remaining = deadline - environment.now()
            let reader = DatabaseReader(databasePath: path)
            defer { reader.close() }
            // Reader's deadline is always a real monotonic deadline, even when the resolver clock is injected.
            let id = try reader.openValidated(key: key, expectedUserId: expected, timeout: remaining)
            try check()
            return DatabaseAccess(databasePath: path, key: key, userId: Int(id))
        }

        // Preserve explicit DB/key (including plaintext --db alone) without touching device preferences.
        if let path = request.databasePath, request.key != nil || request.userId == nil {
            return try validate(path: path, key: request.key, expected: request.userId)
        }

        let ids: [Int]
        if let id = request.userId { ids = [id] }
        else {
            do { ids = Array(try environment.candidateUserIds().filter { $0 > 0 }.prefix(8)) }
            catch { throw DatabaseAccessError.missingUserId }
        }
        try check()
        guard !ids.isEmpty else { throw DatabaseAccessError.missingUserId }
        let uuid: String
        do { uuid = try request.uuid ?? environment.platformUUID() }
        catch { throw DatabaseAccessError.invalidConfiguration }
        guard UUID(uuidString: uuid) != nil else { throw DatabaseAccessError.invalidConfiguration }
        try check()
        var lastError = DatabaseAccessError.unreadableDatabase
        for id in ids {
            try check()
            let path: String
            if let explicit = request.databasePath { path = explicit }
            else {
                let name = KeyDerivation.databaseName(userId: id, uuid: uuid)
                try check()
                let root = environment.containerPath()
                guard let found = ["\(root)/\(name)", "\(root)/\(name).db"].first(where: {
                    FileManager.default.fileExists(atPath: $0)
                }) else { continue }
                path = found
            }
            let key = request.key ?? KeyDerivation.secureKey(userId: id, uuid: uuid)
            try check()
            do { return try validate(path: path, key: key, expected: id) }
            catch let error as DatabaseAccessError {
                if request.userId != nil || error == .deadlineExceeded { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Revalidate account binding on the final returned handle, within the remaining budget.
    public func open(_ request: DatabaseAccessRequest = .init()) throws -> DatabaseReader {
        let start = environment.now()
        let access = try resolve(request)
        let remaining = request.timeout - (environment.now() - start)
        guard remaining > 0 else { throw DatabaseAccessError.deadlineExceeded }
        let reader = DatabaseReader(databasePath: access.databasePath)
        try reader.openValidated(key: access.key, expectedUserId: access.userId, timeout: remaining)
        return reader
    }
}
