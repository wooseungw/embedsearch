import AppKit

/// The screen the user is working on: the one under the mouse. Every window and alert the app opens
/// goes there; AppKit's default (the main display) puts them on another monitor than the panel that
/// opened them.
@MainActor
enum ActiveScreen {
    static var current: NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Horizontally centered, a little above the middle (like `NSWindow.center()`), inside the
    /// screen's visible area.
    static func origin(for size: CGSize, on screen: NSScreen = current) -> CGPoint {
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + max(0, (visible.height - size.height) * 0.6)
        return CGPoint(x: max(visible.minX, x), y: min(y, visible.maxY - size.height))
    }

    /// `alert.runModal()` on the current screen: `NSAlert.runModal` always centers on the main
    /// display, while a laid-out alert window run with `NSApp.runModal(for:)` stays where it is put
    /// and its buttons still end the session with their response.
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.layout()
        alert.window.setFrameOrigin(origin(for: alert.window.frame.size))
        NSApp.activate()
        alert.window.orderFrontRegardless()
        let response = NSApp.runModal(for: alert.window)
        alert.window.orderOut(nil)
        return response
    }
}
