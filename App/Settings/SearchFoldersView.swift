import AppKit
import SearchCore
import SwiftUI

/// The "검색 폴더" settings tab: the folders whose images and PDFs are searchable, each with its
/// index state and disk use. Folders are added with "폴더 추가…", the quick buttons for the usual
/// folders, or by dropping them from Finder; every way first shows what the folder would add (from a
/// scan of its file names) and asks to confirm.
struct SearchFoldersView: View {
    @Bindable var settings: AppSettings
    let runtime: EngineRuntime?
    let engineState: EngineState

    @State private var summary = FileIndexSummary()
    @State private var proposal: Proposal?
    @State private var removal: String?
    @State private var isEstimating = false
    @State private var isDropTargeted = false
    @State private var notice: String?

    /// Folders waiting for confirmation, with their estimates.
    struct Proposal: Identifiable {
        let id = UUID()
        let folders: [URL]
        let estimates: [FileIndexSummary.Folder]
    }

    /// Folders most people want searched, offered as one-click additions.
    static let suggestions: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .desktopDirectory,
                                                                 .documentDirectory, .picturesDirectory]

    var body: some View {
        Form {
            if runtime == nil {
                Section {
                    Text("목업 검색 서비스에서는 사용할 수 없습니다.").foregroundStyle(.secondary)
                }
            } else {
                foldersSection
                storageSection
                aboutSection
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            propose(folders)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: TaskKey(state: engineState, folders: settings.searchFolders)) { await reload() }
        .alert(proposalTitle, isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } }),
               presenting: proposal) { proposal in
            Button("추가") { add(proposal.folders) }
            Button("취소", role: .cancel) {}
        } message: { proposal in
            Text(Self.proposalMessage(proposal.estimates))
        }
        .confirmationDialog("이 폴더를 검색에서 뺄까요?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            presenting: removal) { path in
            Button("빼기", role: .destructive) { remove(path) }
        } message: { _ in
            Text("이 폴더의 색인 데이터가 삭제되어 저장 공간이 줄어듭니다. 다시 추가하면 처음부터 색인합니다.")
        }
    }

    // MARK: Sections

    private var foldersSection: some View {
        Section {
            if settings.searchFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("아직 검색할 폴더가 없습니다.")
                    Text("폴더를 추가하면 그 안의 이미지와 PDF를 이름뿐 아니라 내용으로도 찾을 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(settings.searchFolders, id: \.self) { path in
                FolderRow(path: path, entry: summary.folders.first { $0.path == Self.folderKey(path) }) { removal = path }
            }
            HStack {
                Button("폴더 추가…", action: chooseFolders)
                if !availableSuggestions.isEmpty {
                    Menu("빠른 추가") {
                        ForEach(availableSuggestions, id: \.self) { url in
                            Button(FileManager.default.displayName(atPath: url.path(percentEncoded: false))) { propose([url]) }
                        }
                    }
                    .fixedSize()
                }
                if isEstimating {
                    ProgressView().controlSize(.small)
                    Text("폴더를 살펴보는 중…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("지금 동기화") { runtime?.syncNow() }.disabled(settings.searchFolders.isEmpty)
            }
            .disabled(isEstimating)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("검색할 폴더")
        } footer: {
            Text("Finder에서 폴더를 이 창으로 끌어다 놓아도 추가됩니다. 하위 폴더까지 함께 검색합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("저장 공간과 동기화") {
            LabeledContent("사용 중") {
                Text(Self.bytes(summary.bytes)).foregroundStyle(.secondary)
            }
            if summary.pending > 0 {
                LabeledContent("색인 대기") {
                    Text("\(summary.pending)개 · 남은 시간 약 \(Self.duration(summary.pendingSeconds)) · 완료 시 약 \(Self.bytes(summary.estimatedBytes))")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("상태") {
                Text(DisplayText.engineState(engineState)).foregroundStyle(.secondary)
            }
            Text("폴더 안의 이미지·PDF가 추가되거나 바뀌거나 지워지면 몇 초 안에 자동으로 다시 색인합니다. 색인하는 동안에는 모델이 메모리에 올라오고(최대 약 3GB), 끝나면 내려갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("찾는 방법") {
            Label("사진·이미지: 그림 자체와 그 안의 글자 (png, jpg, heic, gif, webp, tiff, bmp)", systemImage: "photo")
            Label("PDF: 전체 쪽을 제목·목차·초록과 문단 단위로 (머리말·꼬리말·참고문헌 제외), 글자가 없는 쪽은 글자 인식", systemImage: "doc.richtext")
            if let runtime {
                Label("PDF 읽기: \(runtime.pdfReaderDescription)", systemImage: "gearshape.2")
            }
            Label("숨김 파일, 앱·사진 보관함 같은 패키지 안, iCloud에만 있는 파일은 건너뜁니다", systemImage: "eye.slash")
            Label("모든 처리는 이 Mac 안에서만 이뤄집니다", systemImage: "lock")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private var currentFolders: [URL] {
        settings.searchFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// The suggested folders that exist and are not already searched (themselves or by a parent).
    private var availableSuggestions: [URL] {
        Self.suggestions.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
            .filter { FileScanner.folder(of: $0.path(percentEncoded: false) + "/", in: currentFolders) == nil }
    }

    private func reload() async {
        guard let runtime else { return }
        summary = await runtime.fileSummary()
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "선택"
        panel.message = "이미지와 PDF를 검색할 폴더를 고르세요."
        // As a sheet on the settings window, so it opens on that window's screen (a standalone
        // open panel goes to the main display).
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title == "EmbedSearch 설정" }) else {
            if panel.runModal() == .OK { propose(panel.urls) }
            return
        }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .OK { propose(panel.urls) }
            }
        }
    }

    /// Estimates `urls` (off the main thread: reading a protected folder can wait for the privacy
    /// prompt) and asks to confirm.
    private func propose(_ urls: [URL]) {
        let chosen = urls.filter { FileScanner.folder(of: $0.path(percentEncoded: false) + "/", in: currentFolders) == nil }
        notice = chosen.count < urls.count ? "이미 검색 중인 폴더(또는 그 안의 폴더)는 건너뛰었습니다." : nil
        guard !chosen.isEmpty else { return }
        isEstimating = true
        Task {
            let estimates = await Task.detached(priority: .userInitiated) {
                chosen.map { FileIndexSummary.estimate(folder: $0) }
            }.value
            isEstimating = false
            proposal = Proposal(folders: chosen, estimates: estimates)
        }
    }

    private func add(_ folders: [URL]) {
        let normalized = FileScanner.normalized(currentFolders + folders)
        settings.searchFolders = normalized.map { $0.path(percentEncoded: false) }
        apply(normalized)
    }

    private func remove(_ path: String) {
        settings.searchFolders.removeAll { $0 == path }
        apply(currentFolders)
    }

    /// Hands the folders to the engine and shows the outcome once its refresh is done (an
    /// unreadable folder changes neither the items nor the engine state).
    private func apply(_ folders: [URL]) {
        guard let runtime else { return }
        Task {
            await runtime.setFolders(folders)
            await reload()
        }
    }

    // MARK: Formatting

    private var proposalTitle: String {
        guard let proposal else { return "" }
        let names = proposal.folders.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
        return names.count == 1 ? "‘\(names[0])’ 폴더를 검색에 추가할까요?" : "폴더 \(names.count)개를 검색에 추가할까요?"
    }

    static func proposalMessage(_ estimates: [FileIndexSummary.Folder]) -> String {
        let images = estimates.reduce(0) { $0 + $1.images }
        let documents = estimates.reduce(0) { $0 + $1.documents }
        let totalBytes = estimates.reduce(0) { $0 + $1.estimatedBytes }
        let seconds = estimates.reduce(0) { $0 + $1.pendingSeconds }
        var lines = ["이미지 \(images)개 · PDF \(documents)개"]
        if images + documents == 0 {
            lines.append("지금은 검색할 파일이 없습니다. 나중에 들어오는 파일은 자동으로 색인됩니다.")
        } else {
            lines.append("예상 추가 저장 공간: 약 \(bytes(totalBytes))")
            lines.append("처음 색인 예상 시간: 약 \(duration(seconds)) (그동안 모델 메모리 최대 약 3GB)")
            lines.append("이후에는 바뀐 파일만 다시 색인합니다.")
        }
        for estimate in estimates {
            if let error = estimate.error { lines.append("읽을 수 없음: \(error)") }
        }
        return lines.joined(separator: "\n")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "1분 미만" : "\(Int((seconds / 60).rounded()))분"
    }

    /// How a folder is keyed in the summary (standardized, with a trailing slash).
    static func folderKey(_ path: String) -> String {
        FileScanner.normalized([URL(filePath: path, directoryHint: .isDirectory)]).first?.path(percentEncoded: false) ?? path
    }

    private struct TaskKey: Equatable {
        let state: EngineState
        let folders: [String]
    }
}

private struct FolderRow: View {
    let path: String
    let entry: FileIndexSummary.Folder?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(FileManager.default.displayName(atPath: path))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(entry?.error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }) {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 보기")
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("검색에서 빼기")
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        guard let entry else { return "확인 중…" }
        if let error = entry.error { return "읽을 수 없음: \(error)" }
        var parts = ["이미지 \(entry.images) · PDF \(entry.documents)"]
        if entry.files == 0 {
            parts.append("파일 없음")
        } else if entry.pending > 0 {
            parts.append("색인 \(entry.indexed)/\(entry.files)")
        } else {
            parts.append("동기화됨")
        }
        if entry.failed > 0 { parts.append("내용을 읽지 못함 \(entry.failed)") }
        parts.append(SearchFoldersView.bytes(entry.bytes))
        return parts.joined(separator: " · ")
    }
}
