import Foundation
import CryptoKit

public struct ReceiveEvent {
    public let account: String
    public let observation: NotificationObservation
    public let observedAt: Date
    public var revision: Int = 1
    public var eventId: String {
        // Length-delimited namespace prevents separator collisions; no source in identity.
        Self.digest("\(account.utf8.count):\(account)/\(observation.chatId)/\(observation.logId)")
    }
    public init(account: String, observation: NotificationObservation, observedAt: Date) {
        self.account = account; self.observation = observation; self.observedAt = observedAt
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func json() throws -> Data {
        let o = observation, null = NSNull(), f = ISO8601DateFormatter()
        let object: [String: Any] = [
            "schema_version": 1, "event_id": eventId, "revision": revision,
            "event_type": revision == 1 ? "message.observed" : "message.updated",
            "account_namespace": account, "chat_id": o.chatId, "log_id": o.logId,
            "sources": ["notification"], "observed_at": f.string(from: observedAt),
            "notification_at": o.notificationAt.map(f.string) as Any? ?? null,
            "message_at": null, "text": o.text as Any? ?? null, "sender_id": null, "is_from_me": null,
            "notification_title": o.title as Any? ?? null, "verified_chat_name": null,
            "notification_attachment_path": o.attachmentPath as Any? ?? null,
            "completeness": "notification_only",
            "field_provenance": ["chat_id": "notification.req.iden", "log_id": "notification.req.iden", "text": "notification.req.body", "notification_title": "notification.req.titl", "notification_at": "notification.date", "notification_attachment_path": "notification.req.atta.pat"]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
