import AppKit
import Carbon.HIToolbox
import Observation

/// Registers the user's summon hotkey, tracks the result for Settings/menu, and offers alternatives
/// when registration fails.
@MainActor
@Observable
final class HotKeyController {
    enum Status: Equatable {
        case notRegistered
        case registered(KeyCombo)
        case failed(KeyCombo, OSStatus)
        case suspended
    }

    private(set) var status: Status = .notRegistered
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    private let settings: AppSettings
    private let center = HotKeyCenter.shared

    init(settings: AppSettings, onPressed: @escaping () -> Void) {
        self.settings = settings
        center.onPressed = onPressed
    }

    var statusText: String {
        switch status {
        case .notRegistered: return "등록 안 됨"
        case .registered(let combo): return "\(combo.displayString) 등록됨"
        case .failed(let combo, let code): return "\(combo.displayString): \(HotKeyCenter.describe(code))"
        case .suspended: return "녹화 중…"
        }
    }

    /// Warnings that registration can't detect: enabled system shortcuts and apps known to grab ⌥Space.
    var warnings: [String] {
        var out: [String] = []
        let combo = settings.hotKey
        if combo.conflictingSystemShortcut {
            out.append("\(combo.displayString)는 macOS 시스템 단축키(입력 소스 전환 등)와 겹쳐 동작하지 않을 수 있습니다.")
        }
        if combo == .optionSpace {
            let grabbers = ["com.openai.codex": "ChatGPT", "com.openai.chat": "ChatGPT", "com.anthropic.claudefordesktop": "Claude",
                            "com.raycast.macos": "Raycast"]
            let running = grabbers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.key).isEmpty }
            if !running.isEmpty {
                let names = Set(running.values).sorted().joined(separator: ", ")
                out.append("\(names) 앱도 ⌥Space를 쓸 수 있습니다. 반응하지 않으면 다른 단축키를 고르세요.")
            }
        }
        return out
    }

    /// Registers `settings.hotKey`. On failure optionally asks the user to pick an alternative.
    @discardableResult
    func registerFromSettings(interactive: Bool) -> Bool {
        let combo = settings.hotKey
        let code = center.register(combo)
        if code == noErr {
            status = .registered(combo)
            return true
        }
        status = .failed(combo, code)
        if interactive { presentFailureAlert(combo: combo, code: code) }
        return false
    }

    func use(_ combo: KeyCombo, interactive: Bool = true) {
        settings.hotKey = combo
        registerFromSettings(interactive: interactive)
    }

    /// While the Settings recorder listens, the current hotkey must not fire.
    func suspend() {
        center.unregister()
        status = .suspended
    }

    func resume() {
        registerFromSettings(interactive: false)
    }

    func unregister() {
        center.unregister()
        status = .notRegistered
    }

    private func presentFailureAlert(combo: KeyCombo, code: OSStatus) {
        let alternatives = KeyCombo.presets.filter { $0 != combo && !$0.conflictingSystemShortcut }.prefix(2)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "단축키 \(combo.displayString)를 등록하지 못했습니다"
        alert.informativeText = HotKeyCenter.describe(code) + "\n다른 단축키를 선택하세요. 설정에서 언제든 바꿀 수 있습니다."
        for alternative in alternatives {
            alert.addButton(withTitle: "\(alternative.displayString) 사용")
        }
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "나중에")
        let response = ActiveScreen.runModal(alert)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0 && index < alternatives.count {
            use(Array(alternatives)[index])
        } else if index == alternatives.count {
            onOpenSettings?()
        }
    }
}
