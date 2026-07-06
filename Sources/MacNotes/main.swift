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
    private var textView: NSTextView!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var saveTimer: Timer?

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.txt")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpMainMenu()
        setUpPanel()
        setUpStatusItem()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveNow()
    }

    // MARK: - Main menu
    // Never visible (accessory app), but required so standard editing
    // key equivalents (⌘A/C/V/X/Z, ⌘W) resolve while the panel is key.

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
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
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func hidePanel() {
        guard panel.isVisible else { return }
        saveNow()
        panel.orderOut(nil)
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
        panel.onHide = { [weak self] in self?.saveNow() }

        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { fatalError() }
        textView = tv
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = self
        textView.string = (try? String(contentsOf: saveURL, encoding: .utf8)) ?? ""

        panel.contentView = scrollView
        panel.setFrameAutosaveName("MacNotesPanel")
        if panel.frame.origin == .zero {
            panel.center()
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            saveNow()
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
        }
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

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        try? textView.string.write(to: saveURL, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
