import AppKit
import UserNotifications

/// Completion feedback (spec §3).
///
/// The notification always carries the count, and says when pages were not checked — a
/// notification that reports only a total would let an unexamined page read as a success.
public enum Notifier {
    public static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(title: String, body: String, reveal url: URL) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["reveal": url.path]

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
