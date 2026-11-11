import Foundation

/// What a launcher request answers with when there's no answer: words the page can show.
struct LauncherError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Finds notes in brain/ for the launcher. brain/ is on this Mac and nowhere the page can read,
/// so the searching happens here. Every .md file's text is kept in memory, and each search only
/// re-reads the files that changed since the last one, so a keystroke costs a walk of the folder
/// and a byte search, not reading 8 MB.
final class BrainSearch {
    private struct File {
        let modified: Date
        let text: String
        /// The text lowercased, as UTF-8, so matching is a plain byte search.
        let lowered: [UInt8]
        /// The path without ".md", lowercased, as UTF-8.
        let name: [UInt8]
    }

    /// Keyed by the path relative to brain/.
    private var files: [String: File] = [:]
    /// One search at a time, in the order they were typed. An answer the page has stopped
    /// waiting for is ignored there.
    private let queue = DispatchQueue(label: "com.levihanlen.macnotes.brain", qos: .userInitiated)

    private static let limit = 8
    private static let lineLength = 120

    /// `defaults write com.levihanlen.macnotes BrainPath ~/somewhere/brain` for a checkout kept
    /// elsewhere.
    static var root: URL {
        if let custom = UserDefaults.standard.string(forKey: "BrainPath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub/life-nextjs/brain", isDirectory: true)
    }

    /// Answers on the main thread with at most eight hits, each `["path": …, "line": …]`.
    func search(_ query: String, done: @escaping (Result<[[String: String]], LauncherError>) -> Void) {
        queue.async {
            let result = self.run(query)
            DispatchQueue.main.async { done(result) }
        }
    }

    private func run(_ query: String) -> Result<[[String: String]], LauncherError> {
        let root = Self.root.resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(LauncherError("no brain folder at \(root.path)"))
        }
        refresh(root)

        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return .success([]) }
        let needles = words.map { Array($0.utf8) }

        var found: [(path: String, file: File, inName: Bool)] = []
        for (path, file) in files {
            var inName = true
            var matches = true
            for needle in needles where !Self.contains(file.name, needle) {
                inName = false
                if !Self.contains(file.lowered, needle) {
                    matches = false
                    break
                }
            }
            if matches {
                found.append((path, file, inName))
            }
        }

        // A note named for what was typed first, then the most recently touched.
        found.sort { a, b in
            if a.inName != b.inName { return a.inName }
            if a.file.modified != b.file.modified { return a.file.modified > b.file.modified }
            return a.path < b.path
        }

        return .success(found.prefix(Self.limit).map { hit in
            ["path": hit.path, "line": Self.line(in: hit.file.text, for: first)]
        })
    }

    /// Brings the cache up to date with the folder: new and changed files read, deleted ones
    /// dropped. Pictures and hidden folders (.obsidian, .git) are skipped.
    private func refresh(_ root: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var seen: Set<String> = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == "images" {
                    walker.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "md", url.path.hasPrefix(prefix) else { continue }
            let path = String(url.path.dropFirst(prefix.count))
            seen.insert(path)

            let modified = values?.contentModificationDate ?? .distantPast
            if files[path]?.modified == modified { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let name = path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
            files[path] = File(
                modified: modified,
                text: text,
                lowered: Array(text.lowercased().utf8),
                name: Array(name.lowercased().utf8)
            )
        }
        files = files.filter { seen.contains($0.key) }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { big in
            needle.withUnsafeBytes { little in
                memmem(big.baseAddress, big.count, little.baseAddress, little.count) != nil
            }
        }
    }

    /// The first line holding `word`, or the first line with anything on it when only the name
    /// matched.
    private static func line(in text: String, for word: String) -> String {
        var firstLine: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if firstLine == nil {
                firstLine = line
            }
            if line.lowercased().contains(word) {
                return cut(line)
            }
        }
        return cut(firstLine ?? "")
    }

    private static func cut(_ line: String) -> String {
        line.count > lineLength ? String(line.prefix(lineLength - 1)) + "…" : line
    }
}
