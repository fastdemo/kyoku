import Foundation
import UserNotifications

/// Aggregated sync notifications (one per run, never per track).
/// Respects the user's opt-out (Settings → Notifications toggle).
/// Environment note: in sandboxed Debug builds without notification
/// entitlement response, requests are simply dropped (no crash).
enum SyncNotifier {
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "syncNotificationsEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "syncNotificationsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "syncNotificationsEnabled") }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
