import AppKit
import Carbon.HIToolbox
import SwiftUI

/// "Record a shortcut" button for Settings. Captures the next key-down with ⌃/⌥/⌘ in our own
/// window via a local monitor (no permission needed); Esc cancels.
struct HotKeyRecorderView: View {
    let hotKeys: HotKeyController
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecording ? "키 조합을 누르세요… (esc 취소)" : "직접 지정…") {
                isRecording ? stop() : start()
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        isRecording = true
        hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isEscape = Int(event.keyCode) == kVK_Escape
            let combo = KeyCombo(event: event)
            MainActor.assumeIsolated { handleKey(isEscape: isEscape, combo: combo) }
            return nil // swallow every key while recording
        }
    }

    private func handleKey(isEscape: Bool, combo: KeyCombo?) {
        if isEscape {
            stop()
        } else if let combo {
            finish(with: combo)
        } else {
            hint = "⌃, ⌥, ⌘ 중 하나 이상을 함께 누르세요"
        }
    }

    private func finish(with combo: KeyCombo) {
        removeMonitor()
        isRecording = false
        hotKeys.use(combo)
    }

    private func stop() {
        guard isRecording else { return }
        removeMonitor()
        isRecording = false
        hotKeys.resume()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
