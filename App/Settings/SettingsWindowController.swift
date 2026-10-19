import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()
    private let makeView: (SettingsNavigation) -> SettingsView

    init(makeView: @escaping (SettingsNavigation) -> SettingsView) {
        self.makeView = makeView
    }

    /// Shows the window, on `tab` when given (else where it was left), in front on the screen the
    /// user is working on.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        // The window keeps its frame between shows; bring it to the screen under the mouse (where
        // the panel just was) unless it is already open there.
        let screen = ActiveScreen.current
        if !(window.isVisible && window.screen == screen) {
            window.setFrameOrigin(ActiveScreen.origin(for: window.frame.size, on: screen))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app opened from its non-activating panel may not be activated (cooperative
        // activation, macOS 14+): show the window on top anyway; a click on it activates the app.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeView(navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = "EmbedSearch 설정"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Sized now, not at first layout, so it can be centered before it is shown.
        window.setContentSize(SettingsView.size)
        self.window = window
        return window
    }
}
