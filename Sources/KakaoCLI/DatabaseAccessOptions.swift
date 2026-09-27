import ArgumentParser
import KakaoCore

/// One option contract for all encrypted DB commands, independent of receive.
struct DatabaseAccessOptions: ParsableArguments {
    @Option(name: .long, help: "Explicit local database path")
    var db: String?

    @Option(name: .long, help: "Legacy key override (deprecated: visible in process arguments; prefer --access-config)")
    var key: String?

    @Option(name: .long, help: "Expected positive account user ID; derive key if needed, fail on mismatch")
    var userId: Int?

    @Option(name: .long, help: "Explicit owned 0600 JSON config; never imports auth caches")
    var accessConfig: String?

    @Option(name: .long, help: "Device UUID override for derivation")
    var uuid: String?

    @Option(name: .long, help: "Cooperative access deadline in seconds (0–30, default 2)")
    var accessTimeout: Double = 2

    var request: DatabaseAccessRequest {
        .init(databasePath: db, key: key, userId: userId, uuid: uuid,
              configPath: accessConfig, timeout: accessTimeout)
    }

    func open() throws -> DatabaseReader { try DatabaseAccessResolver().open(request) }
    func resolve() throws -> DatabaseAccess { try DatabaseAccessResolver().resolve(request) }
}
