import EmbedCore
import Foundation
import GRDB
import Testing
@testable import SearchCore

@Suite("Keyword search over file text")
struct KeywordSearchTests {
    private let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64), d = String(repeating: "d", count: 64)

    private func text(_ text: String, page: Int? = nil) -> FileContent.Text {
        FileContent.Text(kind: .text, text: text, page: page)
    }

    private func chunks(_ n: Int) -> [FileChunk] {
        Array(repeating: FileChunk(kind: .text, hub: 0, vector: [1, 0, 0, 0]), count: n)
    }

    /// One FTS row per chunk map row, and FTS5's own check passes.
    private func checkTextIndex(_ url: URL) throws {
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO fileTextIndex (fileTextIndex) VALUES ('integrity-check')")
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fileText")
            let indexed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fileTextIndex_docsize")
            #expect(rows == indexed)
        }
    }

    private func words(_ query: String) -> [[String]] { ContentTokenizer.queryWords(QueryAnalyzer.analyze(query)) }

    @Test func tokenizerMakesHangulBigramsAndKeepsOtherWordsWhole() {
        #expect(ContentTokenizer.tokens("다이캐스팅 공정") == ["다이", "이캐", "캐스", "스팅", "공정"])
        #expect(ContentTokenizer.tokens("NAVSIM을 사용한 3D 평가, v2 및 a/b")
            == ["navsim", "을", "사용", "용한", "3d", "평가", "v2", "및"])
        #expect(ContentTokenizer.tokens("TAP-Vid (Doersch et al., 2022)") == ["tap", "vid", "doersch", "et", "al", "2022"])
        #expect(ContentTokenizer.tokens("x = y + 1") == ["1"])
        #expect(ContentTokenizer.tokens("").isEmpty)
        // Queries: a word per content word (kind words and particles gone), duplicates once.
        #expect(words("다이캐스팅 공정에서 설정") == [["다이", "이캐", "캐스", "스팅"], ["공정"]])
        #expect(words("tap TAP-vid x") == [["tap"], ["vid"]])
    }

    @Test func storeFindsReplacesAndPrunesText() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        try store.saveFileChunks([(a, FileIndexRecord(chunks: 3), chunks(3)), (b, FileIndexRecord(chunks: 1), chunks(1)),
                                  (c, FileIndexRecord(chunks: 1), chunks(1))],
                                 texts: [a: [text("NAVSIM: a benchmark for driving policies, report", page: 1),
                                             text("results of the driving benchmark", page: 4)],
                                         b: [text("다이캐스팅 공정의 품질 관리 report", page: 2)],
                                         c: [text("포캐스트 테스팅 결과", page: 1)]],
                                 modelKey: "m")
        try checkTextIndex(url)
        #expect(try store.fileHashesWithoutText(modelKey: "m").isEmpty)
        #expect(try store.fileTextBytes() > 0)

        let navsim = try store.keywordMatches(words: [["navsim"]], chunks: 10)
        #expect(navsim.map(\.fileHash) == [a] && navsim[0].coverage == 1 && navsim[0].page == 1 && navsim[0].score > 0)
        // Rarity counts files: "navsim" is in one of three, "report" in two.
        #expect(navsim[0].rarity == 1)
        let report = try store.keywordMatches(words: [["report"]], chunks: 10)
        #expect(report.count == 2 && report.allSatisfy { $0.rarity < 0.6 })
        // Korean words match as phrases of their bigrams: "캐스팅" is in "다이캐스팅", not in
        // "포캐스트 테스팅", which has both bigrams apart. A particle in the query does not count.
        let casting = try store.keywordMatches(words: words("캐스팅 공정을"), chunks: 10)
        #expect(casting.map(\.fileHash) == [b] && casting[0].coverage == 1 && casting[0].page == 2)
        #expect(try store.keywordMatches(words: words("캐스팅"), chunks: 10).map(\.fileHash) == [b])
        // A word no chunk has weighs more than one two chunks have.
        let partial = try store.keywordMatches(words: [["driving"], ["lidar"]], chunks: 10)
        #expect(partial.map(\.fileHash) == [a])
        #expect(partial[0].coverage > 0 && partial[0].coverage < 0.5)
        #expect(try store.keywordMatches(words: [["lidar"]], chunks: 10).isEmpty)
        #expect(try store.keywordMatches(words: [], chunks: 10).isEmpty)

        // Saving a version again replaces its text; text is kept even without vectors.
        try store.saveFileChunks([(a, FileIndexRecord(chunks: 0, error: "text could not be embedded"), [])],
                                 texts: [a: [text("lidar point clouds")]], modelKey: "m")
        try checkTextIndex(url)
        #expect(try store.keywordMatches(words: [["navsim"]], chunks: 10).isEmpty)
        #expect(try store.keywordMatches(words: [["lidar"]], chunks: 10).map(\.fileHash) == [a])

        // Text leaves with its version.
        #expect(try store.pruneFileIndex(keeping: [a, b], modelKey: "m") == 1)
        try checkTextIndex(url)
        #expect(try store.keywordMatches(words: [["결과"]], chunks: 10).isEmpty)
        // Text a record of another model still has is marked as gone for that record.
        try store.saveFileChunks([(a, FileIndexRecord(chunks: 1), chunks(1))], texts: [a: [text("lidar point clouds")]],
                                 modelKey: "other")
        try checkTextIndex(url)
        try store.pruneFileIndex(keeping: [b], modelKey: "m")
        try checkTextIndex(url)
        #expect(try store.keywordMatches(words: [["lidar"]], chunks: 10).isEmpty)
        #expect(try store.fileHashesWithoutText(modelKey: "other") == [a])
        // And with the last record of it.
        try store.pruneOtherModels(keeping: "other")
        try checkTextIndex(url)
        #expect(try store.keywordMatches(words: words("다이캐스팅"), chunks: 10).isEmpty)
    }

    /// A database from before keyword search (v5) opens with its records marked as having no text,
    /// except those with no text to read (an image without any); text saved for them later is
    /// found, and a version without a record gets none.
    @Test func v5DatabaseIsMigratedWithoutText() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "index.sqlite")
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try IndexStore.migrator.migrate(legacy, upTo: "v5-chunk-page")
            try legacy.write { db in
                try db.execute(sql: "INSERT INTO model (id, key) VALUES (1, 'm')")
                for (hash, chunks, error) in [(a, 1, nil), (b, 1, nil), (d, 0, "text could not be embedded")] as [(String, Int, String?)] {
                    try db.execute(sql: "INSERT INTO fileIndexed (modelId, fileHash, chunks, partial, error, indexedAt) VALUES (1, ?, ?, 0, ?, 0)",
                                   arguments: [IndexStore.hashValue(hash), chunks, error])
                }
                // a: a PDF's text; b: an image with no text in it.
                for (hash, kind) in [(a, ChunkKind.text), (b, .image)] {
                    try db.execute(sql: "INSERT INTO fileChunk (modelId, fileHash, seq, kind, hub, vector, page) VALUES (1, ?, 0, ?, 0.5, ?, 3)",
                                   arguments: [IndexStore.hashValue(hash), Int(kind.rawValue), IndexStore.float16Data([1, 0, 0, 0])])
                }
            }
        }
        let store = try IndexStore(url: url)
        #expect(try store.fileIndexRecords(modelKey: "m")[a] == FileIndexRecord(chunks: 1))
        var pages: [Int?] = []
        try store.forEachFileChunk(hashes: [a], modelKey: "m", dimensions: 4) { _, _, _, page, _ in pages.append(page) }
        #expect(pages == [3])
        #expect(try store.fileHashesWithoutText(modelKey: "m") == [a, d])
        #expect(try store.keywordMatches(words: [["navsim"]], chunks: 10).isEmpty)

        #expect(try store.saveFileTexts([(a, [text("NAVSIM benchmark", page: 3)]), (c, [text("NAVSIM elsewhere", page: 1)])]) == 1)
        try checkTextIndex(url)
        #expect(try store.fileHashesWithoutText(modelKey: "m") == [d])
        let hits = try store.keywordMatches(words: [["navsim"]], chunks: 10)
        #expect(hits.map(\.fileHash) == [a] && hits[0].page == 3)
    }

    @Test func rankerFusesKeywordMatchesAsTheirOwnList() {
        let analysis = QueryAnalyzer.analyze("navsim")
        let kinds: [String: ItemKind] = ["app": .application, "file": .file]
        // The file's name also matches, but only loosely (fuzzy): that is noise and does not count.
        let input = HybridRanker.Input(analysis: analysis, lexical: [LexicalHit(itemID: "file", score: 0.2, tier: .fuzzy)],
                                       semantic: [.init(itemID: "app", cosine: 0.6)],
                                       fileKeyword: [.init(itemID: "file", coverage: 1)], kinds: kinds)
        let hybrid = HybridRanker.rank(input, mode: .hybrid, config: .default, limit: 10)
        // By default a file found only by its words stays below the best semantic item.
        #expect(hybrid.map(\.itemID) == ["app", "file"])
        #expect(hybrid[1].signals == [.lexical])
        #expect(hybrid[1].breakdown.keywordRank == 1 && hybrid[1].breakdown.keywordCoverage == 1)
        #expect(hybrid[1].breakdown.lexicalRank == nil && hybrid[1].breakdown.lexicalScore == nil)
        #expect(HybridRanker.rank(input, mode: .semantic, config: .default, limit: 10).map(\.itemID) == ["app"])
        #expect(HybridRanker.rank(input, mode: .lexical, config: .default, limit: 10).isEmpty)
        // Found by its content and by its words, it goes first.
        var both = input
        both.fileSemantic = [.init(itemID: "file", cosine: 0.5)]
        let fused = HybridRanker.rank(both, mode: .hybrid, config: .default, limit: 10)
        #expect(fused.map(\.itemID) == ["file", "app"])
        #expect(fused[0].signals == [.lexical, .semantic])
        // A file found by its words is not a loose name match: it stays.
        let results = hybrid.map {
            SearchResult(item: makeItem($0.itemID, kinds[$0.itemID]!, title: $0.itemID), score: $0.score, signals: $0.signals,
                         breakdown: $0.breakdown)
        }
        #expect(ResultSections.arrange(results, analysis: analysis, config: .default).map(\.id) == ["app", "file"])
    }
}

