import SearchCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, folders, clipboard, engine
}

/// Which tab the settings window shows (the menu's "검색 폴더…" opens it on `.folders`).
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// Settings in tabs, each short enough to fit any screen (one long form ran past the bottom of a
/// 14" display, hiding the sections at its end).
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var navigation: SettingsNavigation
    let hotKeys: HotKeyController
    let clipboardHotKeys: HotKeyController
    let clipboard: ClipboardHistory
    let launchAtLogin: LaunchAtLogin
    let query: QueryController
    let onPreview: () -> Void

    static let size = CGSize(width: 600, height: 560)

    var body: some View {
        TabView(selection: $navigation.tab) {
            Form {
                hotKeySection
                appearanceSection
                generalSection
            }
            .formStyle(.grouped)
            .tabItem { Label("일반", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            SearchFoldersView(settings: settings, runtime: AppServices.runtime, engineState: query.engineState)
                .tabItem { Label("검색 폴더", systemImage: "folder") }
                .tag(SettingsTab.folders)

            ClipboardSettingsView(settings: settings, hotKeys: clipboardHotKeys, history: clipboard)
                .tabItem { Label("클립보드", systemImage: "doc.on.clipboard") }
                .tag(SettingsTab.clipboard)

            Form { engineSection }
                .formStyle(.grouped)
                .tabItem { Label("검색 엔진", systemImage: "magnifyingglass") }
                .tag(SettingsTab.engine)
        }
        .padding(.top, 6)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { launchAtLogin.refresh() }
    }

    private var hotKeySection: some View {
        Section("단축키") {
            Picker("열기/닫기", selection: Binding(get: { settings.hotKey }, set: { hotKeys.use($0) })) {
                ForEach(KeyCombo.presets, id: \.self) { combo in
                    Text(combo.displayString).tag(combo)
                }
                if !KeyCombo.presets.contains(settings.hotKey) {
                    Text("\(settings.hotKey.displayString) (직접 지정)").tag(settings.hotKey)
                }
            }
            HStack {
                Text("다른 조합")
                Spacer()
                HotKeyRecorderView(hotKeys: hotKeys)
            }
            LabeledContent("상태") {
                Text(hotKeys.statusText)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
            }
            ForEach(hotKeys.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if settings.hotKey == .optionSpace {
                Text("⌥Space를 등록하면 다른 앱에서 ⌥Space로 줄바꿈 없는 공백을 입력할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("모양") {
            Picker("표시 스타일", selection: $settings.panelStyle) {
                Text("노치 스타일 — 노치에서 펼쳐짐").tag(PanelStyle.notch)
                Text("클래식(Raycast) 스타일 — 화면 위쪽 18%").tag(PanelStyle.classic)
            }
            .pickerStyle(.radioGroup)
            LabeledContent("패널 너비") {
                HStack {
                    Slider(value: $settings.panelWidth,
                           in: Double(PanelLayout.panelWidthRange.lowerBound)...Double(PanelLayout.panelWidthRange.upperBound),
                           step: 20)
                        .frame(width: 220)
                    Text("\(Int(settings.panelWidth)) pt")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            HStack {
                Text("노치가 없는 화면에서는 화면 위쪽 가운데에 붙어서 펼쳐집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("미리 보기", action: onPreview)
            }
        }
    }

    private var generalSection: some View {
        Section("일반") {
            Toggle("로그인 시 실행", isOn: Binding(get: { launchAtLogin.isEnabled },
                                              set: { launchAtLogin.setEnabled($0) }))
            LabeledContent("상태") {
                Text(launchAtLogin.statusText).foregroundStyle(.secondary)
            }
            if launchAtLogin.status == .requiresApproval {
                Button("로그인 항목 설정 열기") { launchAtLogin.openSystemSettings() }
            }
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var engineSection: some View {
        Section("검색 엔진") {
            LabeledContent("상태", value: DisplayText.engineState(query.engineState))
            if case .degraded(let reason) = query.engineState {
                LabeledContent("원인", value: reason)
            }
            LabeledContent("검색 서비스", value: AppServices.serviceDescription)
            LabeledContent("모델", value: AppServices.modelDescription)
            HStack {
                Spacer()
                Button("다시 색인") { query.refreshIndex() }
            }
        }
    }

    private var isFailure: Bool {
        switch hotKeys.status {
        case .failed, .clashes: return true
        default: return false
        }
    }
}
