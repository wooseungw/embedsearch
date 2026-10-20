import AppKit
import SwiftUI

/// The first-launch introduction's window, on the screen the user is working on. Closing it in
/// any way counts as done: it is not shown again by itself.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: (_ finish: @escaping (Bool) -> Void) -> OnboardingView
    private let onClose: (_ openPanel: Bool) -> Void
    private var openPanelOnClose = false

    init(makeView: @escaping (_ finish: @escaping (Bool) -> Void) -> OnboardingView,
         onClose: @escaping (_ openPanel: Bool) -> Void) {
        self.makeView = makeView
        self.onClose = onClose
    }

    func show() {
        // A fresh view each time, from its first step.
        let window = self.window ?? makeWindow()
        window.contentViewController = NSHostingController(rootView: makeView { [weak self] openPanel in
            self?.openPanelOnClose = openPanel
            self?.window?.close()
        })
        window.setContentSize(OnboardingView.size)
        window.setFrameOrigin(ActiveScreen.origin(for: window.frame.size, on: ActiveScreen.current))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app may not get activated (cooperative activation): on top anyway.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: OnboardingView.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "EmbedSearch 시작하기"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        let openPanel = openPanelOnClose
        openPanelOnClose = false
        // Lets go of the view (and the folders tab's state) until it is opened again.
        window?.contentViewController = nil
        onClose(openPanel)
    }
}
