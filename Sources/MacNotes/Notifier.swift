import AppKit
import UserNotifications

/// macOS notifications the launcher asks for. Clicking one opens its link. They show even while
/// MacNotes is the frontmost app, which, being a menu bar app with panels, it often nearly is.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Notifications need an app bundle: run bare from .build, there's no center and asking for
    /// one would crash.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start() {
        center?.delegate = self
    }

    /// macOS asks for permission the first time; after that the request answers at once.
    func post(title: String, body: String, url: URL?) {
        guard let center else {
            NSLog("MacNotes: notifications need MacNotes.app; skipped \"\(title)\"")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                NSLog("MacNotes: notifications aren't allowed\(error.map { " (\($0))" } ?? "")")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url {
                content.userInfo = ["url": url.absoluteString]
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error {
                    NSLog("MacNotes: couldn't post a notification: \(error)")
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let string = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: string)
        {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
