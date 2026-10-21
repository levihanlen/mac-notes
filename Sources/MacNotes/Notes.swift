import AppKit

/// One note: the text between two divider lines. A divider is a line that is exactly `---`.
struct Note {
    /// The note's text, not including the divider lines around it.
    var range: NSRange
    var title: String
}

enum Notes {
    static let divider = "---"

    /// Splits `text` into notes, and returns the divider lines (each including its line break).
    static func parse(_ text: NSString) -> (notes: [Note], dividers: [NSRange]) {
        var dividers: [NSRange] = []
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, enclosingRange, _ in
            if lineRange.length == 3, text.substring(with: lineRange) == divider {
                dividers.append(enclosingRange)
            }
        }

        var notes: [Note] = []
        var start = 0
        for end in dividers + [NSRange(location: text.length, length: 0)] {
            let range = NSRange(location: start, length: end.location - start)
            notes.append(Note(range: range, title: title(of: text.substring(with: range))))
            start = NSMaxRange(end)
        }
        return (notes, dividers)
    }

    /// Index of the note holding `location`. A divider line counts as part of the note above it.
    static func index(containing location: Int, in notes: [Note]) -> Int {
        notes.lastIndex { $0.range.location <= location } ?? 0
    }

    /// First non-blank line, trimmed.
    private static func title(of text: String) -> String {
        var title = "Empty note"
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                title = String(trimmed.prefix(80))
                stop = true
            }
        }
        return title
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Borderless SF Symbol button.
final class IconButton: NSButton {
    private let symbolName: String
    /// Paints a background behind the icon, for buttons that sit on top of text.
    var drawsBackground = false

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        symbolName = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        symbolConfiguration = .init(pointSize: 13, weight: .regular)
        contentTintColor = .secondaryLabelColor
        toolTip = label
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    /// Briefly swaps the icon for a checkmark.
    func flashCheckmark() {
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        }
    }
}
