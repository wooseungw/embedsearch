import SearchCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, folders, clipboard, engine, updates
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
    @State private var confirmingHistoryDeletion = false
    @State private var historyNotice: String?
    @State private var reindexing = false
    @Bindable var settings: AppSettings
    @Bindable var navigation: SettingsNavigation
    let hotKeys: HotKeyController
    let clipboardHotKeys: HotKeyController
    let clipboard: ClipboardHistory
    let launchAtLogin: LaunchAtLogin
    let updater: Updater
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

            Form { updateSection }
                .formStyle(.grouped)
                .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
        .padding(.top, 6)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: settings.searchHistoryEnabled) { _, _ in applyHistoryPolicy() }
        .onChange(of: settings.searchHistoryRetentionDays) { _, _ in applyHistoryPolicy() }
        .confirmationDialog("모든 검색 기록을 삭제할까요?", isPresented: $confirmingHistoryDeletion) {
            Button("검색 기록 삭제", role: .destructive) {
                Task {
                    do {
                        try await AppServices.runtime?.engine.clearHistory()
                        historyNotice = "검색 기록과 검색 캐시를 삭제했습니다."
                    } catch { historyNotice = "삭제하지 못했습니다: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("검색어와 실행 이력, 검색 속도를 위한 캐시를 지웁니다. 파일 색인은 유지됩니다.")
        }
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
                .toggleStyle(SettingsToggleStyle())
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
            Toggle("검색 기록 저장 및 개인화", isOn: $settings.searchHistoryEnabled)
                .toggleStyle(SettingsToggleStyle())
                .disabled(AppServices.runtime == nil)
            Picker("기록 보관 기간", selection: $settings.searchHistoryRetentionDays) {
                Text("7일").tag(7)
                Text("30일").tag(30)
                Text("90일").tag(90)
                Text("1년").tag(365)
            }
            .disabled(AppServices.runtime == nil)
            Text("선택한 검색어와 실행 항목을 이 Mac에 보관해 자주 찾는 결과를 먼저 보여줍니다. 끄면 새 기록과 검색 캐시를 저장하지 않습니다. 기존 기록은 보관 기간에 따라 지우거나 아래에서 모두 삭제할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Button("모든 검색 기록 삭제…") { confirmingHistoryDeletion = true }
                .disabled(AppServices.runtime == nil)
            if let historyNotice { Text(historyNotice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("다시 색인") {
                    guard let runtime = AppServices.runtime else { query.refreshIndex(); return }
                    reindexing = true
                    Task {
                        defer { reindexing = false }
                        do {
                            try await runtime.reindexFiles()
                            historyNotice = "파일을 다시 색인했습니다."
                        } catch { historyNotice = "다시 색인하지 못했습니다: \(error.localizedDescription)" }
                    }
                }.disabled(reindexing)
            }
        }
    }

    private func applyHistoryPolicy() {
        guard let runtime = AppServices.runtime else { return }
        let enabled = settings.searchHistoryEnabled, days = settings.searchHistoryRetentionDays
        Task {
            do {
                try await runtime.engine.setHistoryPolicy(enabled: enabled, retentionDays: days)
                historyNotice = nil
            } catch { historyNotice = "기록 설정을 적용하지 못했습니다: \(error.localizedDescription)" }
        }
    }

    private var updateSection: some View {
        Section("업데이트") {
            Toggle("자동 업데이트", isOn: Binding(get: { updater.isAutomatic }, set: { updater.setAutomatic($0) }))
                .toggleStyle(SettingsToggleStyle())
            Text("하루 한 번 새 버전을 확인해 받아 두고, 앱을 종료할 때 설치합니다. 받아 둔 업데이트가 설치되지 않은 채로 있으면 7일마다 한 번 묻습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("현재 버전", value: updater.version)
            HStack {
                Spacer()
                Button("지금 확인") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
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
