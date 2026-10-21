import AppKit

/// Thin strip on the right edge with one segment per note, sized by how much of
/// the document the note takes up. Hovering widens it into a list of note titles.
final class NoteRailView: NSView {
    static let collapsedWidth: CGFloat = 14
    private static let expandedWidth: CGFloat = 180
    private static let rowHeight: CGFloat = 24
    private static let listInset: CGFloat = 8

    struct Item {
        var title: String
        /// Where the note starts and ends, as fractions of the document's height.
        var top: CGFloat
        var bottom: CGFloat
    }

    var items: [Item] = [] {
        didSet {
            clampListOffset()
            needsDisplay = true
        }
    }
    /// The note holding the insertion point.
    var currentIndex = 0 {
        didSet { if currentIndex != oldValue { needsDisplay = true } }
    }
    /// The part of the document that's on screen, as fractions of its height.
    var viewport: ClosedRange<CGFloat> = 0...1 {
        didSet { if viewport != oldValue && !isExpanded { needsDisplay = true } }
    }
    var onSelect: ((Int) -> Void)?
    /// Scrolled when the wheel is used over the collapsed rail.
    weak var documentScrollView: NSScrollView?

    private var isExpanded = false
    private var widthConstraint: NSLayoutConstraint!
    private var expandTimer: Timer?
    private var hoveredRow: Int?
    private var listOffset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Expanding

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        hoveredRow = nil
        let available = (superview?.bounds.width ?? Self.expandedWidth) * 0.6
        widthConstraint.constant = expanded ? min(Self.expandedWidth, available) : Self.collapsedWidth
        if expanded { scrollCurrentRowIntoView() }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        // A short delay so the mouse passing by on its way to the window edge doesn't open it.
        expandTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.setExpanded(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        expandTimer?.invalidate()
        setExpanded(false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else { return }
        let row = rowIndex(at: convert(event.locationInWindow, from: nil))
        if row != hoveredRow {
            hoveredRow = row
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = isExpanded ? rowIndex(at: point) : segmentIndex(at: point) {
            onSelect?(index)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isExpanded, listHeight > bounds.height else {
            documentScrollView?.scrollWheel(with: event)
            return
        }
        listOffset -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.rowHeight
        clampListOffset()
        needsDisplay = true
    }

    // MARK: - Geometry

    private var listHeight: CGFloat {
        Self.listInset * 2 + CGFloat(items.count) * Self.rowHeight
    }

    private func clampListOffset() {
        listOffset = max(0, min(listOffset, listHeight - bounds.height))
    }

    private func scrollCurrentRowIntoView() {
        let row = rowRect(currentIndex)
        if row.minY < 0 || row.maxY > bounds.height {
            listOffset += row.midY - bounds.height / 2
            clampListOffset()
        }
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(
            x: 6,
            y: Self.listInset + CGFloat(index) * Self.rowHeight - listOffset,
            width: bounds.width - 12,
            height: Self.rowHeight - 2
        )
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        let index = Int(((point.y + listOffset - Self.listInset) / Self.rowHeight).rounded(.down))
        return items.indices.contains(index) ? index : nil
    }

    private func segmentIndex(at point: NSPoint) -> Int? {
        let fraction = point.y / max(bounds.height, 1)
        return items.lastIndex { $0.top <= fraction } ?? (items.isEmpty ? nil : 0)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        if isExpanded { drawList() } else { drawSegments() }
    }

    private func drawSegments() {
        let height = bounds.height
        NSColor.quaternaryLabelColor.setFill()
        NSRect(
            x: 1,
            y: viewport.lowerBound * height,
            width: bounds.width - 1,
            height: (viewport.upperBound - viewport.lowerBound) * height
        ).fill()

        for (index, item) in items.enumerated() {
            let top = item.top * height
            let segment = NSRect(x: 5, y: top, width: 5, height: max(item.bottom * height - top - 2, 2))
            (index == currentIndex ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawList() {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12)

        for (index, item) in items.enumerated() {
            let row = rowRect(index)
            guard row.intersects(bounds) else { continue }
            if index == currentIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            } else if index == hoveredRow {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            let color: NSColor = index == currentIndex ? .labelColor : .secondaryLabelColor
            (item.title as NSString).draw(
                with: NSRect(x: row.minX + 8, y: row.midY - 8, width: row.width - 16, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
            )
        }
    }
}
