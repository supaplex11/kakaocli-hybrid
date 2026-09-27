// Adapted from OpenKakao notif_watch.rs, MIT; see THIRD_PARTY_NOTICES.md.
import Foundation
import CoreFoundation

public struct NotificationObservation: Codable, Equatable {
    public let chatId: String
    public let logId: String
    public let title: String?
    public let text: String?
    public let attachmentPath: String?
    public let notificationAt: Date?
}

public enum NotificationParser {
    public static func parse(_ payload: Data) -> NotificationObservation? {
        guard payload.count <= 1_048_576,
              let root = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let req = root["req"] as? [String: Any], let id = req["iden"] as? String else { return nil }
        let ids = id.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard ids.count == 2, ids.allSatisfy({ value in
            guard let number = Int64(value), number > 0 else { return false }
            return String(number) == value
        }) else { return nil }
        var date: Date?
        if let d = root["date"] as? Date { date = d }
        else {
            var seconds: Double?
            if let n = root["date"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { seconds = n.doubleValue }
            else if let s = root["date"] as? String { seconds = Double(s) }
            if let s = seconds, s.isFinite, abs(s) < 100_000_000_000 { date = Date(timeIntervalSinceReferenceDate: s) }
        }
        return NotificationObservation(chatId: ids[0], logId: ids[1], title: req["titl"] as? String,
            text: req["body"] as? String, attachmentPath: (req["atta"] as? [[String: Any]])?.first?["pat"] as? String, notificationAt: date)
    }
}
