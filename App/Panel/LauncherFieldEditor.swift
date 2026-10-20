import AppKit
import Carbon.HIToolbox

/// Field editor of the launcher search field (installed via `windowWillReturnFieldEditor`).
///
/// It exists for Hangul input: AppKit's text-change notifications don't say whether marked text is
/// present, and a plain SwiftUI `TextField` can't tell a composition-committing Return from a real
/// one. This editor reports `(text, hasMarkedText)` after every text or marked-text change and
/// remembers whether a key-down started while composing, so the Return/Escape that only ends a
/// composition is never treated as "open"/"close".
final class LauncherFieldEditor: NSTextView {
    /// Text (including marked text) and whether a composition is active, after every change.
    var onInputChange: ((_ text: String, _ composing: Bool) -> Void)?
    /// Editing commands (`moveUp:`, `insertNewline:`, `cancelOperation:` …) outside a composition.
    /// Return true to consume the command.
    var onCommand: ((Selector) -> Bool)?
    /// Return/Enter pressed while composing: the IME has committed the text by the time this runs.
    var onComposingReturn: (() -> Void)?
    /// ⌃N (+1) / ⌃P (−1), resolved by physical key so the Korean layout can't remap them.
    var onControlNavigation: ((Int) -> Void)?
    /// ⌃X (by physical key): remove the selected clipboard entry. Return true to consume it.
    var onControlX: (() -> Bool)?

    /// True while handling a key-down that began with marked text.
    private(set) var keyDownBeganComposing = false

    /// Commands an IME may pass through after committing; they must not act on the panel.
    private static let commandsSwallowedAfterComposition: Set<Selector> = [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        #selector(NSResponder.cancelOperation(_:)),
    ]

    override func keyDown(with event: NSEvent) {
        let composing = hasMarkedText()
        if !composing, let delta = Self.controlNavigationDelta(for: event) {
            onControlNavigation?(delta)
            return
        }
        if !composing, Self.isControlX(event), onControlX?() == true {
            return
        }
        keyDownBeganComposing = composing
        defer { keyDownBeganComposing = false }
        super.keyDown(with: event)
        if composing, Self.isReturn(event) {
            onComposingReturn?()
        }
    }

    override func doCommand(by selector: Selector) {
        if keyDownBeganComposing, Self.commandsSwallowedAfterComposition.contains(selector) {
            return
        }
        if onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportInput()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportInput()
    }

    override func unmarkText() {
        super.unmarkText()
        reportInput()
    }

    override func didChangeText() {
        super.didChangeText()
        reportInput()
    }

    /// Replace the whole text programmatically (clear on Esc / hide), dropping any composition.
    func replaceAll(with newText: String) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        string = newText
        reportInput()
    }

    private func reportInput() {
        onInputChange?(string, hasMarkedText())
    }

    static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    static func isControlX(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .control
            && Int(event.keyCode) == kVK_ANSI_X
    }

    static func controlNavigationDelta(for event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .control else { return nil }
        switch Int(event.keyCode) {
        case kVK_ANSI_N: return 1
        case kVK_ANSI_P: return -1
        default: return nil
        }
    }
}
