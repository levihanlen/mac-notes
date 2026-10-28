import AppKit
import Carbon.HIToolbox
import Network
import WebKit

// MacNotes is the hotkey and the floating panel. The panel shows one of two pages on
// levihanlen.com: /note in its list layout, or the /kb board. Each is the same as on the site and
// the phone, synced the way it syncs, typed into the same way. The pages keep their data in this
// app's own web storage, so a page that has loaded once still opens with no connection.

final class NotesPanel: NSPanel {
    /// When the panel was last put away. The hotkey, Esc, ⌘W and the close button all come
    /// through `orderOut`. Starts at launch, since the panel starts hidden.
    private(set) var hiddenAt = Date()

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        if isVisible {
            hiddenAt = Date()
        }
        super.orderOut(sender)
    }
}

/// The pages the panel switches between. Each has its own web view, kept alive while the other
/// shows, so switching is instant and each keeps its scroll, its open dialog and its typing.
enum Page: String, CaseIterable {
    case notes
    case kb

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .kb: return "KB"
        }
    }

    /// ⌘1 and ⌘2.
    var keyEquivalent: String {
        String(Page.allCases.firstIndex(of: self)! + 1)
    }

    /// `defaults write com.levihanlen.macnotes URL http://localhost:3000/note` points the panel
    /// at a dev server instead. /kb is on the same origin as the notes, wherever they are.
    var url: URL {
        let notes: URL = {
            if let custom = UserDefaults.standard.string(forKey: "URL"), let url = URL(string: custom) {
                return url
            }
            return URL(string: "https://www.levihanlen.com/note")!
        }()
        switch self {
        case .notes: return notes
        case .kb: return URL(string: "/kb", relativeTo: notes)!.absoluteURL
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler
{
    private var panel: NotesPanel!
    private var webViews: [Page: WKWebView] = [:]
    private var switcher: NSSegmentedControl!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    /// Pages that couldn't be reached, so the next time the panel opens on one it tries again.
    private var loadFailed: Set<Page> = []
    /// Whether the Mac is online, so reloading on its own never swaps a page that works offline
    /// for one saying the site can't be reached.
    private let network = NWPathMonitor()

    /// Away this long, and opening the panel reloads both pages.
    private static let reloadAfter: TimeInterval = 15 * 60

    /// The page showing, remembered across launches.
    private var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "Page") ?? "") ?? .notes {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "Page") }
    }

    private var webView: WKWebView { webViews[page]! }

    /// Where the notes lived before they moved to /note. Nothing reads or writes it any more;
    /// the status menu only shows it in Finder so the old text can be copied across.
    private static let oldNotesDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacNotes", isDirectory: true)

    /// The list layout the first time /note opens here. After that the page's own toggle
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

    /// Before quitting or reloading: leaving the note being typed into writes it now rather than
    /// after the page's short save delay, and a click elsewhere is what turns the composer's text
    /// into a note.
    private static let settle = """
        (function () {
          var active = document.activeElement;
          if (active && active.blur) active.blur();
          if (document.body) document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
        })();
        """

    /// What's typed into a dialog, a new task's title say, is only kept once it's saved, so
    /// reloading on its own leaves a page with one open as it is.
    private static let dialogOpen = """
        document.querySelector('[role="dialog"]') !== null
        """

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpMainMenu()
        setUpPanel()
        setUpStatusItem()
        registerHotKey()
        network.start(queue: .main)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !webViews.isEmpty else { return .terminateNow }
        settle(Page.allCases) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Saves what's being typed on `pages`, then calls `done` once it has had time to land.
    private func settle(_ pages: [Page], then done: @escaping () -> Void) {
        let settled = DispatchGroup()
        for page in pages {
            settled.enter()
            webViews[page]!.evaluateJavaScript(Self.settle) { _, _ in settled.leave() }
        }
        settled.notify(queue: .main) {
            // The pages write to IndexedDB asynchronously; give them a moment to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                done()
            }
        }
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
        fileMenu.addItem(withTitle: "Reload", action: #selector(reloadPages), keyEquivalent: "r").target = self
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

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for page in Page.allCases {
            viewMenu.addItem(pageItem(page))
        }
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    /// A menu item that shows `page`, ⌘1 or ⌘2.
    private func pageItem(_ page: Page) -> NSMenuItem {
        let item = NSMenuItem(title: page.title, action: #selector(showPage(_:)), keyEquivalent: page.keyEquivalent)
        item.representedObject = page.rawValue
        item.target = self
        return item
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

    /// Both pages, not only the one showing, so neither is left behind the other.
    @objc private func reloadPages() {
        reload(Page.allCases)
    }

    private func reload(_ pages: [Page]) {
        settle(pages) {
            for page in pages {
                self.load(page)
            }
        }
    }

    /// Opening the panel after a while away reloads both pages, so what changed on the phone or
    /// the site meanwhile, and any new version of the pages, is there without ⌘R. The clock
    /// keeps running while the Mac sleeps. Only on opening, never while the panel is in use.
    /// Returns whether it's reloading.
    private func reloadIfAway() -> Bool {
        guard Date().timeIntervalSince(panel.hiddenAt) >= Self.reloadAfter,
              network.currentPath.status == .satisfied
        else { return false }
        for page in Page.allCases {
            webViews[page]!.evaluateJavaScript(Self.dialogOpen) { open, _ in
                if open as? Bool != true {
                    self.reload([page])
                }
            }
        }
        return true
    }

    // MARK: - Panel

    private func setUpPanel() {
        panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

        // Both pages load now and stay loaded, stacked, with only the current one showing.
        let container = NSView()
        for page in Page.allCases {
            let webView = WKWebView(frame: container.bounds, configuration: configuration)
            webView.autoresizingMask = [.width, .height]
            webView.navigationDelegate = self
            webView.uiDelegate = self
            if #available(macOS 13.3, *) {
                webView.isInspectable = true
            }
            container.addSubview(webView)
            webViews[page] = webView
            load(page)
        }
        panel.contentView = container

        switcher = NSSegmentedControl(
            labels: Page.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(switchPage(_:))
        )
        switcher.controlSize = .small
        switcher.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        switcher.sizeToFit()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: switcher.frame.width + 12, height: 28))
        switcher.frame.origin = NSPoint(x: 4, y: (holder.frame.height - switcher.frame.height) / 2)
        holder.addSubview(switcher)
        accessory.view = holder
        panel.addTitlebarAccessoryViewController(accessory)

        show(page)

        panel.setFrameAutosaveName("MacNotesPanel")
        if panel.frame.origin == .zero {
            panel.center()
        }
    }

    private func load(_ page: Page) {
        loadFailed.remove(page)
        webViews[page]!.load(URLRequest(url: page.url))
    }

    /// Puts `page` in front, without opening or closing the panel.
    private func show(_ page: Page) {
        self.page = page
        for (other, webView) in webViews {
            webView.isHidden = other != page
        }
        panel.title = page.title
        switcher.selectedSegment = Page.allCases.firstIndex(of: page)!
        for item in statusItem?.menu?.items ?? [] where item.representedObject != nil {
            item.state = item.representedObject as? String == page.rawValue ? .on : .off
        }
        if loadFailed.contains(page) {
            load(page)
        }
        if panel.isVisible {
            panel.makeFirstResponder(webView)
        }
    }

    @objc private func switchPage(_ sender: NSSegmentedControl) {
        show(Page.allCases[sender.selectedSegment])
    }

    /// From ⌘1/⌘2 or the menu bar: that page, with the panel open on it.
    @objc private func showPage(_ sender: NSMenuItem) {
        guard let page = Page(rawValue: sender.representedObject as? String ?? "") else { return }
        show(page)
        if !panel.isVisible {
            togglePanel()
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            if !reloadIfAway(), loadFailed.contains(page) {
                load(page)
            }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(webView)
        }
    }

    // MARK: - Web view

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "hide", message.webView == webView {
            panel.orderOut(nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showUnreachable(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showUnreachable(webView, error)
    }

    private func showUnreachable(_ webView: WKWebView, _ error: Error) {
        // A navigation replaced by another one isn't a failure worth a page.
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard let page = webViews.first(where: { $0.value == webView })?.key else { return }
        loadFailed.insert(page)
        let host = page.url.host ?? "the site"
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
        if url.scheme == "about" || Self.sameSite(url.host, Page.notes.url.host) {
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
        let toggle = NSMenuItem(title: "Show/Hide Panel", action: #selector(togglePanel), keyEquivalent: ".")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        menu.addItem(toggle)
        for page in Page.allCases {
            let item = pageItem(page)
            item.state = page == self.page ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(withTitle: "Reload", action: #selector(reloadPages), keyEquivalent: "").target = self
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
