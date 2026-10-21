import Foundation

/// Timestamped copies of the notes, so nothing typed is ever lost.
/// Keeps every snapshot from the last day, the newest per hour for the
/// last week, and the newest per day after that.
final class History {
    let directory: URL
    private var lastSnapshotText: String?
    private var lastSnapshotDate = Date.distantPast

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let latest = snapshots().first {
            lastSnapshotText = try? String(contentsOf: latest.url, encoding: .utf8)
            lastSnapshotDate = latest.date
        }
    }

    /// All snapshots, newest first.
    func snapshots() -> [(url: URL, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url in
                guard url.pathExtension == "txt",
                      let date = Self.nameFormatter.date(from: url.deletingPathExtension().lastPathComponent)
                else { return nil }
                return (url, date)
            }
            .sorted { $0.date > $1.date }
    }

    /// Saves a copy of `text`, unless it's empty or the same as the latest snapshot.
    func snapshot(_ text: String) {
        guard !text.isEmpty, text != lastSnapshotText else { return }
        let now = Date()
        let url = directory.appendingPathComponent(Self.nameFormatter.string(from: now) + ".txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastSnapshotText = text
            lastSnapshotDate = now
        } catch {
            NSLog("MacNotes: couldn't write snapshot: \(error)")
        }
        prune(now: now)
    }

    /// Snapshots only if the latest one is older than `interval`.
    func snapshotIfStale(_ text: String, interval: TimeInterval = 5 * 60) {
        if Date().timeIntervalSince(lastSnapshotDate) >= interval {
            snapshot(text)
        }
    }

    /// Thins out old snapshots. Files are named by timestamp, so a name prefix
    /// ("2026-10-20T14" or "2026-10-20") identifies its hour or day.
    func prune(now: Date = Date()) {
        let day: TimeInterval = 24 * 60 * 60
        var keptBuckets = Set<String>()
        for snapshot in snapshots() {
            let age = now.timeIntervalSince(snapshot.date)
            guard age > day else { continue }
            let bucket = String(snapshot.url.lastPathComponent.prefix(age < 7 * day ? 13 : 10))
            // Newest first, so the first snapshot seen in each bucket is the one kept.
            if !keptBuckets.insert(bucket).inserted {
                try? FileManager.default.removeItem(at: snapshot.url)
            }
        }
    }
}
