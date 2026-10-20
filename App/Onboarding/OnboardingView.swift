import AppKit
import SearchCore
import SwiftUI

/// First-launch introduction: what the app does, the model download, the folders to search, and
/// launching at login. Shown once on a new install (no index yet) and from the menu bar's
/// "시작 안내…". The model starts downloading at launch; this only shows how far it got.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, model, folders, login, done
    }

    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let query: QueryController
    let onRetryModel: () -> Void
    /// `openPanel`: the last step's "검색창 열기".
    let onFinish: (_ openPanel: Bool) -> Void

    @State private var step: Step = .welcome

    static let size = CGSize(width: 640, height: 600)
    /// `model.safetensors` + tokenizer of mlx-community/embeddinggemma-2-bf16.
    static let downloadSize = "약 1.5 GB"

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .model: model
                case .folders: folders
                case .login: login
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { launchAtLogin.refresh() }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 36)
            Text("EmbedSearch에 오신 것을 환영합니다")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                point("command", "\(settings.hotKey.displayString)를 누르면 어디서든 검색창이 열립니다.")
                point("sparkle.magnifyingglass", "앱, 시스템 설정, 명령, 파일을 이름으로도, 하고 싶은 일로도 찾습니다. ‘화면 밝기’로 디스플레이 설정을, 내용을 설명하는 말로 PDF를 찾는 식입니다.")
                point("lock.shield", "검색은 모두 이 Mac 안에서 이뤄집니다. 검색어와 파일 내용은 밖으로 나가지 않습니다.")
            }
            .frame(maxWidth: 460, alignment: .leading)
            Text("처음 쓰기 전에 몇 가지만 준비합니다.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 40)
    }

    private var model: some View {
        stepPage(title: "의미 검색 모델 받기",
                 subtitle: "이름이 달라도 뜻으로 찾으려면 임베딩 모델(EmbeddingGemma 2, \(Self.downloadSize))이 필요합니다. 처음 한 번만 받고, 이후에는 인터넷 없이 동작합니다.") {
            VStack(alignment: .leading, spacing: 14) {
                modelStatus
                Text("받는 동안에도 이름으로 찾는 검색은 바로 쓸 수 있습니다. 이 창을 닫거나 다음 단계로 가도 계속 받습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("모델은 검색할 때만 메모리에 올리고, 3분 동안 쓰지 않으면 내립니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch query.engineState {
        case .loadingModel(let progress) where progress < 1:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text(progress > 0 ? "받는 중… \(Int(progress * 100))%" : "받기 시작하는 중…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loadingModel, .idle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("모델을 불러오는 중…").foregroundStyle(.secondary)
            }
        case .indexing(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                Label("모델 준비 완료", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("검색할 항목을 색인하는 중… \(done) / \(total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("모델이 준비됐습니다", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        case .degraded(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("모델을 받지 못했습니다", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("다시 시도", action: onRetryModel)
            }
        }
    }

    private var folders: some View {
        VStack(spacing: 0) {
            header(title: "검색할 폴더 고르기",
                   subtitle: "고른 폴더 안의 PDF와 이미지를 이름뿐 아니라 내용으로도 찾습니다. 건너뛰어도 되고, 설정에서 언제든 바꿀 수 있습니다.")
                .padding(.horizontal, 32)
                .padding(.top, 24)
            SearchFoldersView(settings: settings, runtime: AppServices.runtime, engineState: query.engineState)
        }
    }

    private var login: some View {
        stepPage(title: "로그인할 때 실행",
                 subtitle: "Mac을 켜면 EmbedSearch가 메뉴 막대에서 바로 기다리도록 합니다. 쉬는 동안에는 CPU를 쓰지 않습니다.") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("로그인 시 실행", isOn: Binding(get: { launchAtLogin.isEnabled },
                                                  set: { launchAtLogin.setEnabled($0) }))
                    .toggleStyle(.switch)
                Text(launchAtLogin.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if launchAtLogin.status == .requiresApproval {
                    Button("로그인 항목 설정 열기") { launchAtLogin.openSystemSettings() }
                }
                if let error = launchAtLogin.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private var done: some View {
        stepPage(title: "준비됐습니다", subtitle: "이렇게 쓰면 됩니다.") {
            VStack(alignment: .leading, spacing: 12) {
                point("command", "\(settings.hotKey.displayString): 검색창 열기·닫기")
                point("return", "↵: 열기 · ⌘1–9: N번째 결과 열기 · esc: 지우기, 닫기")
                point("doc.on.clipboard", "\(settings.clipboardHotKey.displayString) 또는 검색창에서 ⇥: 최근 복사한 텍스트")
                point("doc.richtext", "PDF 결과: ⌘Y 미리보기 · ⌘↵ Finder에서 보기 · ⌘C 경로 복사")
                point("gearshape", "설정(⌘,)에서 단축키, 폴더, 모양을 바꿀 수 있습니다. 메뉴 막대의 ‘시작 안내…’로 이 안내를 다시 볼 수 있습니다.")
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    // MARK: Pieces

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("이전") { move(-1) }
            }
            if step == .done {
                Button("닫기") { onFinish(false) }
                Button("검색창 열기") { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .folders && settings.searchFolders.isEmpty ? "건너뛰기" : "다음") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private func move(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    private func stepPage(title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: title, subtitle: subtitle)
            content()
        }
        .padding(.horizontal, 48)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
