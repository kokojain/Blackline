import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import BlacklineUI

@main
struct BlacklineApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            // Monochrome template artwork, the way the menu bar expects.
            Image(systemName: model.current == nil ? "square.text.square" : "square.text.square.fill")
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "review", for: UUID.self) { $runID in
            if let runID {
                ReviewView(runID: runID)
                    .environment(model)
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar utility with no Dock icon and no main window.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestPermission()
    }

    /// Clicking the completion notification reveals the redacted copy (spec §3).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["reveal"] as? String {
            Notifier.reveal(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
}

