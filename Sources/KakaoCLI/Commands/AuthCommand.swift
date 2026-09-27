import ArgumentParser
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Verify read-only database access and account binding (no login)"
    )

    @Flag(name: .long, help: "Show validation status only; keys and account identifiers are always redacted")
    var verbose = false

    @OptionGroup var access: DatabaseAccessOptions

    func run() throws {
        let reader = try access.open()
        defer { reader.close() }
        print("Database access verified (read-only, account validated).")
        if verbose { print("Diagnostics redacted: no keys, account IDs, device UUIDs or database paths are printed.") }
    }
}
