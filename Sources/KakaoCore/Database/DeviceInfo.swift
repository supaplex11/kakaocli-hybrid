import CommonCrypto
import Foundation
import IOKit
import Darwin

/// Extracts device UUID and KakaoTalk user ID from the local system.
public enum DeviceInfo {

    /// Direct IOKit lookup: no subprocess, pipe deadlock or unbounded waitUntilExit.
    public static func platformUUID() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw KakaoError.uuidNotFound }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              UUID(uuidString: value) != nil else { throw KakaoError.uuidNotFound }
        return value
    }

    /// Path to the KakaoTalk preferences plist.
    public static var preferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Preferences/com.kakao.KakaoTalkMac.plist"
    }

    /// Path to the KakaoTalk container data directory.
    public static var containerPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
    }

    /// Path to the container preferences plist (has more data than the global one).
    public static var containerPreferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefDir = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences"
        // Find the hex-suffixed plist: com.kakao.KakaoTalkMac.<HEX>.plist
        if let directory = opendir(prefDir) {
            defer { closedir(directory) }
            for _ in 0..<128 {
                guard let entry = readdir(directory) else { break }
                let file = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if file.hasPrefix("com.kakao.KakaoTalkMac."), file.hasSuffix(".plist") {
                    return "\(prefDir)/\(file)"
                }
            }
        }
        return "\(prefDir)/com.kakao.KakaoTalkMac.plist"
    }

    /// Bounded preferences-only detection; never reads legacy auth caches or brute-forces hashes.
    /// Candidates are untrusted hints and must be validated against the decrypted database account.
    public static func detectedUserIds() -> [Int] {
        var result: [Int] = []
        for path in [containerPreferencesPath, preferencesPath] {
            guard let plist = boundedPreferences(path) else { continue }
            for key in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
                if let id = positiveID(plist[key]), !result.contains(id) { result.append(id) }
            }
            for prefix in ["FSChatWindowTransparency", "NSWindow Frame FSChatWindowFrame_"] {
                let suffixes = plist.keys.filter { $0.hasPrefix(prefix) }.prefix(128).map { String($0.dropFirst(prefix.count)) }
                if suffixes.count >= 2, let suffix = longestCommonSuffix(suffixes),
                   let id = positiveID(suffix), !result.contains(id) { result.append(id) }
            }
            for value in (plist["AlertKakaoIDsList"] as? [Any] ?? []).prefix(8) {
                if let id = positiveID(value), !result.contains(id) { result.append(id) }
            }
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    private static func positiveID(_ value: Any?) -> Int? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else { return nil }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let id = Int(text), id > 0 else { return nil }
        return id
    }

    private static func boundedPreferences(_ path: String) -> [String: Any]? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1_048_577)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 1_048_576 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: Data(bytes.prefix(count)), format: nil)) as? [String: Any]
    }

    public static func userId() throws -> Int {
        guard let id = detectedUserIds().first else { throw DatabaseAccessError.missingUserId }
        return id
    }

    public static func candidateUserIds() -> [Int] { detectedUserIds() }

    /// Discover database file by scanning the container for 78-char hex filenames.
    public static func discoverDatabaseFile() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return nil }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        // Also check files with .db extension that have hex basename
        let hexDbPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}\\.db$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexDbPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        return nil
    }

    /// Count database files in the container (78-char hex files or .db files).
    public static func countDatabaseFiles() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return 0 }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}(\\.db)?$")
        return entries.filter { entry in
            let range = NSRange(entry.startIndex..., in: entry)
            return hexPattern.firstMatch(in: entry, range: range) != nil
        }.count
    }

    /// Extract the active account SHA-512 hash from plist revision keys.
    /// Keys like `DESIGNATEDFRIENDSREVISION:<sha512hex>` appear with non-zero values for the active account.
    /// SHA-512("0") is the default/empty account hash.
    public static func activeAccountHash() -> String? {
        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            if let hash = activeAccountHash(from: plist) {
                return hash
            }
        }
        return nil
    }

    private static func activeAccountHash(from plist: [String: Any]) -> String? {
        // SHA-512("0") = 31bca02... is the default/empty account
        let emptyHash = "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"
        let prefix = "DESIGNATEDFRIENDSREVISION:"
        for (key, val) in plist where key.hasPrefix(prefix) {
            let hash = String(key.dropFirst(prefix.count))
            if hash == emptyHash { continue }
            let intVal: Int
            if let v = val as? Int { intVal = v }
            else if let v = val as? Double { intVal = Int(v) }
            else { intVal = 0 }
            if intVal != 0 { return hash }
        }
        return nil
    }

    /// Recover a userId by brute-forcing the SHA-512 pre-image.
    /// KakaoTalk stores SHA-512(userId) as hex in plist keys. Since userIds are
    /// typically small integers, this is fast (< 1 second for IDs under 1M).
    /// Explicit library-only helper, never used in auto detection. Default 250 ms; max 10 seconds.
    public static func recoverUserIdFromSHA512(hexHash: String, timeout: TimeInterval = 0.25) -> Int? {
        guard timeout.isFinite, timeout > 0, timeout <= 10, hexHash.count == 128 else { return nil }
        // Parse target hash to bytes
        var targetBytes = [UInt8](repeating: 0, count: 64)
        let hexChars = Array(hexHash)
        for i in 0..<64 {
            guard let byte = UInt8(String(hexChars[i*2...i*2+1]), radix: 16) else { return nil }
            targetBytes[i] = byte
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let maxId = 1_000_000_000
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))

        for i in 0..<maxId {
            let s = String(i)
            let data = Array(s.utf8)
            CC_SHA512(data, CC_LONG(data.count), &hash)
            if hash == targetBytes {
                return i
            }
            if i % 64 == 0 && ProcessInfo.processInfo.systemUptime >= deadline { return nil }
        }
        return nil
    }

    private static func longestCommonSuffix(_ strings: [String]) -> String? {
        guard let first = strings.first else { return nil }
        let reversed = strings.map { String($0.reversed()) }
        var commonLen = 0
        for i in reversed[0].indices {
            let ch = reversed[0][i]
            if reversed.allSatisfy({ i < $0.endIndex && $0[i] == ch }) {
                commonLen += 1
            } else {
                break
            }
        }
        guard commonLen > 0 else { return nil }
        return String(first.suffix(commonLen))
    }
}

public enum KakaoError: Error, CustomStringConvertible {
    case uuidNotFound
    case plistNotFound(String)
    case plistParseError
    case userIdNotFound([String])
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case sqlError(String)
    case kakaoTalkNotInstalled

    public var description: String {
        switch self {
        case .uuidNotFound:
            return "Could not read IOPlatformUUID from ioreg"
        case .plistNotFound(let path):
            return "KakaoTalk preferences not found at \(path). Is KakaoTalk installed?"
        case .plistParseError:
            return "Failed to parse KakaoTalk preferences plist"
        case .userIdNotFound(let keys):
            return "Could not find user ID in plist. Available keys: \(keys.joined(separator: ", "))"
        case .databaseNotFound(let path):
            return "KakaoTalk database not found at \(path)"
        case .databaseOpenFailed(let msg):
            return "Failed to open database: \(msg)"
        case .sqlError(let msg):
            return "SQL error: \(msg)"
        case .kakaoTalkNotInstalled:
            return "KakaoTalk.app is not installed"
        }
    }
}
