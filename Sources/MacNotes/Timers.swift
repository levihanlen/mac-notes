import Foundation

/// The launcher's timers ("timer 10m tea", and the end of a focus session started from it). Each
/// is a moment, never a count: the notification is handed to macOS for that moment, and this list
/// is only so the launcher can show what's running and cancel one. Kept in the defaults so a
/// relaunch still knows them.
final class Timers {
    struct Timer {
        let id: String
        let label: String
        let endsAt: Date
    }

    private static let key = "Timers"
    private let notifier: Notifier
    private var timers: [Timer]

    init(notifier: Notifier) {
        self.notifier = notifier
        let saved = UserDefaults.standard.array(forKey: Self.key) as? [[String: Any]] ?? []
        timers = saved.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let label = entry["label"] as? String,
                  let endsAt = entry["endsAt"] as? Double
            else { return nil }
            return Timer(id: id, label: label, endsAt: Date(timeIntervalSince1970: endsAt / 1000))
        }
        dropEnded()
    }

    func start(id: String, label: String, endsAt: Date, body: String, url: URL?) {
        timers.removeAll { $0.id == id }
        timers.append(Timer(id: id, label: label, endsAt: endsAt))
        notifier.schedule(id: id, title: label, body: body, at: endsAt, url: url)
        save()
    }

    func cancel(id: String) {
        timers.removeAll { $0.id == id }
        notifier.cancel(id: id)
        save()
    }

    /// The ones still running, soonest first, with `endsAt` in ms as the page counts time.
    var answer: [[String: Any]] {
        dropEnded()
        return timers.sorted { $0.endsAt < $1.endsAt }.map {
            ["id": $0.id, "label": $0.label, "endsAt": ($0.endsAt.timeIntervalSince1970 * 1000).rounded()]
        }
    }

    private func dropEnded() {
        let before = timers.count
        timers.removeAll { $0.endsAt <= Date() }
        if timers.count != before {
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(
            timers.map { ["id": $0.id, "label": $0.label, "endsAt": $0.endsAt.timeIntervalSince1970 * 1000] },
            forKey: Self.key
        )
    }
}
