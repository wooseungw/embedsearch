import AppKit
import Carbon.HIToolbox

/// A global hotkey in Carbon terms (virtual key code + Carbon modifier mask).
struct KeyCombo: Hashable, Codable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let optionSpace = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    static let controlSpace = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))
    static let optionCommandSpace = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | cmdKey))
    static let controlOptionSpace = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))
    static let shiftCommandSpace = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(shiftKey | cmdKey))

    static let `default` = optionSpace
    static let presets: [KeyCombo] = [optionSpace, controlSpace, optionCommandSpace, controlOptionSpace, shiftCommandSpace]

    /// The clipboard history's. ⇧⌘V is left out: many apps paste without formatting with it.
    static let optionShiftV = KeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(optionKey | shiftKey))
    static let controlCommandV = KeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | cmdKey))
    static let controlOptionV = KeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey))
    static let clipboardDefault = optionShiftV
    static let clipboardPresets: [KeyCombo] = [optionShiftV, controlCommandV, controlOptionV]

    /// From a recorder key-down. Requires at least one of ⌃⌥⌘ (⇧ alone is not a hotkey).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// e.g. "⌥Space", "⌃⌥⇧⌘K" (Apple's modifier order).
    var displayString: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + Self.keyName(Int(keyCode))
    }

    /// An enabled macOS system shortcut (System Settings › Keyboard › Shortcuts) uses this combo,
    /// e.g. ⌃Space for "select previous input source". Registration still succeeds but never fires.
    var conflictingSystemShortcut: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return entries.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = entry["kHISymbolicHotKeyCode"] as? Int,
                  let modifiers = entry["kHISymbolicHotKeyModifiers"] as? Int else { return false }
            return UInt32(code) == keyCode && UInt32(modifiers) & relevant == carbonModifiers & relevant
        }
    }

    private static func keyName(_ code: Int) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: break
        }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        ]
        return letters[code] ?? "Key\(code)"
    }
}
