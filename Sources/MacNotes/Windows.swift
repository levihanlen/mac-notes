import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What MacNotes does inside other apps: pressing ⌘V for a pasted clip, and moving the front
/// window. Both go through Accessibility, which macOS grants per app in System Settings → Privacy
/// & Security → Accessibility. The launcher is a non-activating panel, so while it's up the app
/// that was in front is still the frontmost app, and that's the one these act on.
enum Accessibility {
    private static var prompted = false

    /// Whether MacNotes may press keys and move windows. The first time it may not, macOS is
    /// asked to show its prompt, once per launch, so a missing grant says so without nagging.
    static func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !prompted {
            prompted = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// ⌘V, as if typed, into whatever has the keyboard.
    static func pressPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Windows

    /// Moves the focused window of the frontmost app to `spot`, one of the launcher's
    /// WINDOW_SPOTS, on the screen it's mostly on.
    static func move(to spot: String) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // A hung app shouldn't hang MacNotes with it.
        AXUIElementSetMessagingTimeout(app, 1)

        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute),
              let position = point(window),
              let extent = size(window),
              let primary = NSScreen.screens.first
        else {
            NSLog("MacNotes: no window to move in \(front.localizedName ?? "the front app")")
            return
        }

        let frame = flipped(CGRect(origin: position, size: extent), primary)
        guard let screen = screen(for: frame), let target = place(frame, spot, in: screen.visibleFrame) else { return }
        let goal = flipped(target, primary)

        // Chrome, Firefox and some Electron apps animate or refuse moves while this is on (set by
        // assistive apps), so it's off for the move and back after.
        let enhanced = "AXEnhancedUserInterface" as CFString
        var wasEnhanced: CFTypeRef?
        let restore = AXUIElementCopyAttributeValue(app, enhanced, &wasEnhanced) == .success
            && (wasEnhanced as? Bool) == true
        if restore {
            AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse)
        }

        // Position, size, then position again: an app that keeps a window on screen may have
        // clamped the first move against the old size.
        set(window, goal.origin)
        set(window, goal.size)
        set(window, goal.origin)

        if restore {
            AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue)
        }
    }

    /// Where `frame` goes for `spot` within `area`, all in AppKit's coordinates (origin bottom left).
    private static func place(_ frame: CGRect, _ spot: String, in area: CGRect) -> CGRect? {
        let half = area.width / 2
        let third = area.width / 3
        let rect: CGRect
        switch spot {
        case "left": rect = CGRect(x: area.minX, y: area.minY, width: half, height: area.height)
        case "right": rect = CGRect(x: area.minX + half, y: area.minY, width: half, height: area.height)
        case "top": rect = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case "bottom": rect = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case "left third": rect = CGRect(x: area.minX, y: area.minY, width: third, height: area.height)
        case "middle third": rect = CGRect(x: area.minX + third, y: area.minY, width: third, height: area.height)
        case "right third": rect = CGRect(x: area.minX + 2 * third, y: area.minY, width: third, height: area.height)
        case "left two thirds": rect = CGRect(x: area.minX, y: area.minY, width: 2 * third, height: area.height)
        case "right two thirds": rect = CGRect(x: area.minX + third, y: area.minY, width: 2 * third, height: area.height)
        case "max": rect = area
        case "center":
            let width = min(frame.width, area.width)
            let height = min(frame.height, area.height)
            rect = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        default:
            NSLog("MacNotes: no window spot called \(spot)")
            return nil
        }
        // Whole points, so two halves meet without a gap or an overlap.
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }

    /// Accessibility measures from the top left of the primary screen, downward; AppKit from its
    /// bottom left, upward. The same flip goes either way.
    private static func flipped(_ rect: CGRect, _ primary: NSScreen) -> CGRect {
        CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen holding most of `frame`, or the one under its middle, or the main one.
    private static func screen(for frame: CGRect) -> NSScreen? {
        let overlaps = NSScreen.screens.map { screen -> (NSScreen, CGFloat) in
            let shared = screen.frame.intersection(frame)
            return (screen, shared.isNull ? 0 : shared.width * shared.height)
        }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(middle) } ?? NSScreen.main
    }

    // MARK: - AX values

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        var point = CGPoint.zero
        guard let raw = value(element, kAXPositionAttribute), AXValueGetValue(raw, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var size = CGSize.zero
        guard let raw = value(element, kAXSizeAttribute), AXValueGetValue(raw, .cgSize, &size) else { return nil }
        return size
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    private static func set(_ element: AXUIElement, _ origin: CGPoint) {
        var origin = origin
        guard let wrapped = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, wrapped)
    }

    private static func set(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        guard let wrapped = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, wrapped)
    }
}
