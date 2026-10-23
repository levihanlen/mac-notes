import AppKit
import Carbon.HIToolbox
import WebKit

// MacNotes is the hotkey and the floating panel. The notes themselves are /note on
// levihanlen.com, in its list layout: the same notes as the site and the phone, synced the way
// they sync, typed into the same way. The page keeps them in this app's own web storage, so a
// panel that has loaded once still opens its notes with no connection.

final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler
{
    private var panel: NotesPanel!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    /// Set when the page couldn't be reached, so the next time the panel opens it tries again.
    private var loadFailed = false

    /// `defaults write com.levihanlen.macnotes URL http://localhost:3000/note` points the panel
    /// at a dev server instead.
    private static let notesURL: URL = {
        if let custom = UserDefaults.standard.string(forKey: "URL"), let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://www.levihanlen.com/note")!
    }()

    /// Where the notes lived before they moved to /note. Nothing reads or writes it any more;
    /// the status menu only shows it in Finder so the old text can be copied across.
    private static let oldNotesDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacNotes", isDirectory: true)

    /// The list layout the first time the page opens here. After that the page's own toggle
    /// decides, and remembers, as it does in any browser.
    private static let seedLayout = """
        try {
          if (!localStorage.getItem("note-layout")) localStorage.setItem("note-layout", "list");
        } catch (error) {}
        """

    /// Escape hides the panel, but only once the page has had it: Escape also closes the
    /// composer, a dialog, or leaves the note being typed into, and those say so by preventing
    /// the default. Checked after the event has finished, since the page's own listeners may run
    /// after this one.
    private static let escapeHides = """
        window.addEventListener("keydown", function (event) {
          if (event.key !== "Escape") return;
          setTimeout(function () {
            if (!event.defaultPrevented) window.webkit.messageHandlers.macnotes.postMessage("hide");
          }, 0);
        });
        """

    /// Before quitting: leaving the note being typed into writes it now rather than after the
    /// page's short save delay, and a click elsewhere is what turns the composer's text into a
    /// note.
    private static let settle = """
        (function () {
          var active = document.activeElement;
          if (active && active.blur) active.blur();
          if (document.body) document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
        })();
        """

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpMainMenu()
        setUpPanel()
        setUpStatusItem()
        registerHotKey()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard webView != nil else { return .terminateNow }
        webView.evaluateJavaScript(Self.settle) { _, _ in
            // The page writes to IndexedDB asynchronously; give it a moment to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - Main menu
    // Never visible (accessory app), but required so standard editing
    // key equivalents (⌘A/C/V/X/Z, ⌘W) resolve while the panel is key.

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Note", action: #selector(startNewNote), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Find", action: #selector(findNotes), keyEquivalent: "f").target = self
        fileMenu.addItem(withTitle: "Reload", action: #selector(reloadNotes), keyEquivalent: "r").target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(hidePanel), keyEquivalent: "w").target = self
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
        panel.orderOut(nil)
    }

    /// The page's own shortcuts: n opens the composer, / goes to search. Sent as key presses
    /// rather than reaching into the page, so they mean whatever the page says they mean.
    private func pressKey(_ key: String) {
        webView.evaluateJavaScript(
            "window.dispatchEvent(new KeyboardEvent('keydown', { key: '\(key)', bubbles: true }));"
        )
    }

    @objc private func startNewNote() {
        pressKey("n")
    }

    @objc private func findNotes() {
        pressKey("/")
    }

    @objc private func reloadNotes() {
        loadNotes()
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

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.seedLayout, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.escapeHides, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "macnotes")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = content

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        loadNotes()

        panel.contentView = webView
        panel.setFrameAutosaveName("MacNotesPanel")
        if panel.frame.origin == .zero {
            panel.center()
        }
    }

    private func loadNotes() {
        loadFailed = false
        webView.load(URLRequest(url: Self.notesURL))
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            if loadFailed {
                loadNotes()
            }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(webView)
        }
    }

    // MARK: - Web view

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "hide" {
            panel.orderOut(nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showUnreachable(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showUnreachable(error)
    }

    private func showUnreachable(_ error: Error) {
        // A navigation replaced by another one isn't a failure worth a page.
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadFailed = true
        let host = Self.notesURL.host ?? "the notes"
        webView.loadHTMLString(
            """
            <body style="font: 14px -apple-system; color: #888; padding: 24px; background: transparent">
            Couldn't reach \(host). It tries again the next time this panel opens, or press ⌘R.
            </body>
            """,
            baseURL: nil
        )
    }

    /// The notes host, and the other apps on it reached from the page's ⌘K, open in the panel.
    /// Anything else opens in the browser.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || Self.sameSite(url.host, Self.notesURL.host) {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    /// With or without the www, so a redirect between the two stays in the panel.
    private static func sameSite(_ host: String?, _ other: String?) -> Bool {
        func bare(_ host: String?) -> String? {
            guard let host else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return bare(host) != nil && bare(host) == bare(other)
    }

    /// A link that asks for a new window goes to the browser too.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
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
        menu.addItem(withTitle: "Reload Notes", action: #selector(reloadNotes), keyEquivalent: "").target = self
        if FileManager.default.fileExists(atPath: Self.oldNotesDirectory.path) {
            menu.addItem(withTitle: "Show Old Notes in Finder", action: #selector(showOldNotes), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showOldNotes() {
        NSWorkspace.shared.open(Self.oldNotesDirectory)
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
