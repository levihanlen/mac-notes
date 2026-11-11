import AppKit
import Carbon.HIToolbox
import Network
import WebKit

// MacNotes is the hotkey and the floating panel. The panel shows one of two pages on
// levihanlen.com: /note in its list layout, or the /kb board. Each is the same as on the site and
// the phone, synced the way it syncs, typed into the same way. The pages keep their data in this
// app's own web storage, so a page that has loaded once still opens with no connection.
//
// ⌘Space opens the launcher, a second panel holding /launcher: the Mac's apps and the site's pages
// in one field, plus "n …" for a note and "t …" for a /kb card. The page does the searching and the
// writing; this side tells it which apps are installed and opens what it picks, and does what a
// web page can't: searching brain/ on disk, asking the dev server's git, keeping the clipboard's
// history, pasting into and moving the windows of the app in front, and posting notifications.

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

/// The ⌘Space window: a field and a list, high on the screen, gone the moment anything else is
/// clicked, the way Spotlight is.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
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
    WKScriptMessageHandler, NSWindowDelegate
{
    private var panel: NotesPanel!
    private var webViews: [Page: WKWebView] = [:]
    private var switcher: NSSegmentedControl!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var launcherHotKeyRef: EventHotKeyRef?
    private var launcher: LauncherPanel!
    private var launcherView: WKWebView!
    /// When /launcher last loaded, so a long-lived copy gets the site's newer version. Reloaded
    /// after hiding, never on opening, so opening stays instant.
    private var launcherLoadedAt = Date()
    private var launcherFailed = false
    /// The installed apps as last found, sent to the page each time it opens.
    private var installedApps: [[String: String]] = []
    /// Pages that couldn't be reached, so the next time the panel opens on one it tries again.
    private var loadFailed: Set<Page> = []
    /// Whether the Mac is online, so reloading on its own never swaps a page that works offline
    /// for one saying the site can't be reached.
    private let network = NWPathMonitor()
    private let brain = BrainSearch()
    private let clips = ClipHistory()
    private let notifier = Notifier()
    /// A note or card the launcher asked the panel to open, while that page was loading or about
    /// to reload. Handed to the page once it has loaded, if that's soon.
    private var pendingItems: [Page: (id: String, at: Date)] = [:]

    /// Away this long, and opening the panel reloads both pages.
    private static let reloadAfter: TimeInterval = 15 * 60
    /// Loaded this long, and the launcher reloads behind the scenes once it's put away.
    private static let launcherReloadAfter: TimeInterval = 60 * 60

    /// How long an item asked for while its page reloads still opens once it has.
    private static let pendingItemFor: TimeInterval = 15

    /// The launcher's size. The page is laid out for nine rows under its field.
    private static let launcherSize = NSSize(width: 640, height: 352)

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
        setUpLauncher()
        setUpStatusItem()
        registerHotKeys()
        refreshApps()
        network.start(queue: .main)
        clips.start()
        notifier.start()
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
        if message.name == "launcher" {
            handleLauncher(message.body)
            return
        }
        if message.body as? String == "hide", message.webView == webView {
            panel.orderOut(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = webViews.first(where: { $0.value == webView })?.key,
              let pending = pendingItems.removeValue(forKey: page),
              Date().timeIntervalSince(pending.at) < Self.pendingItemFor
        else { return }
        // The load event can come before the page's own listeners are on; a moment for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.openItem(pending.id, on: page)
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
        if webView == launcherView {
            launcherFailed = true
            webView.loadHTMLString(
                """
                <body style="font: 14px -apple-system; color: #888; padding: 24px">
                Couldn't reach the launcher page. It tries again the next time it opens.
                </body>
                """,
                baseURL: nil
            )
            return
        }
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
        let launch = NSMenuItem(title: "Show Launcher", action: #selector(toggleLauncher), keyEquivalent: " ")
        launch.keyEquivalentModifierMask = [.command]
        launch.target = self
        menu.addItem(launch)
        for page in Page.allCases {
            let item = pageItem(page)
            item.state = page == self.page ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(withTitle: "Reload", action: #selector(reloadPages), keyEquivalent: "").target = self
        if Self.hasOldNotes {
            menu.addItem(withTitle: "Show Old Notes in Finder", action: #selector(showOldNotes), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// The folder now also holds the clipboard history, so it's the old notes in it that count.
    private static var hasOldNotes: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: oldNotesDirectory.path)) ?? []
        return names.contains { $0 != ClipHistory.fileName && !$0.hasPrefix(".") }
    }

    @objc private func showOldNotes() {
        NSWorkspace.shared.open(Self.oldNotesDirectory)
    }

    // MARK: - Global hotkeys (⌥. and ⌘Space)

    private static let panelHotKey: UInt32 = 1
    private static let launcherHotKey: UInt32 = 2

    private func registerHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var hotKey = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKey
                )
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
                if hotKey.id == AppDelegate.launcherHotKey {
                    delegate.toggleLauncher()
                } else {
                    delegate.togglePanel()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        let signature = OSType(0x4D4E_5453) // "MNTS"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period),
            UInt32(optionKey),
            EventHotKeyID(signature: signature, id: Self.panelHotKey),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        // Spotlight's own ⌘Space has to be turned off in System Settings → Keyboard → Keyboard
        // Shortcuts → Spotlight, or it gets the keys first.
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            EventHotKeyID(signature: signature, id: Self.launcherHotKey),
            GetApplicationEventTarget(),
            0,
            &launcherHotKeyRef
        )
        if status != noErr {
            NSLog("MacNotes: couldn't take ⌘Space (\(status)); the launcher still opens from the menu bar.")
        }
    }

    // MARK: - Launcher

    private func setUpLauncher() {
        launcher = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.launcherSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        launcher.isFloatingPanel = true
        launcher.level = .modalPanel
        launcher.hidesOnDeactivate = false
        launcher.isReleasedWhenClosed = false
        launcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        launcher.hasShadow = true
        launcher.delegate = self

        let content = WKUserContentController()
        content.add(self, name: "launcher")
        let configuration = WKWebViewConfiguration()
        // The same storage as the notes and the board, so the sync password and the notes the
        // launcher writes into are theirs.
        configuration.websiteDataStore = .default()
        configuration.userContentController = content

        launcherView = WKWebView(frame: NSRect(origin: .zero, size: Self.launcherSize), configuration: configuration)
        launcherView.autoresizingMask = [.width, .height]
        launcherView.navigationDelegate = self
        launcherView.uiDelegate = self
        if #available(macOS 13.3, *) {
            launcherView.isInspectable = true
        }
        launcher.contentView = launcherView
        loadLauncher()
    }

    private var launcherURL: URL {
        URL(string: "/launcher", relativeTo: Page.notes.url)!.absoluteURL
    }

    private func loadLauncher() {
        launcherFailed = false
        launcherLoadedAt = Date()
        launcherView.load(URLRequest(url: launcherURL))
    }

    @objc func toggleLauncher() {
        if launcher.isVisible {
            launcher.orderOut(nil)
            return
        }
        if launcherFailed {
            loadLauncher()
        }
        // A fifth of the way down whichever screen the pointer is on, like Spotlight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            launcher.setFrameOrigin(NSPoint(
                x: area.midX - Self.launcherSize.width / 2,
                y: area.maxY - area.height * 0.2 - Self.launcherSize.height
            ))
        }
        launcher.makeKeyAndOrderFront(nil)
        launcher.makeFirstResponder(launcherView)
        sendToLauncher(opened: true)
        refreshApps()
    }

    /// Clicking anywhere else puts it away. A copy loaded long ago reloads then, out of sight.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? LauncherPanel === launcher else { return }
        launcher.orderOut(nil)
        if Date().timeIntervalSince(launcherLoadedAt) >= Self.launcherReloadAfter,
           network.currentPath.status == .satisfied
        {
            loadLauncher()
        }
    }

    private func handleLauncher(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            sendToLauncher(opened: launcher.isVisible)
        case "hide":
            launcher.orderOut(nil)
        case "open-app":
            guard let path = message["path"] as? String else { return }
            launcher.orderOut(nil)
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            )
        case "open-url":
            guard let string = message["url"] as? String, let url = URL(string: string) else { return }
            launcher.orderOut(nil)
            NSWorkspace.shared.open(url)
        case "show-panel":
            guard let page = Page(rawValue: message["page"] as? String ?? "") else { return }
            launcher.orderOut(nil)
            show(page)
            if !panel.isVisible {
                togglePanel()
            }
        case "open-item":
            guard let page = Page(rawValue: message["page"] as? String ?? ""),
                  let id = message["id"] as? String
            else { return }
            launcher.orderOut(nil)
            show(page)
            if !panel.isVisible {
                togglePanel()
            }
            // Now, and again once the page has loaded in case opening the panel reloads it.
            pendingItems[page] = (id, Date())
            if !webViews[page]!.isLoading {
                openItem(id, on: page)
            }
        case "copy":
            guard let text = message["text"] as? String else { return }
            putOnClipboard(text)
            launcher.orderOut(nil)
        case "paste":
            guard let text = message["text"] as? String else { return }
            putOnClipboard(text)
            launcher.orderOut(nil)
            // Without Accessibility it stays on the clipboard, for ⌘V by hand.
            if Accessibility.trusted() {
                // A moment for the keyboard to go back to the app in front.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Accessibility.pressPaste()
                }
            }
        case "window":
            guard let spot = message["spot"] as? String else { return }
            launcher.orderOut(nil)
            if Accessibility.trusted() {
                Accessibility.move(to: spot)
            }
        case "notify":
            let title = message["title"] as? String ?? ""
            let body = message["body"] as? String ?? ""
            // A path alone is on the site's origin.
            let url = (message["url"] as? String).flatMap { URL(string: $0, relativeTo: Page.notes.url)?.absoluteURL }
            notifier.post(title: title, body: body, url: url)
        case "request":
            answer(message)
        case "captured":
            // The panel's copy of that page catches up. Not while it's open and in use: its own
            // sync brings the new note or card in there.
            guard let page = Page(rawValue: message["page"] as? String ?? ""), !panel.isVisible else { return }
            webViews[page]!.evaluateJavaScript(Self.dialogOpen) { open, _ in
                if open as? Bool != true {
                    self.reload([page])
                }
            }
        default:
            break
        }
    }

    private func putOnClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Hands the page the note or card the launcher found, by id. The page listens for this.
    private func openItem(_ id: String, on page: Page) {
        guard let data = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webViews[page]!.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('open-item', { detail: { id: \(json) } }));"
        )
    }

    /// A question from the page. Each is answered, whatever happens, so the page never waits out
    /// its timeout for one MacNotes understood.
    private func answer(_ message: [String: Any]) {
        guard let id = message["id"] as? String else { return }
        let reply: (Result<Any, LauncherError>) -> Void = { [weak self] result in
            self?.reply(id, result)
        }
        let password = message["password"] as? String ?? ""
        switch message["kind"] as? String {
        case "brain-search":
            brain.search(message["query"] as? String ?? "") { result in
                reply(result.map { ["hits": $0] })
            }
        case "git-status":
            DevGit.status(password: password) { reply($0.map { $0 }) }
        case "git-commit":
            DevGit.commit(password: password, message: message["message"] as? String ?? "") { reply($0.map { $0 }) }
        case "clips":
            reply(.success(["clips": clips.answer]))
        case let kind:
            reply(.failure(LauncherError("MacNotes doesn't know \(kind ?? "that")")))
        }
    }

    /// Answers request `id` with a "launcher-reply" event: `{id, result}` or `{id, error}`.
    private func reply(_ id: String, _ result: Result<Any, LauncherError>) {
        var detail: [String: Any] = ["id": id]
        switch result {
        case let .success(value): detail["result"] = value
        case let .failure(error): detail["error"] = error.message
        }
        guard JSONSerialization.isValidJSONObject(detail),
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8)
        else { return }
        launcherView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('launcher-reply', { detail: \(json) }));"
        )
    }

    private func sendToLauncher(opened: Bool) {
        let detail: [String: Any] = ["apps": installedApps, "opened": opened]
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8)
        else { return }
        launcherView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('launcher-native', { detail: \(json) }));"
        )
    }

    /// Looks for apps off the main thread and tells the page if the list changed, so an app
    /// installed a minute ago turns up on the next opening rather than the next launch.
    private func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.findApps()
            DispatchQueue.main.async {
                guard found != self.installedApps else { return }
                self.installedApps = found
                self.sendToLauncher(opened: false)
            }
        }
    }

    /// Where apps live: each folder's .app bundles, and one folder down for suites kept in a
    /// folder of their own.
    private static func findApps() -> [[String: String]] {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let folders = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
        var paths: [String] = ["/System/Library/CoreServices/Finder.app"]
        for folder in folders {
            for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = "\(folder)/\(name)"
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if !name.hasPrefix("."), name != "Utilities",
                          let inner = try? files.contentsOfDirectory(atPath: path)
                {
                    paths += inner.filter { $0.hasSuffix(".app") }.map { "\(path)/\($0)" }
                }
            }
        }
        var seen: Set<String> = []
        var apps: [[String: String]] = []
        for path in paths {
            var name = files.displayName(atPath: path)
            if name.hasSuffix(".app") {
                name = String(name.dropLast(4))
            }
            // Hidden helpers (".Karabiner-VirtualHIDDevice-Manager") aren't for opening.
            guard !name.hasPrefix("."), seen.insert(name).inserted else { continue }
            apps.append(["name": name, "path": path])
        }
        return apps.sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
