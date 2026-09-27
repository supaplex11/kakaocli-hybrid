import ArgumentParser
import Foundation
import KakaoCore

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Watch for new messages and output as JSON (for AI agents)"
    )

    @Flag(name: .long, help: "Continuously watch for new messages (NDJSON output)")
    var follow = false

    @Option(name: .long, help: "POST new messages to this webhook URL")
    var webhook: String?

    @Option(name: .long, help: "Poll interval in seconds (default: 2)")
    var interval: Double = 2.0

    @Option(name: .long, help: "Start from this logId (default: latest)")
    var sinceLogId: Int64?

    @OptionGroup var access: DatabaseAccessOptions

    func run() throws {
        let resolved = try access.resolve()

        if !follow && webhook == nil {
            // One-shot: show current high-water mark
            let reader = DatabaseReader(databasePath: resolved.databasePath)
            try reader.openValidated(key: resolved.key, expectedUserId: resolved.userId, timeout: access.accessTimeout)
            defer { reader.close() }
            let maxId = try reader.maxLogId()
            print("{\"status\":\"ready\",\"max_log_id\":\(maxId)}")
            return
        }

        let webhookPublisher: WebhookPublisher?
        if let webhookUrl = webhook, let url = URL(string: webhookUrl) {
            webhookPublisher = WebhookPublisher(url: url)
            fputs("Webhook: \(webhookUrl)\n", stderr)
        } else {
            webhookPublisher = nil
        }

        let watcher = DatabaseWatcher(
            databasePath: resolved.databasePath,
            key: resolved.key,
            pollInterval: interval,
            startFromLogId: sinceLogId,
            expectedUserId: resolved.userId
        )

        // Handle Ctrl-C gracefully
        signal(SIGINT) { _ in
            fputs("\nStopping sync...\n", stderr)
            Darwin.exit(0)
        }

        fputs("Watching for new messages (poll every \(interval)s)...\n", stderr)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        watcher.watch(
            onMessages: { messages in
                for msg in messages {
                    // NDJSON: one JSON object per line
                    if let data = try? encoder.encode(msg),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                        fflush(stdout)
                    }
                }
                // Also publish to webhook if configured
                if let publisher = webhookPublisher {
                    if !publisher.publish(messages) {
                        fputs("Warning: webhook delivery failed\n", stderr)
                    }
                }
            },
            onError: { error in
                fputs("Error: \(error)\n", stderr)
            }
        )
    }
}
