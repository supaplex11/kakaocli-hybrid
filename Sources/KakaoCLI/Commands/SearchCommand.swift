import ArgumentParser
import Foundation
import KakaoCore

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages"
    )

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Maximum results")
    var limit: Int = 20

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @OptionGroup var access: DatabaseAccessOptions

    func run() throws {
        let reader = try access.open()
        defer { reader.close() }

        let results = try reader.search(query: query, limit: limit)

        if json {
            let items = results.map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "id": msg.id,
                    "chat_id": msg.chatId,
                    "sender_id": msg.senderId,
                    "type": String(describing: msg.type),
                    "timestamp": ISO8601DateFormatter().string(from: msg.createdAt),
                    "is_from_me": msg.isFromMe,
                ]
                if let name = msg.senderName { dict["sender"] = name }
                if let text = msg.text { dict["text"] = text }
                return dict
            }
            JSONOutput.printArray(items)
        } else {
            if results.isEmpty {
                print("No messages matching '\(query)'.")
                return
            }
            print("Found \(results.count) message(s):")
            print()
            for msg in results {
                let sender = msg.isFromMe ? "Me" : (msg.senderName ?? "Unknown")
                let time = formatDate(msg.createdAt)
                let text = msg.text ?? ""
                print("\(time) \(sender): \(text)")
            }
        }
    }
}
