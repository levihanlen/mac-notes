import AppKit
import Carbon.HIToolbox

final class NotesPanel: NSPanel {
    var onHide: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onHide?()
        orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var panel: NotesPanel!
    private var editor: NotesEditor!
    private var textView: NotesTextView { editor.textView }
    private var copyAllButton: IconButton!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var saveTimer: Timer?
    private var lastSavedText = ""
    /// False if the notes file couldn't be read or backed up, so it's never saved over.
    private var canSave = true

    private static let supportDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let saveURL = supportDirectory.appendingPathComponent("notes.txt")
    private let history = History(directory: supportDirectory.appendingPathComponent("history", isDirectory: true))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpMainMenu()
        setUpPanel()
        setUpStatusItem()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveAndSnapshot()
    }

    // MARK: - Main menu
    // Never visible (accessory app), but required so standard editing
    // key equivalents (⌘A/C/V/X/Z, ⌘W) resolve while the panel is key.

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newNote = fileMenu.addItem(withTitle: "New Note", action: #selector(startNewNote), keyEquivalent: "n")
        newNote.target = self
        let close = fileMenu.addItem(withTitle: "Close", action: #selector(hidePanel), keyEquivalent: "w")
        close.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyNote = editMenu.addItem(withTitle: "Copy Note", action: #selector(copyCurrentNote), keyEquivalent: "c")
        copyNote.keyEquivalentModifierMask = [.command, .shift]
        copyNote.target = self
        let copyAll = editMenu.addItem(withTitle: "Copy All Notes", action: #selector(copyAllNotes), keyEquivalent: "c")
        copyAll.keyEquivalentModifierMask = [.command, .option]
        copyAll.target = self
        editMenu.addItem(.separator())
        let findActions: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", [.command], .showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
        ]
        for (title, key, modifiers, action) in findActions {
            let item = editMenu.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func hidePanel() {
        guard panel.isVisible else { return }
        saveAndSnapshot()
        panel.orderOut(nil)
    }

    @objc private func startNewNote() {
        textView.startNewNote()
        panel.makeFirstResponder(textView)
    }

    @objc private func copyCurrentNote() {
        guard let note = textView.currentNote else { return }
        copyToPasteboard(textView.text(of: note))
    }

    @objc private func copyAllNotes() {
        copyToPasteboard(textView.string)
        copyAllButton.flashCheckmark()
    }

    // MARK: - Panel

    private func setUpPanel() {
        panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Notes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 280, height: 160)
        panel.onHide = { [weak self] in self?.saveAndSnapshot() }

        editor = NotesEditor()
        textView.delegate = self
        let text = loadNotes()
        editor.load(text)
        lastSavedText = text
        history.snapshot(text)

        panel.contentView = editor
        setUpTitlebarButtons()
        panel.setFrameAutosaveName("MacNotesPanel")
        if panel.frame.origin == .zero {
            panel.center()
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            saveAndSnapshot()
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
        }
    }

    private func setUpTitlebarButtons() {
        let historyButton = IconButton(
            symbol: "clock.arrow.circlepath", label: "History", target: self, action: #selector(showHistoryMenu(_:))
        )
        copyAllButton = IconButton(symbol: "doc.on.doc", label: "Copy all notes", target: self, action: #selector(copyAllNotes))
        let stack = NSStackView(views: [historyButton, copyAllButton])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        stack.frame.size = NSSize(width: stack.fittingSize.width, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = stack
        panel.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - History menu

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @objc private func showHistoryMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let snapshots = history.snapshots()
        if snapshots.isEmpty {
            menu.addItem(withTitle: "No history yet", action: nil, keyEquivalent: "")
        }
        for snapshot in snapshots.prefix(20) {
            let item = menu.addItem(
                withTitle: Self.historyDateFormatter.string(from: snapshot.date),
                action: #selector(openSnapshot(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = snapshot.url
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All in Finder", action: #selector(showHistoryFolder), keyEquivalent: "").target = self
        let below = sender.isFlipped ? sender.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
    }

    @objc private func openSnapshot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showHistoryFolder() {
        NSWorkspace.shared.open(history.directory)
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: "MacNotes"
        )
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show/Hide Notes", action: #selector(togglePanel), keyEquivalent: ".")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(withTitle: "Show History in Finder", action: #selector(showHistoryFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Global hotkey (⌥.)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue().togglePanel()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4E_5453), id: 1) // "MNTS"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    // MARK: - Persistence

    func textDidChange(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    private func loadNotes() -> String {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return "" }
        if let text = try? String(contentsOf: saveURL, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: saveURL, usedEncoding: &encoding) { return text }

        // Unreadable: keep the original bytes before anything is saved over them.
        let backup = history.directory.appendingPathComponent("unreadable-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try FileManager.default.copyItem(at: saveURL, to: backup)
        } catch {
            canSave = false
            panel.title = "Notes — not saved"
        }
        return ""
    }

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let text = textView.string
        guard canSave, text != lastSavedText else { return }

        // Clearing everything or deleting a big chunk puts the version before it in history.
        if text.isEmpty || lastSavedText.utf16.count - text.utf16.count >= 100 {
            history.snapshot(lastSavedText)
        }
        do {
            try text.write(to: saveURL, atomically: true, encoding: .utf8)
            lastSavedText = text
            panel.title = "Notes"
        } catch {
            NSLog("MacNotes: couldn't save notes: \(error)")
            panel.title = "Notes — not saved"
        }
        history.snapshotIfStale(text)
    }

    /// Saves and takes a history snapshot. Runs whenever the panel hides and when the app quits.
    private func saveAndSnapshot() {
        saveNow()
        if canSave {
            history.snapshot(textView.string)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
