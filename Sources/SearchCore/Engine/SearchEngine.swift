import EmbedCore
import Foundation

/// Outcome of one `refresh()`; the CLI prints it, the App may log it.
public struct IndexStats: Sendable {
    public var itemCounts: [ItemKind: Int] = [:]
    public var sourceCounts: [String: Int] = [:]
    public var sourceErrors: [String: String] = [:]
    public var sourceSeconds: [String: Double] = [:]
    public var sync = ItemSyncSummary()
    public var modelKey: String?
    public var embeddedNew = 0
    public var embeddingCacheHits = 0
    public var vectorCount = 0
    public var embeddingError: String?
    public var scanSeconds = 0.0
    public var embedSeconds = 0.0
    /// File versions whose content was embedded in this refresh, and how many had no readable content.
    public var filesIndexed = 0
    public var fileErrors = 0
    public var fileChunks = 0
    public var fileSeconds = 0.0
    /// Indexed file versions read again because their text was not kept (indexed before keyword search).
    public var fileTextsRead = 0
    public var imageEmbeddingError: String?
    /// PDFs read with opendataloader-pdf (the rest of the PDFs used PDFKit).
    public var pdfsStructured = 0
    public var totalItems: Int { itemCounts.values.reduce(0, +) }
}

/// The real `SearchService`: sources → store → lexical + vector indexes → hybrid ranking.
///
/// Lexical search works as soon as items are loaded (`loadFromStore()` or `refresh()`); semantic search
/// needs an embedder (`init(embedder:)` or `setEmbedder(_:)`). Without one, or when it fails,
/// the state is `.degraded` and `fullSearch` returns lexical-only results.
///
/// Files: images and PDFs in `fileFolders` are items too (`FileScanner`). Their content is embedded
/// as several chunks per file (`FileContentExtractor`; pixels need an `ImageEmbedder`) into a
/// `ChunkIndex`, whose matches are fused as their own list. The text of those chunks is also kept
/// for keyword search (`IndexStore.keywordMatches`, no model needed), fused as another list.
public actor SearchEngine: SearchService {
    public nonisolated let store: IndexStore
    private let sources: [any ItemSource]
    public private(set) var config: RankingConfig
    private var embedder: (any TextEmbedder)?
    private var imageEmbedder: (any ImageEmbedder)?

    /// Items in source order; `position` maps an id to its index, `hashes` holds each item's
    /// `IndexStore.contentHash` (computed once per install).
    private var items: [SearchItem] = []
    private var position: [String: Int32] = [:]
    private var hashes: [String] = []
    /// Bumped by every install, so an embedding batch that resumes after one re-maps its hashes.
    private var generation = 0
    private var lexical = LexicalIndex(items: [])
    private var vectors: VectorIndex?
    private var usage: [String: UsageRecord] = [:]
    private var memory = QueryMemoryIndex()

    private var state: EngineState = .idle
    private var modelLoadProgress: Double?
    private var semanticFailure: String?
    private var isIndexing = false
    private var continuations: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var runningRefresh: Task<IndexStats, Never>?
    /// A refresh was requested while one ran: run once more when it finishes (it may have scanned
    /// before the change).
    private var refreshAgain = false
    private var queryVectorCache: [String: [Float]] = [:]
    private var queryVectorOrder: [String] = []
    private let now: @Sendable () -> Date
    private var fileRetryTask: Task<Void, Never>?
    private var historyEnabled = true
    private var historyRetentionDays = 30
    private var historyGeneration = 0
    private var historyLastPruned: Date?

    /// Folders whose images and PDFs are searchable.
    public private(set) var fileFolders: [URL] = []
    private var fileScanErrors: [String: String] = [:]
    /// Content vectors of the current file items (current model) and the item ids they cover,
    /// including files without content.
    private var chunks: ChunkIndex?
    private var indexedFiles = Set<String>()
    /// Some items are files: results then go through `ResultSections`.
    private var hasFileItems = false
    /// Positions of the file items by content hash (keyword matches are by file version).
    private var filePositions: [String: [Int32]] = [:]
    /// Applications by their names (normalized): the title, the English name (subtitle) and the
    /// bundle's file name — not aliases ("로그" for Console) or categories ("유틸리티"). A query that
    /// is exactly an app's name puts that app first.
    private var appsByExactName: [String: [Int32]] = [:]
    /// Index records of the current file versions (current model), by content hash.
    private var fileRecords: [String: FileIndexRecord] = [:]
    private var probeVectors: (key: String, vectors: [[Float]])?
    /// Image embedding kept failing (see `VisionUse`): images are skipped until then, and the files
    /// indexed without them meanwhile are redone after it.
    private var imagesUnavailableUntil: ContinuousClock.Instant?
    public private(set) var imageRetryInterval: Duration = .seconds(600)
    private var imagesUsable: Bool { imagesUnavailableUntil.map { ContinuousClock.now >= $0 } ?? true }

    /// Items embedded per `embed` call during indexing (progress granularity).
    public var embeddingBatchSize = 32
    /// Files read and embedded per round (progress granularity; bounds decoded images in memory).
    public var fileBatchSize = 8
    public private(set) var fileContent = FileContentExtractor()
    /// Reads PDFs with structure (opendataloader-pdf); without it PDFKit's text is used.
    public private(set) var pdfReader: OpenDataLoader?
    /// Recent query vectors kept so Enter after a debounced search does not re-embed.
    private let queryVectorCacheSize = 256
    /// Query vectors are read from and saved to the store (`IndexStore.queryVector`).
    public private(set) var storesQueryVectors = true

    public init(store: IndexStore, embedder: (any TextEmbedder)?, sources: [any ItemSource],
                config: RankingConfig = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.embedder = embedder
        self.sources = sources
        self.config = config
        self.now = now
    }

    /// Engine over the default database location and the default sources.
    public static func makeDefault(embedder: (any TextEmbedder)? = nil) throws -> SearchEngine {
        SearchEngine(store: try IndexStore(), embedder: embedder, sources: DefaultSources.all())
    }

    // MARK: Configuration

    public func setConfig(_ config: RankingConfig) { self.config = config }

    /// Saving off also disables personal ranking and on-disk query vectors; RAM query caching remains available.
    public func setHistoryPolicy(enabled: Bool, retentionDays: Int) throws {
        let days = min(365, max(1, retentionDays))
        historyGeneration += 1
        historyEnabled = enabled
        historyRetentionDays = days
        if !enabled { usage = [:]; memory = QueryMemoryIndex() }
        queryVectorCache.removeAll()
        queryVectorOrder.removeAll()
        try store.pruneHistory(before: now().addingTimeInterval(-Double(days) * 86_400))
        refreshUsage()
    }

    public func clearHistory() throws {
        historyGeneration += 1 // an embedding already awaiting the model cannot repopulate the cache
        try store.resetUsage()
        usage.removeAll()
        memory = QueryMemoryIndex()
        queryVectorCache.removeAll()
        queryVectorOrder.removeAll()
    }

    private func expireHistoryIfNeeded() {
        if historyLastPruned.map({ now().timeIntervalSince($0) >= 3_600 || now() < $0 }) ?? true {
            historyGeneration += 1
            queryVectorCache.removeAll()
            queryVectorOrder.removeAll()
            refreshUsage()
        }
    }

    /// Installs (or removes) the embedder, e.g. after the App finished loading the model in the
    /// background. Embeds whatever is missing from the cache — through `refreshWithStats`, so it
    /// never runs alongside a refresh's indexing — then becomes `.ready`.
    public func setEmbedder(_ embedder: (any TextEmbedder)?) async {
        self.embedder = embedder
        modelLoadProgress = nil
        semanticFailure = nil
        queryVectorCache.removeAll()
        queryVectorOrder.removeAll()
        vectors = nil
        chunks = nil
        indexedFiles = []
        fileRecords = [:]
        if embedder != nil, !items.isEmpty {
            await refreshWithStats()
        }
        settleState()
    }

    /// Installs (or removes) the image embedder. Files indexed without one get their images at the
    /// next refresh.
    public func setImageEmbedder(_ embedder: (any ImageEmbedder)?) {
        imageEmbedder = embedder
        imagesUnavailableUntil = nil
        if embedder != nil { redoPartialFiles() }
    }

    /// How long images are skipped after the image embedder kept failing.
    public func setImageRetryInterval(_ interval: Duration) {
        imageRetryInterval = interval
    }

    /// Files indexed without their images are read again at the next indexing.
    private func redoPartialFiles() {
        let partial = Set(fileRecords.filter { needsFileRetry($0.value) }.keys)
        guard !partial.isEmpty else { return }
        let redo = Set(zip(items, hashes).filter { $0.0.kind == .file && partial.contains($0.1) }.map(\.0.id))
        indexedFiles.subtract(redo)
        chunks?.removeAll { redo.contains($0) }
    }

    private func needsFileRetry(_ record: FileIndexRecord) -> Bool {
        if record.retryable { return record.shouldRetry(at: now()) && imagesUsable }
        return record.partial && imageEmbedder != nil && imagesUsable
    }

    /// A forced rebuild waits for the current indexing job before invalidating selected versions.
    public func reindexFiles(in folder: URL? = nil) async throws {
        while let running = runningRefresh { _ = await running.value }
        let selected = items.indices.filter { p in
            items[p].kind == .file && (folder.map { FileScanner.folder(of: Self.filePath(items[p]), in: [$0]) != nil } ?? true)
        }
        let versions = Set(selected.map { hashes[$0] })
        // Other paths may share this cached version. They must receive its rebuilt chunks too.
        let dropped = Set(items.indices.filter { items[$0].kind == .file && versions.contains(hashes[$0]) }.map { items[$0].id })
        try store.invalidateFiles(hashes: versions)
        indexedFiles.subtract(dropped)
        chunks?.removeAll { dropped.contains($0) }
        for hash in versions { fileRecords.removeValue(forKey: hash) }
        imagesUnavailableUntil = nil
        await refresh()
    }

    /// Reads PDFs with opendataloader-pdf from now on (nil: PDFKit).
    public func setPDFReader(_ reader: OpenDataLoader?) {
        pdfReader = reader
    }

    /// How file content is read (pages, chunk size, text recognition); for files indexed from now on.
    public func setFileContentExtractor(_ extractor: FileContentExtractor) {
        fileContent = extractor
    }

    /// Folders whose images and PDFs are searchable; takes effect at the next `refresh()`.
    public func setFileFolders(_ folders: [URL]) {
        fileFolders = FileScanner.normalized(folders)
    }

    /// Whether query vectors are read from and saved to the store (default on; the in-memory cache
    /// works either way). The CLI turns it off: its eval and bench latencies measure query
    /// embedding, and on the user's database (its default) its queries would fill the slots the
    /// App's queries use.
    public func setStoresQueryVectors(_ on: Bool) {
        storesQueryVectors = on
    }

    /// Lets the App surface model download/load progress in the footer.
    public func reportModelLoading(progress: Double) {
        modelLoadProgress = progress
        if embedder == nil, !isIndexing { publish(.loadingModel(progress: progress)) }
    }

    /// The model could not be loaded: lexical-only from now on.
    public func reportModelLoadFailure(_ reason: String) {
        modelLoadProgress = nil
        semanticFailure = reason
        settleState()
    }

    // MARK: Introspection

    public var currentState: EngineState { state }
    public var itemCount: Int { items.count }
    public func allItems() -> [SearchItem] { items }
    public func item(id: String) -> SearchItem? { position[id].map { items[Int($0)] } }
    public var vectorCount: Int { vectors?.count ?? 0 }
    public var fileChunkCount: Int { chunks?.rowCount ?? 0 }
    public var embeddingInfo: EmbeddingModelInfo? { embedder?.info }

    /// Per-folder file counts, index progress and disk use (see `FileIndexSummary`).
    public func fileIndexSummary() -> FileIndexSummary {
        let files = zip(items, hashes).compactMap { item, hash -> FileIndexSummary.FileState? in
            guard item.kind == .file else { return nil }
            let path = Self.filePath(item)
            return FileIndexSummary.FileState(path: path, isImage: FileScanner.isImage(path: path),
                                              record: indexedFiles.contains(item.id) ? fileRecords[hash] : nil)
        }
        return FileIndexSummary.make(folders: fileFolders, files: files,
                                     dimensions: embedder?.info.dimensions ?? chunks?.dimensions ?? 768,
                                     scanErrors: fileScanErrors)
    }

    /// The path of a `.file` item.
    static func filePath(_ item: SearchItem) -> String {
        if case .openFile(let path) = item.action { return path }
        return String(item.id.dropFirst("file:".count))
    }

    // MARK: Indexing

    /// Warm start: items and cached vectors from the database, no source scan, no model call.
    public func loadFromStore() async {
        do {
            install(items: try store.allItems())
            if let embedder {
                vectors = try cachedVectors(embedder.info).index
                loadIndexedFiles(embedder.info)
            }
            refreshUsage()
        } catch {
            semanticFailure = "Could not read the index: \(error.localizedDescription)"
        }
        settleState()
    }

    public func refresh() async {
        _ = await refreshWithStats()
    }

    /// `refresh()` returning what it did. Concurrent calls share one run; a call during a run makes
    /// it run once more, so a change made after the run's scan is not missed.
    @discardableResult
    public func refreshWithStats() async -> IndexStats {
        if let running = runningRefresh {
            refreshAgain = true
            return await running.value
        }
        // Isolated to the engine, so checking `refreshAgain` and clearing `runningRefresh` happen
        // with no suspension in between: no request falls into a gap.
        let task = Task {
            var stats = await self.performRefresh()
            while self.refreshAgain {
                self.refreshAgain = false
                stats = await self.performRefresh()
            }
            self.runningRefresh = nil
            return stats
        }
        runningRefresh = task
        return await task.value
    }

    private func performRefresh() async -> IndexStats {
        var stats = IndexStats()
        let scanStart = Date()

        let sources = self.sources
        let loaded = await withTaskGroup(of: (Int, Result<[SearchItem], Error>, Double).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    let start = Date()
                    let result: Result<[SearchItem], Error>
                    do { result = .success(try await source.loadItems()) } catch { result = .failure(error) }
                    return (i, result, Date().timeIntervalSince(start))
                }
            }
            var out: [(Int, Result<[SearchItem], Error>, Double)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        var merged: [SearchItem] = []
        var seen = Set<String>()
        for (i, result, elapsed) in loaded {
            let name = sources[i].name
            stats.sourceSeconds[name] = elapsed
            switch result {
            case .success(let list):
                stats.sourceCounts[name] = list.count
                for item in list where seen.insert(item.id).inserted { merged.append(item) }
            case .failure(let error):
                stats.sourceErrors[name] = String(describing: error)
            }
        }
        let failedSources = !stats.sourceErrors.isEmpty

        // Files of the chosen folders, listed off the actor (a big folder takes a while).
        let scanner = FileScanner(folders: fileFolders)
        if !scanner.folders.isEmpty {
            let start = Date()
            let scan = await Task.detached(priority: .utility) { scanner.scan() }.value
            stats.sourceSeconds["files"] = Date().timeIntervalSince(start)
            stats.sourceCounts["files"] = scan.items.count
            if !scan.failedFolders.isEmpty {
                stats.sourceErrors["files"] = scan.failedFolders.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
            }
            fileScanErrors = scan.failedFolders
            for item in scan.items where seen.insert(item.id).inserted { merged.append(item) }
        } else {
            fileScanErrors = [:]
        }

        // Keep the previously stored items of a failed source or an unreadable folder instead of
        // deleting them as vanished. Files of folders no longer listed do go.
        if failedSources || !fileScanErrors.isEmpty, let previous = try? store.allItems() {
            let unreadable = fileScanErrors.keys.map { URL(filePath: $0, directoryHint: .isDirectory) }
            for item in previous where !seen.contains(item.id) {
                let keep = item.kind == .file ? FileScanner.folder(of: Self.filePath(item), in: unreadable) != nil : failedSources
                if keep {
                    seen.insert(item.id)
                    merged.append(item)
                }
            }
        }

        let mergedHashes = Self.contentHashes(merged)
        do {
            stats.sync = try store.syncItems(merged)
        } catch {
            stats.sourceErrors["store"] = String(describing: error)
        }
        install(items: merged, hashes: mergedHashes)
        refreshUsage()
        stats.scanSeconds = Date().timeIntervalSince(scanStart)
        for item in items { stats.itemCounts[item.kind, default: 0] += 1 }

        await embedItems(&stats)
        await indexFiles(&stats)
        settleState()
        return stats
    }

    private func install(items newItems: [SearchItem], hashes newHashes: [String]? = nil) {
        let oldPosition = position, oldHashes = hashes
        items = newItems
        hashes = newHashes ?? Self.contentHashes(newItems)
        position = [:]
        position.reserveCapacity(newItems.count)
        for (i, item) in newItems.enumerated() where position[item.id] == nil { position[item.id] = Int32(i) }
        generation += 1
        filePositions = [:]
        for (p, item) in newItems.enumerated() where item.kind == .file { filePositions[hashes[p], default: []].append(Int32(p)) }
        hasFileItems = !filePositions.isEmpty
        appsByExactName = Self.exactNames(newItems)
        lexical = LexicalIndex(items: newItems)
        // Drop vectors of vanished items and of items whose embedded content changed.
        let stale = { [position, hashes] (id: String) -> Bool in
            guard let p = position[id], let o = oldPosition[id] else { return true }
            return oldHashes[Int(o)] != hashes[Int(p)]
        }
        if var v = vectors {
            vectors = nil  // sole owner: compacted in place, not copied
            v.removeAll(where: stale)
            vectors = v
        }
        if var c = chunks {
            chunks = nil
            c.removeAll(where: stale)
            chunks = c
        }
        indexedFiles = indexedFiles.filter { !stale($0) }
    }

    private static func exactNames(_ items: [SearchItem]) -> [String: [Int32]] {
        var out: [String: [Int32]] = [:]
        for (i, item) in items.enumerated() where item.kind == .application {
            var names = [item.title]
            if let english = item.subtitle { names.append(english) }
            if case .openApplication(let path) = item.action {
                names.append(URL(filePath: path).deletingPathExtension().lastPathComponent)
            }
            for name in Set(names.map(TextNormalizer.normalize)) where !name.isEmpty {
                out[name, default: []].append(Int32(i))
            }
        }
        return out
    }

    private static func contentHashes(_ items: [SearchItem]) -> [String] {
        Parallel.chunked(items.count, minimumChunk: 256) { range in range.map { IndexStore.contentHash(items[$0]) } }
    }

    /// The cached vectors of the current items (item order) and the hashes they cover.
    private func cachedVectors(_ info: EmbeddingModelInfo) throws -> (index: VectorIndex, hashes: Set<String>) {
        let (rows, matrix) = try store.embeddingMatrix(hashes: hashes, modelKey: info.cacheKey, dimensions: info.dimensions)
        let index = VectorIndex(dimensions: info.dimensions, ids: rows.map { items[Int($0)].id }, matrix: matrix)
        return (index, Set(rows.map { hashes[Int($0)] }))
    }

    private func refreshUsage() {
        try? store.pruneHistory(before: now().addingTimeInterval(-Double(historyRetentionDays) * 86_400))
        historyLastPruned = now()
        guard historyEnabled else { usage = [:]; memory = QueryMemoryIndex(); return }
        usage = (try? store.usageRecords()) ?? [:]
        memory = QueryMemoryIndex((try? store.queryMemoryRecords()) ?? [])
    }

    /// Fills the vector index from the cache and embeds what is missing, in batches.
    private func embedItems(_ stats: inout IndexStats) async {
        guard let embedder else { return }
        let info = embedder.info
        let key = info.cacheKey
        stats.modelKey = key
        let start = Date()
        let snapshot = items, snapshotHashes = hashes

        let cached = (try? cachedVectors(info)) ?? (index: VectorIndex(dimensions: info.dimensions), hashes: [])
        vectors = cached.index

        // File items are embedded from their content (`indexFiles`), not from their text card.
        var missing: [(hash: String, item: SearchItem)] = []
        var queued = Set<String>()
        var cardItems = 0
        for (item, hash) in zip(snapshot, snapshotHashes) where item.kind != .file {
            cardItems += 1
            if !cached.hashes.contains(hash) && queued.insert(hash).inserted { missing.append((hash, item)) }
        }
        stats.embeddingCacheHits = cardItems - missing.count

        if !missing.isEmpty {
            isIndexing = true
            publish(.indexing(done: 0, total: missing.count))
            var done = 0
            let batchSize = max(1, embeddingBatchSize)
            var batchStart = 0
            var positionsOfHash: [String: [Int32]] = [:]
            var mappedGeneration = -1
            while batchStart < missing.count {
                let batch = missing[batchStart..<min(batchStart + batchSize, missing.count)]
                batchStart += batch.count
                do {
                    let inputs = batch.map { EmbeddingInput.document(title: $0.item.embeddingTitle, text: $0.item.embeddingText) }
                    let out = try await embedder.embed(inputs)
                    guard out.count == batch.count, out.allSatisfy({ $0.count == info.dimensions }) else {
                        throw EngineError.badEmbedderOutput(expected: batch.count, dimensions: info.dimensions)
                    }
                    var fresh: [String: [Float]] = [:]
                    // At stored precision, so this session ranks exactly like the next one, which
                    // reads them back from the cache.
                    for (entry, v) in zip(batch, out) { fresh[entry.hash] = IndexStore.storedPrecision(v) }
                    try? store.saveEmbeddings(fresh, modelKey: key)
                    // Items can change while we were suspended; only index vectors whose content still
                    // matches, in item order.
                    if var index = vectors, index.dimensions == info.dimensions, self.embedder?.info.cacheKey == key {
                        vectors = nil  // sole owner: upserts grow the matrix in place, not a copy of it
                        if mappedGeneration != generation {
                            positionsOfHash = [:]
                            for (p, h) in hashes.enumerated() { positionsOfHash[h, default: []].append(Int32(p)) }
                            mappedGeneration = generation
                        }
                        let rows = fresh.keys.flatMap { positionsOfHash[$0] ?? [] }.sorted()
                        for p in rows { index.upsert(id: items[Int(p)].id, vector: fresh[hashes[Int(p)]]!) }
                        vectors = index
                    }
                    done += batch.count
                    stats.embeddedNew += batch.count
                    publish(.indexing(done: done, total: missing.count))
                } catch {
                    stats.embeddingError = String(describing: error)
                    semanticFailure = "Embedding failed: \(error.localizedDescription)"
                    break
                }
            }
            isIndexing = false
        }
        if stats.embeddingError == nil {
            semanticFailure = nil
            _ = try? store.pruneEmbeddings(keeping: Set(snapshotHashes), modelKey: key)
            _ = try? store.pruneOtherModels(keeping: key)
        }
        stats.vectorCount = vectors?.count ?? 0
        stats.embedSeconds = Date().timeIntervalSince(start)
    }

    // MARK: Files

    /// Generic queries whose mean cosine to a chunk measures how close it comes to any query (its
    /// hubness, see `ChunkIndex`): short, everyday, Korean and English, across topics.
    static let hubProbes = [
        "사진", "문서", "설정", "음악", "날씨", "메일", "일정", "지도", "계산기", "메모",
        "화면", "인터넷", "회의", "여행", "음식", "운동", "뉴스", "쇼핑", "영화", "공부",
        "photo", "document", "settings", "music", "weather", "email", "calendar", "map", "notes", "screen",
        "internet", "meeting", "travel", "food", "news", "shopping",
    ]

    /// Puts the stored chunks of the current file items into `chunks` (warm start, no model call).
    private func loadIndexedFiles(_ info: EmbeddingModelInfo) {
        chunks = ChunkIndex(dimensions: info.dimensions)
        indexedFiles = []
        fileRecords = [:]
        loadStoredFiles(info, only: nil)
    }

    /// Loads stored chunks of current file items not in `chunks` yet (all of them when `only` is
    /// nil, else the items in `only`). Returns the items whose version the store does not have
    /// (or has without images while there is an image embedder now).
    @discardableResult
    private func loadStoredFiles(_ info: EmbeddingModelInfo, only: Set<String>?) -> [Int] {
        let key = info.cacheKey
        let stored = (try? store.fileIndexRecords(modelKey: key)) ?? [:]
        var idsOfHash: [String: [String]] = [:]
        var unknown: [Int] = []
        for (p, item) in items.enumerated() where item.kind == .file && !indexedFiles.contains(item.id) {
            guard only?.contains(item.id) ?? true else { continue }
            let hash = hashes[p]
            if let record = stored[hash], !needsFileRetry(record) {
                idsOfHash[hash, default: []].append(item.id)
                fileRecords[hash] = record
            } else {
                if let record = stored[hash] { fileRecords[hash] = record }
                unknown.append(p)
            }
        }
        guard !idsOfHash.isEmpty else { return unknown }
        var index = chunks ?? ChunkIndex(dimensions: info.dimensions)
        chunks = nil  // sole owner: grows in place
        index.reserveCapacity(forAdditionalRows: idsOfHash.reduce(0) { $0 + (stored[$1.key]?.chunks ?? 0) * $1.value.count })
        try? store.forEachFileChunk(hashes: Set(idsOfHash.keys), modelKey: key, dimensions: info.dimensions) { hash, kind, hub, page, bytes in
            for id in idsOfHash[hash] ?? [] { index.append(itemID: id, kind: kind, hub: hub, page: page, float16: bytes) }
        }
        chunks = index
        for ids in idsOfHash.values { indexedFiles.formUnion(ids) }
        return unknown
    }

    /// Brings `chunks` in step with the current file items: stored versions are loaded, new or
    /// changed files are read and embedded in batches, and versions no file has any more are
    /// deleted from the store.
    private func indexFiles(_ stats: inout IndexStats) async {
        guard let embedder else { return }
        let info = embedder.info
        let start = Date()
        if chunks?.dimensions != info.dimensions {
            chunks = ChunkIndex(dimensions: info.dimensions)
            indexedFiles = []
        }
        if let until = imagesUnavailableUntil, ContinuousClock.now >= until { imagesUnavailableUntil = nil }
        // Files indexed without their images get them now that images can be embedded.
        redoPartialFiles()
        let unknown = loadStoredFiles(info, only: nil)
        var order: [String] = []
        var file: [String: (path: String, title: String?)] = [:]
        for p in unknown where file[hashes[p]] == nil {
            file[hashes[p]] = (Self.filePath(items[p]), items[p].embeddingTitle)
            order.append(hashes[p])
        }
        // Versions indexed before keyword search kept no text: read once more for it alone, before
        // the model is needed (like `embedFiles`, so opendataloader-pdf's JVM does not run next to it).
        let textless = (try? store.fileHashesWithoutText(modelKey: info.cacheKey)) ?? []
        var reread: [String] = []
        var paths: [String: String] = [:]
        for (p, item) in items.enumerated() where item.kind == .file && textless.contains(hashes[p])
            && file[hashes[p]] == nil && paths[hashes[p]] == nil {
            paths[hashes[p]] = Self.filePath(item)
            reread.append(hashes[p])
        }
        if !reread.isEmpty { await readMissingTexts(reread, paths, &stats) }
        if !order.isEmpty { await embedFiles(order, file, embedder: embedder, &stats) }

        let current = Set(zip(items, hashes).filter { $0.0.kind == .file }.map(\.1))
        fileRecords = fileRecords.filter { current.contains($0.key) }
        _ = try? store.pruneFileIndex(keeping: current, modelKey: info.cacheKey)
        // Appends and removals leave the vector array up to ~2.5× its rows.
        if var index = chunks {
            chunks = nil  // sole owner: no second copy
            index.shrinkToFit()
            chunks = index
        }
        stats.fileChunks = chunks?.rowCount ?? 0
        stats.fileSeconds = Date().timeIntervalSince(start)
        scheduleFileRetry()
    }

    private func scheduleFileRetry() {
        fileRetryTask?.cancel()
        let dates = fileRecords.values.filter { $0.retryable && $0.retryCount < 3 }.compactMap(\.retryAfter)
        guard let next = dates.min() else { return }
        let wait = max(1, next.timeIntervalSince(now()))
        fileRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.refresh()
        }
    }

    /// Reads file versions `order` (content hash → path) again for their text alone and stores it
    /// (`IndexStore.saveFileTexts`): they were indexed before keyword search kept text. No model
    /// call. PDFs go through opendataloader-pdf (when there is a reader) a run at a time, then all
    /// files are read `fileBatchSize` at a time, as in `embedFiles`. A file that cannot be read right
    /// now is left for a later refresh.
    private func readMissingTexts(_ order: [String], _ paths: [String: String], _ stats: inout IndexStats) async {
        isIndexing = true
        defer { isIndexing = false }
        let extractor = fileContent
        let batchSize = max(1, fileBatchSize), run = max(1, pdfReader?.filesPerRun ?? batchSize)
        var done = 0
        publish(.indexing(done: 0, total: order.count))
        for runStart in stride(from: 0, to: order.count, by: run) {
            // A folder removed meanwhile is not read any further.
            let folders = fileFolders
            let slice = order[runStart..<min(runStart + run, order.count)]
            let group = slice.filter { FileScanner.folder(of: paths[$0]!, in: folders) != nil }
            done += slice.count - group.count
            var structures: [String: PDFStructure] = [:]
            let pdfs = group.map { paths[$0]! }.filter {
                !FileScanner.isImage(path: $0) && !FileContentExtractor.isUnavailable(URL(filePath: $0))
            }
            if let reader = pdfReader, !pdfs.isEmpty {
                structures = await Self.readPDFs(pdfs, with: reader)
                stats.pdfsStructured += structures.count
            }
            for batchStart in stride(from: 0, to: group.count, by: batchSize) {
                let batch = group[batchStart..<min(batchStart + batchSize, group.count)]
                let files = batch.map { paths[$0]! }
                let contents = await Self.extract(files, structures: files.map { structures.removeValue(forKey: $0) },
                                                  with: extractor)
                let read = zip(batch, contents).filter { !$0.1.unavailable }.map { (hash: $0.0, texts: $0.1.texts) }
                stats.fileTextsRead += (try? store.saveFileTexts(read)) ?? 0
                done += batch.count
                publish(.indexing(done: done, total: order.count))
            }
        }
    }

    /// Reads and embeds file versions `order` (content hash → path and title), `fileBatchSize` at a
    /// time: content is read on GCD's threads, then text chunks and images are embedded. Each batch
    /// is saved and indexed before the next starts.
    ///
    /// The vision model embeds the text chunks too, so indexing holds one model; while it fails,
    /// text goes to `embedder`. A file whose text cannot be embedded is recorded without it rather
    /// than holding up the rest; files that cannot be read right now (gone, offline, in iCloud only)
    /// are left for a later refresh.
    private func embedFiles(_ order: [String], _ file: [String: (path: String, title: String?)],
                            embedder: any TextEmbedder, _ stats: inout IndexStats) async {
        let info = embedder.info, key = info.cacheKey
        isIndexing = true
        defer { isIndexing = false }
        // PDFs are read with opendataloader-pdf first, all of them, so its JVM never runs next to the
        // embedding model. Progress counts those reads, then the files embedded.
        // Not files that cannot be read right now: reading would download an iCloud-only file, and
        // they would start the JVM again at every refresh.
        let pdfs = pdfReader == nil ? [] : order.compactMap { file[$0]?.path }.filter {
            !FileScanner.isImage(path: $0) && !FileContentExtractor.isUnavailable(URL(filePath: $0))
        }
        let total = pdfs.count + order.count
        var done = 0
        publish(.indexing(done: 0, total: total))
        var structures: [String: PDFStructure] = [:]
        if let reader = pdfReader {
            for start in stride(from: 0, to: pdfs.count, by: max(1, reader.filesPerRun)) {
                let group = Array(pdfs[start..<min(start + reader.filesPerRun, pdfs.count)])
                structures.merge(await Self.readPDFs(group, with: reader)) { first, _ in first }
                done += group.count
                publish(.indexing(done: done, total: total))
            }
            stats.pdfsStructured += structures.count
        }
        var vision = VisionUse(embedder: imagesUsable ? imageEmbedder.flatMap { $0.info == info ? $0 : nil } : nil)
        let probes: [[Float]]
        do {
            probes = try await hubProbeVectors(&vision, text: embedder, &stats)
        } catch {
            stats.embeddingError = String(describing: error)
            semanticFailure = "Embedding failed: \(error.localizedDescription)"
            return
        }
        let extractor = fileContent
        var positionsOfHash: [String: [Int32]] = [:]
        var mappedGeneration = -1
        let batchSize = max(1, fileBatchSize)
        for batchStart in stride(from: 0, to: order.count, by: batchSize) {
            // A folder removed meanwhile is not indexed any further (the next refresh drops its files).
            let folders = fileFolders
            let slice = order[batchStart..<min(batchStart + batchSize, order.count)]
            let batch = slice.filter { FileScanner.folder(of: file[$0]!.path, in: folders) != nil }
            done += slice.count - batch.count
            guard !batch.isEmpty else { continue }
            publish(.indexing(done: done, total: total))
            let paths = batch.map { file[$0]!.path }
            let contents = await Self.extract(paths, structures: paths.map { structures.removeValue(forKey: $0) }, with: extractor)

            // Text: the batch in one call; if that fails, file by file, so one file that cannot be
            // embedded does not hold up the others.
            let texts = contents.enumerated().map { i, content in
                content.texts.map { (kind: $0.kind, page: $0.page,
                                     input: EmbeddingInput.document(title: file[batch[i]]!.title, text: $0.text)) }
            }
            var textVectors: [[[Float]]?]
            if let all = try? await embedTexts(texts.flatMap { $0.map(\.input) }, &vision, text: embedder, &stats) {
                var offset = 0
                textVectors = texts.map { t in
                    defer { offset += t.count }
                    return Array(all[offset..<offset + t.count])
                }
            } else {
                textVectors = []
                var anyEmbedded = false
                var lastError: Error?
                for t in texts {
                    guard !t.isEmpty else {
                        textVectors.append([])
                        continue
                    }
                    do {
                        textVectors.append(try await embedTexts(t.map(\.input), &vision, text: embedder, &stats))
                        anyEmbedded = true
                    } catch {
                        textVectors.append(nil)
                        lastError = error
                    }
                }
                if !anyEmbedded, let lastError {
                    stats.embeddingError = String(describing: lastError)
                    semanticFailure = "Embedding failed: \(lastError.localizedDescription)"
                }
            }
            var fileChunks = [[FileChunk]](repeating: [], count: batch.count)
            for (i, t) in texts.enumerated() {
                for (entry, v) in zip(t, textVectors[i] ?? []) {
                    let v = IndexStore.storedPrecision(v)
                    fileChunks[i].append(FileChunk(kind: entry.kind, hub: Self.hub(v, probes), vector: v, page: entry.page))
                }
            }

            // Images one at a time (one image's activations in memory).
            var imagesSkipped = [Bool](repeating: false, count: batch.count)
            var imageFailed = [Bool](repeating: false, count: batch.count)
            for (i, content) in contents.enumerated() {
                for image in content.images {
                    guard let model = vision.embedder else {
                        imagesSkipped[i] = true
                        continue
                    }
                    do {
                        guard let v = try await model.embed(images: [image.image]).first, v.count == info.dimensions else {
                            throw EngineError.badEmbedderOutput(expected: 1, dimensions: info.dimensions)
                        }
                        vision.imageSucceeded()
                        let stored = IndexStore.storedPrecision(v)
                        fileChunks[i].append(FileChunk(kind: image.kind, hub: Self.hub(stored, probes), vector: stored,
                                                       page: image.page))
                    } catch {
                        stats.imageEmbeddingError = String(describing: error)
                        imageFailed[i] = true
                        if vision.imageFailed() { imagesUnavailableUntil = .now + imageRetryInterval }
                    }
                }
            }

            // Inference failures are retryable even when another file succeeded. Parsing errors
            // remain stable until the file changes or the user explicitly rebuilds the folder.
            var saved: [(hash: String, record: FileIndexRecord, chunks: [FileChunk])] = []
            // Text is kept for keyword search even where it could not be embedded.
            var savedTexts: [String: [FileContent.Text]] = [:]
            for (i, hash) in batch.enumerated() where !contents[i].unavailable {
                savedTexts[hash] = contents[i].texts
                let retryable = imageFailed[i] || textVectors[i] == nil
                let partial = imagesSkipped[i] || retryable
                var error = contents[i].error
                if error == nil, fileChunks[i].isEmpty {
                    error = textVectors[i] == nil ? "text could not be embedded" : imageFailed[i] ? "image could not be embedded" : nil
                }
                if retryable, error == nil { error = imageFailed[i] ? "image could not be embedded" : "text could not be embedded" }
                let attempts = retryable ? (fileRecords[hash]?.retryCount ?? 0) + 1 : 0
                let interval = imageRetryInterval.components
                let seconds = max(0, Double(interval.seconds) + Double(interval.attoseconds) / 1e18)
                let retryAfter = retryable ? now().addingTimeInterval(seconds * pow(2, Double(min(attempts - 1, 8)))) : nil
                saved.append((hash, FileIndexRecord(chunks: fileChunks[i].count, partial: partial, error: error,
                                                  retryable: retryable, retryCount: attempts, retryAfter: retryAfter),
                              fileChunks[i]))
            }
            do { try store.saveFileChunks(saved, texts: savedTexts, modelKey: key) }
            catch {
                stats.sourceErrors["store"] = String(describing: error)
                semanticFailure = "Could not save file index: \(error.localizedDescription)"
                break
            }
            // Files (or the model) can change while we were suspended: index only the items that
            // still have these versions, under this model.
            if var index = chunks, index.dimensions == info.dimensions, self.embedder?.info.cacheKey == key {
                chunks = nil  // sole owner: grows in place
                if mappedGeneration != generation {
                    positionsOfHash = [:]
                    for (p, h) in hashes.enumerated() where items[p].kind == .file { positionsOfHash[h, default: []].append(Int32(p)) }
                    mappedGeneration = generation
                }
                for entry in saved {
                    fileRecords[entry.hash] = entry.record
                    for p in positionsOfHash[entry.hash] ?? [] {
                        let id = items[Int(p)].id
                        guard indexedFiles.insert(id).inserted else { continue }
                        for c in entry.chunks { index.append(itemID: id, kind: c.kind, hub: c.hub, page: c.page, vector: c.vector) }
                    }
                }
                chunks = index
            }
            stats.filesIndexed += saved.count
            stats.fileErrors += saved.filter { $0.record.error != nil }.count
            done += batch.count
            publish(.indexing(done: done, total: total))
        }
    }

    /// The vision model during one indexing run. Images: it is given up on (until
    /// `imageRetryInterval` passes) after `failuresBeforeWorking` image failures in a row before any
    /// image embedded, or `failuresAfterWorking` after one did. Text: it stops being used for text
    /// after `failuresBeforeWorking` text failures in a row. Text successes say nothing about images.
    private struct VisionUse {
        static let failuresBeforeWorking = 3
        static let failuresAfterWorking = 8
        var embedder: (any ImageEmbedder)?
        var forText = true
        var imagesWorked = false
        var gaveUp = false
        private var imageFailures = 0
        private var textFailures = 0

        init(embedder: (any ImageEmbedder)?) { self.embedder = embedder }

        mutating func imageSucceeded() {
            imagesWorked = true
            imageFailures = 0
        }

        /// Counts an image failure; true when it gives up on the model now.
        mutating func imageFailed() -> Bool {
            imageFailures += 1
            let limit = imagesWorked ? Self.failuresAfterWorking : Self.failuresBeforeWorking
            guard embedder != nil, imageFailures >= limit else { return false }
            embedder = nil
            gaveUp = true
            return true
        }

        mutating func textSucceeded() { textFailures = 0 }

        mutating func textFailed() {
            textFailures += 1
            if textFailures >= Self.failuresBeforeWorking { forText = false }
        }
    }

    /// `inputs` embedded by the vision model while it works (one model in memory during indexing),
    /// else by the text model.
    private func embedTexts(_ inputs: [EmbeddingInput], _ vision: inout VisionUse, text: any TextEmbedder,
                            _ stats: inout IndexStats) async throws -> [[Float]] {
        if inputs.isEmpty { return [] }
        let dimensions = text.info.dimensions
        if vision.forText, let model = vision.embedder {
            do {
                let vectors = try Self.checked(await model.embed(inputs), count: inputs.count, dimensions: dimensions)
                vision.textSucceeded()
                return vectors
            } catch {
                stats.imageEmbeddingError = String(describing: error)
                vision.textFailed()
            }
        }
        return try Self.checked(await text.embed(inputs), count: inputs.count, dimensions: dimensions)
    }

    /// Reads `paths` on GCD's threads: PDF parsing and text recognition block, and on the
    /// cooperative pool they would hold up searches.
    private static func extract(_ paths: [String], structures: [PDFStructure?],
                                with extractor: FileContentExtractor) async -> [FileContent] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var out = [FileContent](repeating: FileContent(), count: paths.count)
                out.withUnsafeMutableBufferPointer { buffer in
                    nonisolated(unsafe) let slots = buffer
                    DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                        slots[i] = extractor.extract(path: paths[i], structure: structures[i])
                    }
                }
                continuation.resume(returning: out)
            }
        }
    }

    /// One opendataloader-pdf run (a JVM process) over `paths`, on a GCD thread.
    private static func readPDFs(_ paths: [String], with reader: OpenDataLoader) async -> [String: PDFStructure] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: reader.read(paths))
            }
        }
    }

    private static func checked(_ vectors: [[Float]], count: Int, dimensions: Int) throws -> [[Float]] {
        guard vectors.count == count, vectors.allSatisfy({ $0.count == dimensions }) else {
            throw EngineError.badEmbedderOutput(expected: count, dimensions: dimensions)
        }
        return vectors
    }

    private func hubProbeVectors(_ vision: inout VisionUse, text: any TextEmbedder,
                                 _ stats: inout IndexStats) async throws -> [[Float]] {
        let key = text.info.cacheKey
        if let probes = probeVectors, probes.key == key { return probes.vectors }
        let stored = try await embedTexts(Self.hubProbes.map { .query($0) }, &vision, text: text, &stats)
            .map(IndexStore.storedPrecision)
        probeVectors = (key, stored)
        return stored
    }

    /// Mean cosine of `v` to the probe vectors.
    static func hub(_ v: [Float], _ probes: [[Float]]) -> Float {
        guard !probes.isEmpty else { return 0 }
        var total: Float = 0
        for p in probes { total += VectorMath.dot(v, p) }
        return total / Float(probes.count)
    }

    // MARK: Search

    public func instantSearch(_ query: String, limit: Int) async -> [SearchResult] {
        expireHistoryIfNeeded()
        let analysis = QueryAnalyzer.analyze(query)
        guard !analysis.normalized.isEmpty else { return [] }
        let lex = lexical.search(analysis, limit: max(0, config.lexicalCandidates))
        return rank(analysis, lexical: lex, mode: .lexical, semantic: nil, limit: limit)
    }

    public func fullSearch(_ query: String, limit: Int) async throws -> [SearchResult] {
        try await search(query, mode: .hybrid, limit: limit)
    }

    /// Search with an explicit mode (CLI / evaluation). `.semantic` ranks by cosine only.
    public func search(_ query: String, mode: SearchMode, limit: Int) async throws -> [SearchResult] {
        expireHistoryIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let analysis = QueryAnalyzer.analyze(trimmed)
        guard !analysis.normalized.isEmpty else { return [] }
        let lex = mode == .semantic ? [] : lexical.search(analysis, limit: max(0, config.lexicalCandidates))
        var semantic: [HybridRanker.SemanticHit]?
        var files: [HybridRanker.SemanticHit] = []
        if mode != .lexical {
            let hits = try await semanticHits(for: trimmed, lexicalIDs: lex.map(\.itemID))
            semantic = hits?.items
            files = hits?.files ?? []
            if mode == .semantic, semantic == nil { return [] }
        }
        try Task.checkCancellation()
        let keywords = mode == .hybrid ? try await keywordHits(analysis, lexical: lex, contentMatches: files) : []
        try Task.checkCancellation()
        return rank(analysis, lexical: lex, mode: mode, semantic: semantic, files: files, keywords: keywords, limit: limit)
    }

    private func rank(_ analysis: QueryAnalysis, lexical lex: [LexicalHit], mode: SearchMode,
                      semantic: [HybridRanker.SemanticHit]?, files: [HybridRanker.SemanticHit] = [],
                      keywords: [HybridRanker.KeywordHit] = [], limit: Int) -> [SearchResult] {
        var frecency: [String: Double] = [:]
        var memoryBoosts: [String: Double] = [:]
        if config.useUsageSignals, mode != .semantic {
            let now = now()
            memoryBoosts = memory.boosts(query: analysis.normalized, now: now, config: config)
            if !usage.isEmpty {
                for id in Set(lex.map(\.itemID)).union(memoryBoosts.keys)
                    .union((semantic ?? []).prefix(max(0, config.semanticCandidates)).map(\.itemID)).union(files.map(\.itemID))
                    .union(keywords.map(\.itemID)) {
                    if let r = usage[id] { frecency[id] = Frecency.boost(r, now: now, config: config) }
                }
            }
        }
        // With files, rank twice as many: settings moved to the end make room for what follows them.
        let arranges = hasFileItems && mode != .semantic
        let ranked = HybridRanker.rank(analysis: analysis, lexical: lex, semantic: semantic, fileSemantic: files,
                                       fileKeyword: keywords, kind: { position[$0].map { items[Int($0)].kind } },
                                       frecency: frecency, memory: memoryBoosts, mode: mode, config: config,
                                       limit: arranges ? min(limit, Int.max / 2) * 2 : limit)
        var results = ranked.compactMap { r in
            position[r.itemID].map { SearchResult(item: items[Int($0)], score: r.score, signals: r.signals, breakdown: r.breakdown) }
        }
        if arranges { results = Array(ResultSections.arrange(results, analysis: analysis, config: config).prefix(limit)) }
        // A query that is exactly an app's name opens that app: it goes first.
        if mode != .semantic, let apps = appsByExactName[analysis.normalized] {
            let ids = Set(apps.map { items[Int($0)].id })
            let named = results.filter { ids.contains($0.id) }
            if !named.isEmpty, results.first.map({ !ids.contains($0.id) }) ?? false {
                results = named + results.filter { !ids.contains($0.id) }
            }
        }
        return results
    }

    /// Cosine-ranked item hits for the top candidates plus every lexical candidate (cosine only), and
    /// file hits past `minFileScore` (see `ChunkIndex`); nil when semantic search is unavailable (no
    /// embedder or vectors, or the query embedding failed).
    private func semanticHits(for query: String, lexicalIDs: [String])
        async throws -> (items: [HybridRanker.SemanticHit], files: [HybridRanker.SemanticHit])? {
        let itemRows = vectors?.count ?? 0, fileRows = chunks?.rowCount ?? 0
        guard let embedder, itemRows > 0 || fileRows > 0 else { return nil }
        let dimensions = itemRows > 0 ? vectors!.dimensions : chunks!.dimensions
        let qv: [Float]
        let key = embedder.info.cacheKey
        let historyEpoch = historyGeneration
        if let cached = queryVectorCache[query] {
            qv = cached
        } else if storesQueryVectors, historyEnabled, let stored = try? store.queryVector(query, modelKey: key, now: now()), stored.count == dimensions {
            // Searched before (maybe in an earlier run): no model load.
            qv = stored
            rememberQueryVector(query, stored)
        } else {
            do {
                guard let fresh = try await embedder.embed([.query(query)]).first, fresh.count == dimensions else {
                    throw EngineError.badEmbedderOutput(expected: 1, dimensions: dimensions)
                }
                // At stored precision, so a query ranks exactly the same whether its vector came
                // from the model or, in a later search, from the store.
                let v = IndexStore.storedPrecision(fresh)
                try Task.checkCancellation()
                // The embedder was replaced while we were suspended: the vector is of the old space.
                guard self.embedder?.info.cacheKey == key else { return nil }
                qv = v
                if historyEpoch == historyGeneration {
                    if storesQueryVectors, historyEnabled { try? store.saveQueryVector(v, query: query, modelKey: key, now: now()) }
                    rememberQueryVector(query, v)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                semanticFailure = "Query embedding failed: \(error.localizedDescription)"
                settleState()
                return nil
            }
        }
        try Task.checkCancellation()
        var hits: [HybridRanker.SemanticHit] = []
        if let index = vectors, index.dimensions == qv.count, index.count > 0 {
            let k = max(config.semanticCandidates, 1)
            hits = index.withScores(for: qv) { scores in
                let top = VectorIndex.topK(scores, k: k)
                var hits = top.map { HybridRanker.SemanticHit(itemID: index.id(atRow: $0), cosine: Double(scores[$0])) }
                // Cosines for lexical candidates outside the top-k (explain output; no rank contribution),
                // in row order.
                let extra = Set(lexicalIDs.compactMap(index.row(of:))).subtracting(top).sorted()
                hits += extra.map { HybridRanker.SemanticHit(itemID: index.id(atRow: $0), cosine: Double(scores[$0])) }
                return hits
            }
        }
        var fileHits: [HybridRanker.SemanticHit] = []
        if let index = chunks, index.dimensions == qv.count, index.rowCount > 0 {
            fileHits = index.search(qv, k: max(config.fileCandidates, 1), hubWeight: Float(config.hubWeight))
                .filter { Double($0.score) >= config.minFileScore }
                .map { HybridRanker.SemanticHit(itemID: $0.itemID, cosine: Double($0.cosine), score: Double($0.score),
                                                page: $0.kind == .card ? nil : $0.page) }
        }
        if semanticFailure != nil, !isIndexing {
            semanticFailure = nil
            settleState()
        }
        return (hits, fileHits)
    }

    /// Files whose stored text has the query's words (`IndexStore.keywordMatches`, bm25 order) and
    /// covers at least `minFileKeywordCoverage` of them; every file item of a matching version.
    /// Reads only the store (off the actor), so it works without the model.
    ///
    /// A file the content search did not also find (`contentMatches`) needs words few files have
    /// (rarity of at least `minFileKeywordRarity`): its words are then all there is, and a common
    /// word ("meeting", "회의") would list whichever documents happen to say it.
    ///
    /// None when an app, setting or command is named by the query (lexical score of at least
    /// `fileKeywordMaxItemNameScore`): "작업 관리자", "pdf 보기" and "블루투스" are words some
    /// documents have too, and listing those documents put them above Activity Monitor and
    /// Preview, or opened the settings section above the Bluetooth settings (`ResultSections`).
    private func keywordHits(_ analysis: QueryAnalysis, lexical lex: [LexicalHit],
                             contentMatches: [HybridRanker.SemanticHit]) async throws -> [HybridRanker.KeywordHit] {
        guard hasFileItems, config.fileKeywordCandidates > 0 else { return [] }
        let namesItem = lex.contains { hit in
            hit.score >= config.fileKeywordMaxItemNameScore && position[hit.itemID].map { items[Int($0)].kind != .file } == true
        }
        let words = ContentTokenizer.queryWords(analysis)
        guard !namesItem, !words.isEmpty else { return [] }
        let store = self.store, chunks = config.fileKeywordChunks
        let matches = await Task.detached(priority: .userInitiated) {
            (try? store.keywordMatches(words: words, chunks: chunks)) ?? []
        }.value
        try Task.checkCancellation()
        let found = Set(contentMatches.map(\.itemID))
        var hits: [HybridRanker.KeywordHit] = []
        for match in matches where match.coverage >= config.minFileKeywordCoverage {
            for p in filePositions[match.fileHash] ?? [] {
                let id = items[Int(p)].id
                guard match.rarity >= config.minFileKeywordRarity || found.contains(id) else { continue }
                hits.append(HybridRanker.KeywordHit(itemID: id, coverage: match.coverage, page: match.page))
            }
            if hits.count >= config.fileKeywordCandidates { break }
        }
        return Array(hits.prefix(config.fileKeywordCandidates))
    }

    private func rememberQueryVector(_ query: String, _ v: [Float]) {
        if queryVectorCache[query] == nil { queryVectorOrder.append(query) }
        queryVectorCache[query] = v
        while queryVectorOrder.count > queryVectorCacheSize {
            queryVectorCache.removeValue(forKey: queryVectorOrder.removeFirst())
        }
    }

    // MARK: Usage

    public func recordSelection(itemID: String, query: String) async {
        expireHistoryIfNeeded()
        guard historyEnabled else { return }
        do {
            // Apply the two rows the store wrote instead of re-reading both tables.
            let written = try store.recordSelection(itemID: itemID, query: query, at: now(), halfLife: config.frecencyHalfLife)
            usage[itemID] = written.usage
            if let m = written.memory { memory.upsert(m) }
        } catch {
            refreshUsage()
        }
    }

    // MARK: State

    public func stateUpdates() async -> AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream<EngineState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish(_ newState: EngineState) {
        guard newState != state else { return }
        state = newState
        for c in continuations.values { c.yield(newState) }
    }

    private func settleState() {
        guard !isIndexing else { return }
        if embedder == nil {
            if let p = modelLoadProgress {
                publish(.loadingModel(progress: p))
            } else {
                publish(.degraded(reason: semanticFailure ?? "Semantic search unavailable: no embedding model loaded"))
            }
        } else if let failure = semanticFailure {
            publish(.degraded(reason: failure))
        } else {
            publish(.ready(itemCount: items.count))
        }
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case badEmbedderOutput(expected: Int, dimensions: Int)

    public var description: String {
        switch self {
        case .badEmbedderOutput(let n, let d): "embedder returned an unexpected shape (wanted \(n) × \(d))"
        }
    }
}
