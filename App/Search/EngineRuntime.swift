import EmbedCore
import EmbedMLX
import Foundation
import os
import SearchCore

/// Runs the real `SearchEngine` with EmbeddingGemma in memory only while it is used.
///
/// Startup: lexical search over the database at once (`loadFromStore`), then a source rescan
/// (`refresh`). The model's `EmbeddingModelInfo` (its vector space, part of the embedding cache
/// key) is remembered after the first load, so later launches serve hybrid search from cached
/// vectors and load the model only to embed a query that has no stored vector, or a new item.
/// `OnDemandEmbedder` releases it after `idleTimeout` without use. Opening the panel loads it
/// ahead only on external power outside Low Power Mode and not while indexing; otherwise it keeps
/// a loaded model alive and loads none, except to retry a first load that failed.
///
/// File search: the images and PDFs in `folders` are indexed with the vision model (loaded only
/// while there are files to index, released `visionIdleTimeout` after), and a `FolderWatcher`
/// re-syncs the index whenever a file in them is added, changed or removed.
@MainActor
final class EngineRuntime {
    let engine: SearchEngine
    let idleTimeout: Duration
    /// The vision model only indexes files, so it goes soon after the last one.
    let visionIdleTimeout: Duration = .seconds(30)
    private(set) var folders: [URL]
    private let configuration: MLXEmbedderConfiguration
    private let defaults: UserDefaults
    private var embedder: OnDemandEmbedder?
    private var imageEmbedder: OnDemandImageEmbedder?
    private var startup: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var watchGeneration = 0
    /// How PDFs are read, for Settings.
    private(set) var pdfReaderDescription = "확인 중…"
    private let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "engine")

    private static let infoKey = "embeddingModelInfo"

    init(engine: SearchEngine, idleTimeout: Duration, folders: [URL] = [],
         configuration: MLXEmbedderConfiguration = .default, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.idleTimeout = idleTimeout
        self.folders = folders
        self.configuration = configuration
        self.defaults = defaults
    }

    func start() {
        guard startup == nil else { return }
        watch()
        startup = Task {
            do {
                let days = defaults.integer(forKey: "searchHistoryRetentionDays")
                try await engine.setHistoryPolicy(enabled: defaults.object(forKey: "searchHistoryEnabled") as? Bool ?? true,
                                                  retentionDays: days > 0 ? days : 30)
            } catch { logger.error("history policy: \(error.localizedDescription, privacy: .public)") }
            await engine.setFileFolders(folders)
            await setUpPDFReader()
            let known = rememberedInfo()
            if let known {
                await install(info: known, preloaded: nil)
            } else {
                await engine.reportModelLoading(progress: 0)
            }
            let start = ContinuousClock.now
            await engine.loadFromStore()
            let (items, vectors) = (await engine.itemCount, await engine.vectorCount)
            logger.info("warm start: \(items) items, \(vectors) cached vectors in \(ContinuousClock.now - start)")
            // Embeds new or changed items, which loads the model only if there are any.
            let stats = await engine.refreshWithStats()
            logger.info("refresh: \(stats.totalItems) items, \(stats.embeddedNew) embedded, \(stats.sourceErrors.count) source errors")
            if known == nil { await loadModel() }
            startup = nil
        }
    }

    /// opendataloader-pdf from the app bundle with the newest installed Java 11+; PDFKit without them.
    private func setUpPDFReader() async {
        guard let jar = Bundle.main.url(forResource: "opendataloader-pdf-cli", withExtension: "jar", subdirectory: "opendataloader") else {
            pdfReaderDescription = "기본 방식 (PDFKit) — opendataloader-pdf가 앱에 없음"
            return
        }
        let reader = await Task.detached(priority: .utility) { OpenDataLoader.locate(jar: jar) }.value
        await engine.setPDFReader(reader)
        if let reader {
            let version = (try? String(contentsOf: jar.deletingLastPathComponent().appending(path: "VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pdfReaderDescription = "opendataloader-pdf \(version) (Java: \(reader.java.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)))"
            logger.info("PDFs: opendataloader-pdf with \(reader.java.path(percentEncoded: false), privacy: .public)")
        } else {
            pdfReaderDescription = "기본 방식 (PDFKit) — Java 11 이상이 없어 구조 분석을 쓰지 못함"
        }
    }

    /// Replaces the searched folders and syncs the index with them (indexing what is new, dropping
    /// what is no longer listed); returns when that refresh is done.
    func setFolders(_ folders: [URL]) async {
        self.folders = folders
        watch()
        await engine.setFileFolders(folders)
        await engine.refresh()
    }

    /// Rescans everything now (the menu's and Settings' "다시 색인", and folder changes).
    func syncNow() {
        let engine = engine
        Task { await engine.refresh() }
    }

    func reindexFiles(in folder: URL? = nil) async throws {
        try await engine.reindexFiles(in: folder)
    }

    func fileSummary() async -> FileIndexSummary {
        await engine.fileIndexSummary()
    }

    /// (Re)starts the folder watcher off the main thread: creating it can wait for the privacy prompt
    /// of a protected folder.
    private func watch() {
        watcher?.stop()
        watcher = nil
        watchGeneration += 1
        let generation = watchGeneration, folders = folders, engine = engine, logger = logger
        guard !folders.isEmpty else { return }
        Task {
            let created = await Task.detached(priority: .utility) {
                FolderWatcher(folders: folders, latency: 3) {
                    logger.info("files changed; syncing")
                    Task { await engine.refresh() }
                }
            }.value
            guard generation == watchGeneration else {
                created?.stop()
                return
            }
            watcher = created
        }
    }

    /// The panel opened: on external power outside Low Power Mode, load the model now so a query
    /// without a stored vector does not wait for it; otherwise only keep a loaded model for the
    /// coming queries (a query needs it only when its vector is neither cached nor stored,
    /// `SearchEngine`). Either restarts a loaded model's idle clock. Also retries a first model
    /// load that failed, on any power.
    func prepare() {
        if let embedder {
            let engine = engine, ahead = PowerSource.allowsWorkAhead, vision = imageEmbedder
            Task {
                // Not while indexing or while the vision model is still there: that one (~0.9 GB)
                // embeds the queries meanwhile (`OnDemandEmbedder.standIn`), so the text model
                // would only sit next to it.
                let indexing = if case .indexing = await engine.currentState { true } else { false }
                let visionLoaded = await vision?.isLoaded ?? false
                if ahead, !indexing, !visionLoaded {
                    await embedder.prepare()
                } else {
                    await embedder.keepAlive()
                }
            }
        } else if startup == nil {
            startup = Task {
                await loadModel()
                startup = nil
            }
        }
    }

    /// First launch (or a changed configuration): load the model to learn its vector space, then
    /// index with it. It is released after `idleTimeout` like any on-demand load.
    private func loadModel() async {
        let engine = engine
        // Progress goes through one ordered stream that is drained before the outcome is reported,
        // so a late update cannot turn `.degraded` back into `.loadingModel`.
        let (progress, sink) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let forwarder = Task {
            for await p in progress { await engine.reportModelLoading(progress: p) }
        }
        logger.info("loading \(self.configuration.modelID, privacy: .public)")
        let result: Result<MLXTextEmbedder, Error>
        do {
            result = .success(try await MLXTextEmbedder.load(configuration) { sink.yield($0) })
        } catch {
            result = .failure(error)
        }
        sink.finish()
        await forwarder.value

        switch result {
        case .success(let model):
            remember(model.info)
            await install(info: model.info, preloaded: model)
        case .failure(let error):
            logger.error("model load failed: \(error.localizedDescription, privacy: .public)")
            await engine.reportModelLoadFailure("모델을 불러오지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func install(info: EmbeddingModelInfo, preloaded: MLXTextEmbedder?) async {
        let imageEmbedder = makeImageEmbedder(info: info)
        let embedder = makeEmbedder(info: info, preloaded: preloaded, standIn: imageEmbedder)
        self.imageEmbedder = imageEmbedder
        self.embedder = embedder
        // Before the text embedder: installing that one indexes pending files, which uses this.
        await engine.setImageEmbedder(imageEmbedder)
        await engine.setEmbedder(embedder)
    }

    /// The vision model holds the text weights too and embeds every text while it is loaded
    /// (`OnDemandEmbedder.standIn`), so the text model goes when it comes: both held ~1.6 GB of
    /// GPU memory plus a tokenizer each. Releasing fails while a text embedding runs, so it is
    /// tried again once the vision model is in.
    private func makeImageEmbedder(info: EmbeddingModelInfo) -> OnDemandImageEmbedder {
        let configuration = configuration, logger = logger
        return OnDemandImageEmbedder(info: info, idleTimeout: visionIdleTimeout, load: { [weak self] in
            await self?.releaseTextModel()
            let start = ContinuousClock.now
            let model = try await MLXImageEmbedder.load(configuration)
            logger.info("vision model loaded in \(ContinuousClock.now - start)")
            await self?.releaseTextModel()
            return model
        }, didUnload: {
            MLXTextEmbedder.releaseCachedMemory()
            logger.info("vision model released after idle")
        })
    }

    private func releaseTextModel() async {
        guard let embedder, await embedder.unload() else { return }
        logger.info("text model released for the vision model")
    }

    private func makeEmbedder(info: EmbeddingModelInfo, preloaded: MLXTextEmbedder?,
                              standIn: OnDemandImageEmbedder) -> OnDemandEmbedder {
        let configuration = configuration, logger = logger
        return OnDemandEmbedder(info: info, idleTimeout: idleTimeout, preloaded: preloaded, standIn: standIn, load: { [weak self] in
            let start = ContinuousClock.now
            let model: MLXTextEmbedder
            do {
                model = try await MLXTextEmbedder.load(configuration)
            } catch {
                logger.error("on-demand model load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            logger.info("model loaded on demand in \(ContinuousClock.now - start)")
            if model.info != info { await self?.modelChanged(to: model) }
            return model
        }, didUnload: {
            MLXTextEmbedder.releaseCachedMemory()
            logger.info("model released after idle")
        })
    }

    /// A reload produced another vector space (the cached checkpoint was replaced): the old
    /// embedder rejects it, and the engine re-embeds everything with the new one.
    private func modelChanged(to model: MLXTextEmbedder) {
        logger.notice("embedding model changed to \(model.info.cacheKey, privacy: .public); re-indexing")
        remember(model.info)
        Task { await install(info: model.info, preloaded: model) }
    }

    private func rememberedInfo() -> EmbeddingModelInfo? {
        guard let data = defaults.data(forKey: Self.infoKey),
              let info = try? JSONDecoder().decode(EmbeddingModelInfo.self, from: data),
              info.modelID == configuration.modelID, info.dimensions == configuration.dimensions,
              info.promptVersion == EmbeddingPrompt.version
        else { return nil }
        return info
    }

    private func remember(_ info: EmbeddingModelInfo) {
        if let data = try? JSONEncoder().encode(info) { defaults.set(data, forKey: Self.infoKey) }
    }
}
