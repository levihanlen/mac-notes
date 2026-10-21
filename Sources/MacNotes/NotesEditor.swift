import AppKit

/// The panel's content: the notes text view with the note rail on its right.
final class NotesEditor: NSView {
    let textView: NotesTextView
    private let scrollView: NSScrollView
    private let rail = NoteRailView()
    private var railTimer: Timer?

    init() {
        scrollView = NotesTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NotesTextView else { fatalError() }
        textView = tv
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 380))

        // Touching layoutManager switches the view to TextKit 1, which the divider drawing uses.
        _ = textView.layoutManager
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 10)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The rail shows where you are, so a scroller next to it would just be a second bar.
        scrollView.hasVerticalScroller = false
        addSubview(scrollView)
        addSubview(rail)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The rail overlaps the text when it widens, so the text never reflows.
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -NoteRailView.collapsedWidth),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rail.documentScrollView = scrollView
        rail.onSelect = { [weak self] index in self?.jump(toNote: index) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scheduleRailUpdate), name: NSText.didChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(scheduleRailUpdate), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(updateRailPosition), name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(updateRailPosition), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ text: String) {
        textView.string = text
        textView.refreshNotes()
        updateRail()
    }

    func jump(toNote index: Int) {
        guard textView.notes.indices.contains(index) else { return }
        let location = textView.notes[index].range.location
        textView.setSelectedRange(NSRange(location: location, length: 0))
        // Leave a little room above so the rule before the note shows.
        textView.scroll(NSPoint(x: 0, y: max(textView.lineTop(forCharacterAt: location) - 24, 0)))
        window?.makeFirstResponder(textView)
    }

    // MARK: - Rail

    @objc private func scheduleRailUpdate() {
        railTimer?.invalidate()
        railTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.updateRail()
        }
    }

    private func updateRail() {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = max(textView.bounds.height, 1)
        let notes = textView.notes
        let tops = notes.map { textView.lineTop(forCharacterAt: $0.range.location) / height }
        rail.items = notes.indices.map { i in
            NoteRailView.Item(title: notes[i].title, top: tops[i], bottom: i + 1 < tops.count ? tops[i + 1] : 1)
        }
        updateRailPosition()
    }

    @objc private func updateRailPosition() {
        let height = max(textView.bounds.height, 1)
        let visible = scrollView.contentView.bounds
        let top = min(max(visible.minY / height, 0), 1)
        rail.viewport = top...max(top, min(visible.maxY / height, 1))
        rail.currentIndex = Notes.index(containing: textView.selectedRange().location, in: textView.notes)
    }
}
