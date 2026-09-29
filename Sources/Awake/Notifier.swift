import Foundation
import UserNotifications

/// Local notifications. Everything here is a no-op outside a real `.app` bundle
/// (UserNotifications traps when there is no bundle), and quietly skips when
/// the user has denied permission.
enum Notifier {
    private static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks for permission the first time only; afterwards the system remembers the answer.
    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func postGoalReached() {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "8 hours done today"
        content.body = "Your Mac has been awake for the full 8 hours."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "goal-reached", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
