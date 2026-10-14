import UserNotifications

/// Local notifications for turns that finish while their chat is off screen.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var asked = false

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for permission the first time the user sends something, while the app is in front.
    func prepare() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Banners also show while the app is open on another screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
