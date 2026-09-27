import ArgumentParser
import Foundation
import Darwin
import KakaoCore

struct ReceiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "receive", abstract: "Receive notification observations locally (durable at-least-once NDJSON; not chat history)")
    @Option(name: .long, help: "Only notif is supported; no login or Kakao database access") var source = "notif"
    @Flag(name: .long, help: "Read one snapshot and drain at most 100 eligible deliveries") var once = false
    @Flag(name: .long, help: "Poll continuously; SIGINT/SIGTERM stop gracefully") var follow = false
    @Flag(name: .long, help: "NDJSON output (also the default)") var json = false
    @Flag(name: .long, help: "Deliver existing observations on FIRST initialization only") var replayExisting = false
    @Option(name: .long, help: "Explicit notification SQLite source; otherwise discover current user's store") var notificationDb: String?
    @Option(name: .long, help: "Durable inbox path; parent must be private (0700)") var inbox: String?
    @Option(name: .long, help: "Required user-assigned account namespace; change on account switch") var account: String
    @Option(name: .long, help: "Poll interval in seconds (0.1–3600)") var interval: Double = 2

    @Option(name: .long, help: "Terminal payload retention in seconds (default 604800 = 7 days; 0 prunes immediately). Pending/leased work never expires; fingerprints remain.") var retentionSeconds: Double = ReceiveStore.defaultRetention

    mutating func validate() throws {
        guard retentionSeconds.isFinite, retentionSeconds >= 0 else { throw ValidationError("--retention-seconds must be finite and nonnegative.") }
        guard source == "notif" else { throw ValidationError("Only --source notif is implemented.") }
        guard once != follow else { throw ValidationError("Select exactly one of --once or --follow.") }
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, account.utf8.count <= 256, !account.contains("\0") else { throw ValidationError("--account must be a nonempty namespace of at most 256 UTF-8 bytes.") }
        guard interval.isFinite, (0.1...3600).contains(interval) else { throw ValidationError("--interval must be between 0.1 and 3600 seconds.") }
    }

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let stop = ReceiveStop()
        defer { stop.close() }
        let path = inbox ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kakaocli/receive/inbox.sqlite").path
        if let sourcePath = notificationDb {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath() != URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath() else { throw ValidationError("Inbox must not be the source database.") }
        }
        let store = try ReceiveStore(path: path)
        repeat {
            try store.prune(account: account, now: Date().timeIntervalSince1970, retention: retentionSeconds)
            var remaining = 100
            func drain() throws {
                while remaining > 0 && !stop.requested {
                    guard let claim = try store.claim(account: account, now: Date().timeIntervalSince1970) else { break }
                    remaining -= 1
                    do { try ReceiveStdout.write(claim.payload, shouldStop: { stop.requested }) }
                    catch {
                        if stop.requested {
                            try store.release(claim)
                            return
                        }
                        try store.fail(claim, now: Date().timeIntervalSince1970)
                        throw error
                    }
                    try store.complete(claim, now: Date().timeIntervalSince1970)
                }
            }
            // Recovery is independent of source discovery and snapshot health.
            try drain()
            if stop.requested { break }
            var sourceFailed = false
            do {
                let sourcePath = try notificationDb ?? NotificationReader.discover()
                guard URL(fileURLWithPath: path).resolvingSymlinksInPath() != URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath() else { throw ReceiveError.unsafeStore }
                let reader = try NotificationReader(path: sourcePath)
                let snapshot = try reader.snapshot()
                if !stop.requested {
                    try store.ingest(snapshot.observations, account: account, source: reader.sourceId, replay: replayExisting, now: Date().timeIntervalSince1970)
                }
                if snapshot.malformedCount > 0 { FileHandle.standardError.write(Data("Skipped \(snapshot.malformedCount) malformed notification payload(s).\n".utf8)) }
            } catch {
                sourceFailed = true
                let detail = (error as? ReceiveError)?.description ?? "Operation failed (details redacted)."
                FileHandle.standardError.write(Data("Source health: \(detail)\n".utf8))
            }
            try drain()
            try store.prune(account: account, now: Date().timeIntervalSince1970, retention: retentionSeconds)
            if stop.requested { break }
            if once && sourceFailed { throw ExitCode.failure }
            if follow { stop.wait(interval) }
        } while follow && !stop.requested
    }
}
