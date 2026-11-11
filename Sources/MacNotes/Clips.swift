import AppKit

/// The clipboard's history, for the launcher's clips: the last 200 texts copied anywhere, newest
/// first. macOS keeps only the latest copy and says nothing when it changes, so this looks at the
/// clipboard's change count twice a second. Kept in a file on this Mac and never sent anywhere;
/// the launcher reads it only when asked.
final class ClipHistory {
    struct Clip: Codable {
        let text: String
        /// Milliseconds since the epoch, as the page's Date takes them.
        let at: Int64
    }

    private(set) var clips: [Clip] = []
    /// Starts unseen, so whatever is on the clipboard at launch counts as copied then.
    private var changeCount = -1
    private var timer: Timer?
    private let writer = DispatchQueue(label: "com.levihanlen.macnotes.clips", qos: .utility)

    private static let limit = 200
    /// Something far longer than anyone pastes back from a list, a whole log say, is left out, so
    /// the file and the page's copy of it stay small.
    private static let longest = 100_000

    /// What password managers mark their copies with (nspasteboard.org), so a password never
    /// lands in the history.
    private static let secretTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private static let file = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacNotes", isDirectory: true)
        .appendingPathComponent("clips.json")

    static var fileName: String { file.lastPathComponent }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Clip].self, from: data)
        {
            clips = Array(saved.prefix(Self.limit))
        }
    }

    func start() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer.tolerance = 0.1
        // Common modes, so a copy made while a menu is open is still caught.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// As the page takes them: `{text, at}`, newest first.
    var answer: [[String: Any]] {
        clips.map { ["text": $0.text, "at": $0.at] }
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        if let types = board.types, types.contains(where: Self.secretTypes.contains) {
            return
        }
        guard let text = board.string(forType: .string),
              text.utf16.count <= Self.longest,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        add(text)
    }

    /// The same text copied again moves to the top rather than showing twice.
    private func add(_ text: String) {
        clips.removeAll { $0.text == text }
        clips.insert(Clip(text: text, at: Int64(Date().timeIntervalSince1970 * 1000)), at: 0)
        if clips.count > Self.limit {
            clips.removeLast(clips.count - Self.limit)
        }
        save()
    }

    /// Readable only by this user, since what's copied can be private.
    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        writer.async {
            let files = FileManager.default
            do {
                try files.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: Self.file, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
            } catch {
                NSLog("MacNotes: couldn't save the clipboard history: \(error)")
            }
        }
    }
}
