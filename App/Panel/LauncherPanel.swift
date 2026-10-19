import AppKit
import Carbon.HIToolbox

/// Borderless, non-activating panel above the menu bar. It takes key status (so the search field
/// gets typing) without activating the app, so the previously active app keeps its focus state.
final class LauncherPanel: NSPanel {
    /// ⌘-key equivalents (⌘1–9, ⌘,). Return true when handled.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onCommandKeyChange: ((Bool) -> Void)?
    /// Esc when the search field is not first responder.
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // drawn by SwiftUI so it follows the animated shape
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow the frame to overlap the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        // An agent app has no Edit menu, so route the standard editing shortcuts ourselves
        // (by physical key, so they work with the Korean layout too).
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let action: Selector?
        switch (Int(event.keyCode), flags) {
        case (kVK_ANSI_A, .command): action = #selector(NSText.selectAll(_:))
        case (kVK_ANSI_C, .command): action = #selector(NSText.copy(_:))
        case (kVK_ANSI_V, .command): action = #selector(NSText.paste(_:))
        case (kVK_ANSI_X, .command): action = #selector(NSText.cut(_:))
        case (kVK_ANSI_Z, .command): action = Selector(("undo:"))
        case (kVK_ANSI_Z, [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        onCommandKeyChange?(event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
