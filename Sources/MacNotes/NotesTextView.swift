import AppKit

/// Plain-text editor that draws `---` lines as rules between notes, and shows a
/// copy button on the note under the mouse.
///
/// Uses TextKit 1: `NotesEditor` touches `layoutManager` right after creating it,
/// which switches the view over. Everything here waits for that.
final class NotesTextView: NSTextView {
    private(set) var notes: [Note] = []
    private var dividers: [NSRange] = []

    private lazy var copyNoteButton: IconButton = {
        let button = IconButton(symbol: "doc.on.doc", label: "Copy this note", target: self, action: #selector(copyHoveredNote))
        button.drawsBackground = true
        button.isHidden = true
        addSubview(button)
        return button
    }()
    private var hoveredNote: Int?

    private var textKit1LayoutManager: NSLayoutManager? {
        textLayoutManager == nil ? layoutManager : nil
    }

    /// Re-reads the notes from the text. Call after setting `string` directly.
    func refreshNotes() {
        (notes, dividers) = Notes.parse(string as NSString)
        updateDividerVisibility()
        needsDisplay = true
    }

    override func didChangeText() {
        refreshNotes()
        hideCopyNoteButton()
        super.didChangeText()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateDividerVisibility()
    }

    // MARK: - Dividers

    /// The `---` is hidden and drawn as a rule, except while the selection touches it.
    private func isRevealed(_ divider: NSRange) -> Bool {
        let dashes = NSRange(location: divider.location, length: 3)
        let selection = selectedRange()
        return selection.location <= NSMaxRange(dashes) && NSMaxRange(selection) >= dashes.location
    }

    private func updateDividerVisibility() {
        guard let layoutManager = textKit1LayoutManager else { return }
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        // Dividers can be stale for a moment while text is changing.
        for divider in dividers where NSMaxRange(divider) <= length && !isRevealed(divider) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: divider)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = textKit1LayoutManager, let textContainer, !dividers.isEmpty else { return }

        let glyphs = layoutManager.glyphRange(
            forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y),
            in: textContainer
        )
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (string as NSString).length
        let left = textContainerOrigin.x + textContainer.lineFragmentPadding
        let right = textContainerOrigin.x + textContainer.size.width - textContainer.lineFragmentPadding

        NSColor.separatorColor.setFill()
        for divider in dividers
        where NSMaxRange(divider) <= length
            && divider.location >= chars.location && divider.location <= NSMaxRange(chars)
            && !isRevealed(divider) {
            let line = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: divider.location),
                effectiveRange: nil
            )
            let y = line.midY + textContainerOrigin.y
            backingAlignedRect(NSRect(x: left, y: y, width: right - left, height: 1), options: .alignAllEdgesNearest).fill()
        }
    }

    /// Top of the line holding `location`, in this view's coordinates.
    func lineTop(forCharacterAt location: Int) -> CGFloat {
        guard let layoutManager = textKit1LayoutManager else { return 0 }
        let length = (string as NSString).length
        let line: NSRect
        if location < length {
            line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil)
        } else if !layoutManager.extraLineFragmentRect.isEmpty {
            line = layoutManager.extraLineFragmentRect
        } else if length > 0 {
            line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
        } else {
            line = .zero
        }
        return line.minY + textContainerOrigin.y
    }

    // MARK: - New note

    /// Starts a new note at the top, or moves to the top note if it's still empty.
    func startNewNote() {
        if let first = notes.first,
           !(string as NSString).substring(with: first.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Its own undo step, separate from the typing before and after.
            breakUndoCoalescing()
            insertText("\n\(Notes.divider)\n", replacementRange: NSRange(location: 0, length: 0))
            breakUndoCoalescing()
        }
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
    }

    func text(of note: Note) -> String {
        (string as NSString).substring(with: note.range).trimmingCharacters(in: .newlines)
    }

    var currentNote: Note? {
        notes.isEmpty ? nil : notes[Notes.index(containing: selectedRange().location, in: notes)]
    }

    // MARK: - Hover copy button

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["notes"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["notes": true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard notes.count > 1 else { return hideCopyNoteButton() }

        let point = convert(event.locationInWindow, from: nil)
        let index = Notes.index(containing: characterIndexForInsertion(at: point), in: notes)
        guard index != hoveredNote || copyNoteButton.isHidden else { return }
        hoveredNote = index

        let size = copyNoteButton.intrinsicContentSize
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 14)) ?? size.height
        let top = lineTop(forCharacterAt: notes[index].range.location)
        copyNoteButton.frame = NSRect(
            x: bounds.width - textContainerInset.width - size.width,
            y: top + (lineHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        copyNoteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideCopyNoteButton()
    }

    private func hideCopyNoteButton() {
        copyNoteButton.isHidden = true
        hoveredNote = nil
    }

    @objc private func copyHoveredNote() {
        guard let index = hoveredNote, notes.indices.contains(index) else { return }
        copyToPasteboard(text(of: notes[index]))
        copyNoteButton.flashCheckmark()
    }
}
