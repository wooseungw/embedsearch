import Foundation
import os
import SearchCore

/// The single place that decides which `SearchService` the app talks to: SearchCore's
/// `SearchEngine` over the index database (run by `EngineRuntime`), or `MockSearchService` with
/// `--mock` / `--mock-slow` / `--mock-degraded`. The UI only sees `any SearchService`, including
/// `stateUpdates()` for the footer.
@MainActor
enum AppServices {
    /// Seconds without use after which the embedding model is released. Override with
    /// `defaults write com.seungwoo.embedsearch modelIdleSeconds 60` or `-modelIdleSeconds 60`.
    static let defaultModelIdleSeconds: Double = 180

    private(set) static var serviceDescription = ""
    private(set) static var modelDescription = ""
    /// The real engine's runtime (nil with the mock): file search settings talk to it.
    private(set) static var runtime: EngineRuntime?
    private static let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "app")

    static func makeSearchService(arguments: [String] = CommandLine.arguments, folders: [String] = []) -> any SearchService {
        if arguments.contains(where: { $0.hasPrefix("--mock") }) {
            return makeMock(arguments, description: "목업 (개발용, --mock)")
        }
        let store: IndexStore
        do {
            store = try IndexStore()
            serviceDescription = "SearchEngine · \(IndexStore.defaultURL.path(percentEncoded: false))"
        } catch {
            // Search still works over a fresh index; only usage history and the cache are lost.
            logger.error("index database unavailable: \(error.localizedDescription, privacy: .public)")
            guard let temporary = try? IndexStore.inMemory() else {
                return makeMock(arguments, description: "목업 — 색인 DB를 열지 못했습니다: \(error.localizedDescription)")
            }
            store = temporary
            serviceDescription = "SearchEngine · 메모리 DB (기본 DB 오류: \(error.localizedDescription))"
        }

        let seconds = UserDefaults.standard.double(forKey: "modelIdleSeconds")
        let idle = seconds > 0 ? seconds : defaultModelIdleSeconds
        modelDescription = "EmbeddingGemma 2 · MLX · 사용할 때만 로드 (전원 연결 시 패널을 열면 미리), \(durationText(idle)) 미사용 시 해제"
        let engine = SearchEngine(store: store, embedder: nil, sources: DefaultSources.all())
        let runtime = EngineRuntime(engine: engine, idleTimeout: .seconds(idle),
                                    folders: folders.map { URL(filePath: $0, directoryHint: .isDirectory) })
        runtime.start()
        self.runtime = runtime
        return engine
    }

    /// The panel is opening: loads the model ahead on external power, otherwise keeps a loaded one
    /// alive, or retries a failed first model load (`EngineRuntime.prepare`).
    static func panelWillShow() {
        runtime?.prepare()
    }

    private static func makeMock(_ arguments: [String], description: String) -> any SearchService {
        var options = MockSearchService.Options()
        if arguments.contains("--mock-slow") { options.startupScale = 8 }
        if arguments.contains("--mock-degraded") { options.degraded = true }
        serviceDescription = description
        modelDescription = "없음 (목업)"
        return MockSearchService(options: options)
    }

    private static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 && s % 60 == 0 ? "\(s / 60)분" : "\(s)초"
    }
}