@Suite("Keyword search in the engine")
struct KeywordEngineTests {
    private func makeEngine(_ store: IndexStore, _ embedder: (any TextEmbedder)?, folder: TempFolder,
                            config: RankingConfig = .default) async -> SearchEngine {
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems)], config: config)
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        await engine.setFileContentExtractor(extractor)
        await engine.setFileFolders([folder.url])
        return engine
    }

    @Test func filesAreFoundByTheirWordsEvenWithoutTheModel() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("drive.pdf", pages: ["NAVSIM is a benchmark for autonomous driving policies, evaluated in simulation"])
        try folder.writePDF("cast.pdf", pages: ["다이캐스팅 공정의 품질 관리와 금형 설계에 관한 보고서"])
        let store = try IndexStore.inMemory()
        await makeEngine(store, FakeEmbedder(), folder: folder).refresh()

        let engine = await makeEngine(store, nil, folder: folder)
        await engine.loadFromStore()
        let navsim = try await engine.fullSearch("NAVSIM", limit: 5)
        #expect(navsim.first?.item.title == "drive.pdf")
        #expect(navsim.first?.signals == [.lexical])
        #expect(navsim.first?.breakdown.keywordRank == 1)
        let casting = try await engine.fullSearch("캐스팅 금형", limit: 5)
        #expect(casting.first?.item.title == "cast.pdf")
        // The instant (lexical) path does not search file text.
        #expect(await engine.instantSearch("NAVSIM", limit: 5).allSatisfy { $0.item.kind != .file })
    }

    /// "protocol 영수증": both files have "protocol" in every chunk but neither has 영수/수증, so
    /// they cover little of the query and stay out; without the gate they come in.
    @Test func commonWordsDoNotPullFilesIn() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("layers.pdf", pages: ["Network protocol design: the network layer forwards packets between hosts"])
        try folder.writePDF("home.pdf", pages: ["Home router protocol setup and troubleshooting checklist"])
        let store = try IndexStore.inMemory()
        let engine = await makeEngine(store, FakeEmbedder(), folder: folder)
        await engine.refresh()
        func keywordFiles(_ query: String, _ config: RankingConfig = .default) async throws -> [String] {
            await engine.setConfig(config)
            return try await engine.fullSearch(query, limit: 20).filter { $0.breakdown.keywordRank != nil }.map(\.item.title)
        }
        var ungated = RankingConfig.default
        ungated.minFileKeywordCoverage = 0
        ungated.minFileKeywordRarity = 0
        #expect(try await keywordFiles("protocol 영수증").isEmpty)
        #expect(try await keywordFiles("protocol 영수증", ungated).count == 2)
        #expect(try await keywordFiles("forwards packets") == ["layers.pdf"])
    }

    /// Without the content search (no model here) a file is listed for its words only when few
    /// files have them: "meeting" is in all three, "zyxquant" in one.
    @Test func aCommonWordListsNoFileTheContentSearchMissed() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("minutes.pdf", pages: ["Minutes of the weekly meeting about the zyxquant release"])
        try folder.writePDF("agenda.pdf", pages: ["Agenda for the board meeting in March"])
        try folder.writePDF("travel.pdf", pages: ["Travel plan for the partner meeting in Busan"])
        let store = try IndexStore.inMemory()
        await makeEngine(store, FakeEmbedder(), folder: folder).refresh()
        let engine = await makeEngine(store, nil, folder: folder)
        await engine.loadFromStore()
        func keywordFiles(_ query: String) async throws -> [String] {
            try await engine.fullSearch(query, limit: 20).filter { $0.breakdown.keywordRank != nil }.map(\.item.title)
        }
        #expect(try await keywordFiles("meeting").isEmpty)
        #expect(try await keywordFiles("zyxquant") == ["minutes.pdf"])
        var anyWord = RankingConfig.default
        anyWord.minFileKeywordRarity = 0
        await engine.setConfig(anyWord)
        #expect(try await keywordFiles("meeting").count == 3)
    }

    /// Text whose embedding fails is still kept for keyword search.
    @Test func textIsKeptWhenItsEmbeddingFails() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("good.pdf", pages: ["Quarterly sales report for the northern region"])
        try folder.writePDF("bad.pdf", pages: ["POISON text that the embedder rejects every time, zyxquant"])
        let store = try IndexStore.inMemory()
        let engine = await makeEngine(store, PoisonEmbedder(), folder: folder)
        let stats = await engine.refreshWithStats()
        #expect(stats.fileErrors == 1)
        #expect(try store.keywordMatches(words: [["zyxquant"]], chunks: 10).count == 1)
        #expect(try await engine.fullSearch("zyxquant", limit: 30).contains { $0.item.title == "bad.pdf" && $0.breakdown.keywordRank == 1 })
    }

    /// A query that names an item ("wi-fi network": the Wi‑Fi setting) gets no keyword matches,
    /// whatever the files say.
    @Test func aQueryNamingAnItemGetsNoKeywordMatches() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("wifi.pdf", pages: ["Wi-Fi network survey: signal strength of the office network"])
        let store = try IndexStore.inMemory()
        let engine = await makeEngine(store, FakeEmbedder(), folder: folder)
        await engine.refresh()
        #expect(try await engine.fullSearch("wi-fi network", limit: 20).allSatisfy { $0.breakdown.keywordRank == nil })
        var always = RankingConfig.default
        always.fileKeywordMaxItemNameScore = 2
        await engine.setConfig(always)
        let results = try await engine.fullSearch("wi-fi network", limit: 20)
        #expect(results.first { $0.breakdown.keywordRank != nil }?.item.title == "wifi.pdf")
    }

    /// Files indexed before keyword search are read again once for their text, without the model
    /// and without embedding them again.
    @Test func filesIndexedWithoutTextAreReadOnceForIt() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("drive.pdf", pages: ["NAVSIM is a benchmark for autonomous driving policies"])
        let dir = try TempDir()
        let url = dir.url.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        let first = await makeEngine(store, FakeEmbedder(), folder: folder)
        #expect(await first.refreshWithStats().filesIndexed == 1)
        // As a v5 database left it: records, no text.
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: """
                UPDATE fileIndexed SET hasText = 0;
                INSERT INTO fileTextIndex (fileTextIndex) VALUES ('delete-all');
                DELETE FROM fileText;
                """)
        }
        #expect(try store.keywordMatches(words: [["navsim"]], chunks: 10).isEmpty)

        let embedder = FakeEmbedder()
        let engine = await makeEngine(store, embedder, folder: folder)
        let stats = await engine.refreshWithStats()
        #expect(stats.fileTextsRead == 1 && stats.filesIndexed == 0)
        #expect(embedder.calls == 0)
        #expect(try store.keywordMatches(words: [["navsim"]], chunks: 10).count == 1)
        #expect(await engine.refreshWithStats().fileTextsRead == 0)
    }
}
