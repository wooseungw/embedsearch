import SwiftUI

/// The "클립보드" settings tab: recording on or off, its hotkey, and clearing what is kept.
struct ClipboardSettingsView: View {
    @Bindable var settings: AppSettings
    let hotKeys: HotKeyController
    let history: ClipboardHistory

    var body: some View {
        Form {
            Section("클립보드 기록") {
                Toggle("복사한 텍스트 기록", isOn: Binding(get: { settings.clipboardHistoryEnabled }, set: setEnabled))
                    .toggleStyle(SettingsToggleStyle())
                Text("""
                    최근 \(ClipboardHistory.capacity)개를 이 Mac의 메모리에만 보관합니다. 디스크에 저장하지 않으므로 앱을 끄면 사라집니다. \
                    같은 텍스트를 다시 복사하거나 기록에서 고르면 새로 쌓이지 않고 목록 맨 위(최신)로 올라갑니다. \
                    비밀번호 관리자가 숨김으로 표시한 복사와 Finder의 파일 복사는 기록하지 않습니다.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem = history.problem, settings.clipboardHistoryEnabled {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("보관 중") {
                    HStack {
                        Text("\(history.count)개")
                            .monospacedDigit()
                        Button("기록 지우기") { history.removeAll() }
                            .disabled(history.count == 0)
                    }
                }
            }
            Section("단축키") {
                Picker("기록 열기", selection: Binding(get: { settings.clipboardHotKey }, set: { hotKeys.use($0) })) {
                    ForEach(KeyCombo.clipboardPresets, id: \.self) { combo in
                        Text(combo.displayString).tag(combo)
                    }
                    if !KeyCombo.clipboardPresets.contains(settings.clipboardHotKey) {
                        Text("\(settings.clipboardHotKey.displayString) (직접 지정)").tag(settings.clipboardHotKey)
                    }
                }
                .disabled(!settings.clipboardHistoryEnabled)
                HStack {
                    Text("다른 조합")
                    Spacer()
                    HotKeyRecorderView(hotKeys: hotKeys)
                        .disabled(!settings.clipboardHistoryEnabled)
                }
                LabeledContent("상태") {
                    Text(settings.clipboardHistoryEnabled ? hotKeys.statusText : "꺼짐")
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                }
                Text("검색창(\(settings.hotKey.displayString))에서 ‘클립보드’를 입력해도 열 수 있고, 일반 검색에도 일치하는 기록이 4번째 줄부터 최대 3개 끼어 나옵니다. ↵는 복사, ⌃X는 기록에서 삭제입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setEnabled(_ enabled: Bool) {
        settings.clipboardHistoryEnabled = enabled
        history.setEnabled(enabled)
        if enabled {
            hotKeys.registerFromSettings(interactive: true)
        } else {
            hotKeys.unregister()
        }
    }

    private var isFailure: Bool {
        switch hotKeys.status {
        case .failed, .clashes: return true
        default: return false
        }
    }
}
