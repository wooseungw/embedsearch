import Foundation
import GRDB
import Testing
@testable import SearchCore

@Suite("Index store")
struct IndexStoreTests {
    @Test func itemsRoundTripAndSync() throws {
        let store = try IndexStore.inMemory()
        var s = try store.syncItems(Array(fixtureItems.prefix(3)))
        #expect(s == ItemSyncSummary(inserted: 3, updated: 0, unchanged: 0, deleted: 0))
        #expect(try store.allItems().sorted { $0.id < $1.id } == Array(fixtureItems.prefix(3)).sorted { $0.id < $1.id })

        let changed = makeItem(fixtureItems[0].id, title: "계산기", subtitle: "Calculator", keywords: ["new"])
        s = try store.syncItems([changed, fixtureItems[1], fixtureItems[3]])
        #expect(s == ItemSyncSummary(inserted: 1, updated: 1, unchanged: 1, deleted: 1))
        let loaded = try store.allItems()
        #expect(loaded.count == 3)
        #expect(loaded.first { $0.id == changed.id } == changed)
        #expect(!loaded.contains { $0.id == fixtureItems[2].id })
    }

    @Test func fileStoreUsesWALAndPersists() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "nested/index.sqlite")
        do {
            let store = try IndexStore(url: url)
            try store.syncItems(fixtureItems)
            try store.saveEmbeddings(["h": [0.25, -1, 3.5]], modelKey: "m")
        }
        let reopened = try IndexStore(url: url)
        #expect(try reopened.allItems().count == fixtureItems.count)
        #expect(try reopened.cachedEmbeddings(hashes: ["h"], modelKey: "m")["h"] == [0.25, -1, 3.5])
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test func embeddingCacheIsKeyedByHashAndModel() throws {
        let store = try IndexStore.inMemory()
        let v: [Float] = [0.1, 0.2, -0.3, .pi]
        try store.saveEmbeddings(["a": v, "b": [1, 2, 3, 4]], modelKey: "model@main#d4#p1")
        #expect(try store.cachedEmbeddings(hashes: ["a"], modelKey: "model@main#d4#p1") == ["a": IndexStore.storedPrecision(v)])
        #expect(try store.cachedEmbeddings(hashes: ["a"], modelKey: "other").isEmpty)
        #expect(try store.pruneEmbeddings(keeping: ["a"], modelKey: "model@main#d4#p1") == 1)
        #expect(try store.embeddingCount() == 1)
    }

    @Test func newFilesUseCompactStorage() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        try store.syncItems(fixtureItems)
        let pragmas = try DatabaseQueue(path: url.path).read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_size"), try Int.fetchOne(db, sql: "PRAGMA auto_vacuum"))
        }
        #expect(pragmas.0 == IndexStore.pageSize)
        #expect(pragmas.1 == 2)  // incremental
    }

    /// A database written by the first schema (plain JSON, hex hashes, model keys as text, float32
    /// vectors, 4 KB pages) opens with the same items and vectors (now at float16 precision),
    /// rewritten into the compact layout.
    @Test func legacyDatabaseIsUpgraded() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "index.sqlite")
        let hash = IndexStore.contentHash(fixtureItems[0])
        let vector: [Float] = [0.5, -0.25, 1e-7, .pi]
        do {
            let legacy = try DatabaseQueue(path: url.path)
            var v1 = DatabaseMigrator()
            v1.registerMigration("v1") { db in try db.execute(sql: IndexStore.schemaV1) }
            try v1.migrate(legacy)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try legacy.write { db in
                for item in fixtureItems {
                    try db.execute(sql: "INSERT INTO item (id, kind, json, contentHash, updatedAt) VALUES (?, ?, ?, ?, 0)",
                                   arguments: [item.id, item.kind.rawValue, String(decoding: try encoder.encode(item), as: UTF8.self),
                                               IndexStore.contentHash(item)])
                }
                for (h, key) in [(hash, "m1"), ("legacy-text-key", "m1"), (hash, "m2")] {
                    try db.execute(sql: "INSERT INTO embedding (contentHash, modelKey, dimensions, vector, createdAt) VALUES (?, ?, 4, ?, 0)",
                                   arguments: [h, key, IndexStore.data(from: vector)])
                }
            }
            #expect(try legacy.read { try Int.fetchOne($0, sql: "PRAGMA page_size") } == 4096)
        }
        let store = try IndexStore(url: url)
        let stored = IndexStore.storedPrecision(vector)
        #expect(try store.allItems() == fixtureItems.sorted { $0.id < $1.id })
        #expect(try store.cachedEmbeddings(hashes: [hash, "legacy-text-key"], modelKey: "m1") == [hash: stored, "legacy-text-key": stored])
        #expect(try store.cachedEmbeddings(hashes: [hash], modelKey: "m2") == [hash: stored])
        #expect(try store.syncItems(fixtureItems).unchanged == fixtureItems.count)
        #expect(try store.pruneOtherModels(keeping: "m1") == 1)
        #expect(try store.embeddingCount() == 2)
        let pageSize = try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "PRAGMA page_size") }
        #expect(pageSize == IndexStore.pageSize)
    }

    @Test func float16StorageRoundsToNearestEven() {
        var rng = SystemRandomNumberGenerator()
        let values: [Float] = [0, -0, 1, -1, 0.1, .pi, 65504, 1e-7, 6e-8, 5.96e-8, 1e-9, 0.333333]
            + (0..<5_000).map { _ in Float.random(in: -1...1, using: &rng) }
        let stored = IndexStore.storedPrecision(values)
        #expect(IndexStore.float16Data(values).count == values.count * 2)
        #expect(IndexStore.storedPrecision(stored) == stored)                          // idempotent
        #if arch(arm64)
        #expect(zip(values, stored).allSatisfy { Float(Float16($0)).bitPattern == $1.bitPattern })
        #endif
        let worst = zip(values.suffix(5_000), stored.suffix(5_000)).map { abs($0 - $1) }.max()!
        #expect(worst <= 1.0 / 2048)                                                    // half ulp at |x| ≤ 1
    }

    @Test func hashEncodingRoundTrips() {
        let hex = IndexStore.contentHash(fixtureItems[0])
        #expect(IndexStore.hashValue(hex).storage == .blob(Data(stride(from: 0, to: 64, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })))
        for h in [hex, "h", "a", hex.uppercased(), String(hex.dropLast()), hex + "0", "", String(repeating: "g", count: 64)] {
            #expect(IndexStore.hashString(IndexStore.hashValue(h)) == h)
        }
    }

    @Test func contentHashTracksEmbeddingContentOnly() {
        let a = makeItem("x", title: "A", keywords: ["k1"], text: "same")
        let b = makeItem("y", title: "A", keywords: ["k2"], text: "same")
        let c = makeItem("x", title: "A", keywords: ["k1"], text: "different")
        #expect(IndexStore.contentHash(a) == IndexStore.contentHash(b))
        #expect(IndexStore.contentHash(a) != IndexStore.contentHash(c))
        #expect(IndexStore.contentHash(a).count == 64)
    }

    @Test func selectionsDecayAndAccumulate() throws {
        let store = try IndexStore.inMemory()
        let day: TimeInterval = 86_400
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try store.recordSelection(itemID: "app:x", query: "Calc", at: t0, halfLife: 10 * day)
        try store.recordSelection(itemID: "app:x", query: "calc", at: t0.addingTimeInterval(10 * day), halfLife: 10 * day)
        let u = try #require(try store.usageRecords()["app:x"])
        #expect(u.count == 2)
        #expect(abs(u.frecency - 1.5) < 1e-9)     // 1 decayed by one half-life + 1
        let mem = try store.queryMemoryRecords()
        #expect(mem.count == 1)                     // "Calc" and "calc" normalize to one key
        #expect(mem[0].query == "calc" && mem[0].count == 2)
        try store.resetUsage()
        #expect(try store.usageRecords().isEmpty)
    }

    @Test func queryVectorsAreKeyedByModelAndCapped() throws {
        let store = try IndexStore.inMemory()
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_000_000 + s) }
        let v: [Float] = [0.1, -0.2, 0.3, .pi], w: [Float] = [1, 0.5, -0.25, 1e-7]
        try store.saveQueryVector(v, query: "계산기", modelKey: "m1", now: t(0))
        try store.saveQueryVector(w, query: "계산기", modelKey: "m2", now: t(0))       // same text, another space
        #expect(try store.queryVector("계산기", modelKey: "m1", now: t(1)) == IndexStore.storedPrecision(v))
        #expect(try store.queryVector("계산기", modelKey: "m2", now: t(1)) == IndexStore.storedPrecision(w))
        #expect(try store.queryVector("계산기 ", modelKey: "m1", now: t(1)) == nil)     // the exact text only
        #expect(try store.queryVector("캘린더", modelKey: "m1", now: t(1)) == nil)
        #expect(try store.queryVector("계산기", modelKey: "unknown", now: t(1)) == nil)

        // m2's vectors are all newer than m1's: m1's cap neither counts nor drops them.
        for (i, q) in ["x", "y", "z"].enumerated() {
            try store.saveQueryVector(w, query: q, modelKey: "m2", now: t(100 + Double(i)))
        }
        // At most `limit` per model, least recently used out first; reading a vector is a use.
        try store.saveQueryVector(v, query: "a", modelKey: "m1", now: t(2), limit: 3)
        try store.saveQueryVector(v, query: "b", modelKey: "m1", now: t(3), limit: 3)
        _ = try store.queryVector("계산기", modelKey: "m1", now: t(4))                 // else it would go first
        try store.saveQueryVector(v, query: "c", modelKey: "m1", now: t(5), limit: 3)  // drops a
        try store.saveQueryVector(v, query: "d", modelKey: "m1", now: t(6), limit: 3)  // drops b
        let m1 = try ["계산기", "a", "b", "c", "d"].filter { try store.queryVector($0, modelKey: "m1", now: t(7)) != nil }
        #expect(m1 == ["계산기", "c", "d"])
        let m2 = try ["계산기", "x", "y", "z"].filter { try store.queryVector($0, modelKey: "m2", now: t(200)) != nil }
        #expect(m2.count == 4)

        // m2's four query vectors are the only rows of other models.
        #expect(try store.pruneOtherModels(keeping: "m1") == 4)
        #expect(try store.queryVector("d", modelKey: "m1", now: t(8)) != nil)
        try store.resetUsage()
        #expect(try store.queryVector("d", modelKey: "m1", now: t(9)) == nil)
    }

    @Test func justSavedQueryVectorSurvivesPruning() throws {
        let store = try IndexStore.inMemory()
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_000_000 + s) }
        let v: [Float] = [0.5, -0.5]
        for (i, q) in ["a", "b", "c"].enumerated() {
            try store.saveQueryVector(v, query: q, modelKey: "m", now: t(10 + Double(i)), limit: 3)
        }
        // Older than every other row (the clock went back): the oldest other one goes instead.
        try store.saveQueryVector(v, query: "late", modelKey: "m", now: t(0), limit: 3)
        let kept = try ["a", "b", "c", "late"].filter { try store.queryVector($0, modelKey: "m", now: t(20)) != nil }
        #expect(kept == ["b", "c", "late"])
    }
}

@Suite("Ranking")
struct RankingTests {
    @Test func rrf() {
        #expect(HybridRanker.rrf(rank: 1, k: 60) == 1.0 / 61)
        #expect(HybridRanker.rrf(rank: 10, k: 60) == 1.0 / 70)
    }

    @Test func frecencyDecayAndBuckets() {
        let day: TimeInterval = 86_400
        #expect(Frecency.decay(8, elapsed: 14 * day, halfLife: 14 * day) == 4)
        #expect(Frecency.decay(8, elapsed: 28 * day, halfLife: 14 * day) == 2)
        #expect(Frecency.recencyMultiplier(elapsed: 60) == 4)
        #expect(Frecency.recencyMultiplier(elapsed: 2 * 3_600) == 2)
        #expect(Frecency.recencyMultiplier(elapsed: 3 * day) == 0.5)
        #expect(Frecency.recencyMultiplier(elapsed: 30 * day) == 0.25)

        let now = Date()
        let config = RankingConfig()
        let fresh = UsageRecord(itemID: "a", count: 1, frecency: 1, lastUsed: now.addingTimeInterval(-60))
        let old = UsageRecord(itemID: "a", count: 1, frecency: 1, lastUsed: now.addingTimeInterval(-60 * day))
        let heavy = UsageRecord(itemID: "a", count: 500, frecency: 500, lastUsed: now)
        #expect(Frecency.boost(fresh, now: now, config: config) > Frecency.boost(old, now: now, config: config))
        #expect(Frecency.boost(heavy, now: now, config: config) == config.frecencyCap)
        #expect(Frecency.boost(nil, now: now, config: config) == 0)
    }

    @Test func queryMemoryMatchesExactPrefixAndExtension() {
        let now = Date()
        let config = RankingConfig()
        let records = [
            QueryMemoryRecord(query: "cal", itemID: "calc", count: 1, weight: 1, lastUsed: now),
            QueryMemoryRecord(query: "calendar", itemID: "cal", count: 1, weight: 1, lastUsed: now),
            QueryMemoryRecord(query: "zzz", itemID: "z", count: 1, weight: 1, lastUsed: now),
        ]
        let exact = Frecency.memoryBoosts(records, query: "cal", now: now, config: config)
        #expect(exact["calc"]! > exact["cal"]!)       // exact beats "query is a prefix of remembered"
        #expect(exact["z"] == nil)
        let ext = Frecency.memoryBoosts(records, query: "calc", now: now, config: config)
        #expect(ext["calc"] != nil && ext["calc"]! < exact["calc"]!)
        #expect(Frecency.memoryBoosts(records, query: "", now: now, config: config).isEmpty)
    }

    func input(_ q: String, lexical: [LexicalHit], semantic: [HybridRanker.SemanticHit]?, memory: [String: Double] = [:],
               frecency: [String: Double] = [:]) -> HybridRanker.Input {
        HybridRanker.Input(analysis: QueryAnalyzer.analyze(q), lexical: lexical, semantic: semantic,
                           kinds: Dictionary(uniqueKeysWithValues: fixtureItems.map { ($0.id, $0.kind) }),
                           frecency: frecency, memory: memory)
    }

    @Test func semanticOnlyHitsNeedMinimumCosine() {
        var config = RankingConfig()
        config.minSemanticCosine = 0.5
        let sem = [HybridRanker.SemanticHit(itemID: "app:com.apple.Notes", cosine: 0.7),
                   HybridRanker.SemanticHit(itemID: "app:com.apple.Safari", cosine: 0.4)]
        let out = HybridRanker.rank(input("x", lexical: [], semantic: sem), mode: .hybrid, config: config, limit: 10)
        #expect(out.map(\.itemID) == ["app:com.apple.Notes"])
        #expect(out[0].signals == [.semantic])
        #expect(out[0].breakdown.semanticRank == 1 && out[0].breakdown.cosine == 0.7)
        // Pure semantic mode ranks by cosine without the threshold.
        let pure = HybridRanker.rank(input("x", lexical: [], semantic: sem), mode: .semantic, config: config, limit: 10)
        #expect(pure.map(\.itemID) == ["app:com.apple.Notes", "app:com.apple.Safari"])
    }

    @Test func fusionCombinesBothListsAndFillsBreakdown() throws {
        let lex = [LexicalHit(itemID: "app:com.apple.calculator", score: 0.5, tier: .substring),
                   LexicalHit(itemID: "app:com.apple.calendar", score: 0.45, tier: .substring)]
        let sem = [HybridRanker.SemanticHit(itemID: "app:com.apple.calendar", cosine: 0.8),
                   HybridRanker.SemanticHit(itemID: "app:com.apple.calculator", cosine: 0.3)]
        let out = HybridRanker.rank(input("q", lexical: lex, semantic: sem), mode: .hybrid, config: RankingConfig(), limit: 10)
        let cal = try #require(out.first { $0.itemID == "app:com.apple.calendar" })
        #expect(cal.signals == [.lexical, .semantic])
        #expect(cal.breakdown.lexicalRank == 2 && cal.breakdown.semanticRank == 1)
        #expect(cal.breakdown.final == cal.score)
        // Lexical-only mode ignores the semantic list.
        let lexOnly = HybridRanker.rank(input("q", lexical: lex, semantic: sem), mode: .lexical, config: RankingConfig(), limit: 10)
        #expect(lexOnly.first?.itemID == "app:com.apple.calculator")
        #expect(lexOnly.allSatisfy { $0.breakdown.semanticRank == nil })
    }

    @Test func exactLexicalMatchBeatsSemanticFavourite() {
        // "safari" typed exactly must stay first even if the embedding prefers another browser-ish item.
        let lex = [LexicalHit(itemID: "app:com.apple.Safari", score: 1.0, tier: .exact)]
        let sem = [HybridRanker.SemanticHit(itemID: "app:com.apple.Notes", cosine: 0.9),
                   HybridRanker.SemanticHit(itemID: "app:com.apple.calendar", cosine: 0.85),
                   HybridRanker.SemanticHit(itemID: "app:com.apple.Safari", cosine: 0.6)]
        let out = HybridRanker.rank(input("safari", lexical: lex, semantic: sem), mode: .hybrid, config: RankingConfig(), limit: 3)
        #expect(out.first?.itemID == "app:com.apple.Safari")
    }

    @Test func memoryAndFrecencyLiftItemsAndAddSignals() {
        let lex = [LexicalHit(itemID: "app:com.apple.calendar", score: 0.85, tier: .prefix),
                   LexicalHit(itemID: "app:com.apple.calculator", score: 0.84, tier: .prefix)]
        let config = RankingConfig()
        let base = HybridRanker.rank(input("ca", lexical: lex, semantic: nil), mode: .lexical, config: config, limit: 2)
        #expect(base.first?.itemID == "app:com.apple.calendar")
        let boosted = HybridRanker.rank(input("ca", lexical: lex, semantic: nil, memory: ["app:com.apple.calculator": 0.02]),
                                        mode: .lexical, config: config, limit: 2)
        #expect(boosted.first?.itemID == "app:com.apple.calculator")
        #expect(boosted.first?.signals.contains(.memory) == true)
        #expect(boosted.first?.breakdown.frecencyBoost == 0.02)
        let viaFrecency = HybridRanker.rank(input("ca", lexical: lex, semantic: nil, frecency: ["app:com.apple.calculator": 0.01]),
                                            mode: .lexical, config: config, limit: 2)
        #expect(viaFrecency.first?.itemID == "app:com.apple.calculator")
        #expect(viaFrecency.first?.signals.contains(.frecency) == true)
        // Memory alone (no lexical match) still surfaces the remembered item.
        let memoryOnly = HybridRanker.rank(input("browser", lexical: [], semantic: nil, memory: ["app:com.apple.Safari": 0.02]),
                                           mode: .lexical, config: config, limit: 5)
        #expect(memoryOnly.map(\.itemID) == ["app:com.apple.Safari"])
    }

    @Test func intentRoutingBoostsRequestedKind() {
        // Same lexical strength; "설정" in the query routes to the settings item.
        let lex = [LexicalHit(itemID: "app:com.apple.Notes", score: 0.7, tier: .wordPrefix),
                   LexicalHit(itemID: "setting:com.apple.Keyboard-Settings.extension#Shortcuts", score: 0.7, tier: .wordPrefix)]
        let out = HybridRanker.rank(input("키보드 설정", lexical: lex, semantic: nil), mode: .lexical, config: RankingConfig(), limit: 2)
        #expect(out.first?.itemID == "setting:com.apple.Keyboard-Settings.extension#Shortcuts")
    }
}

extension IndexStoreTests {
    @Test func v8MigrationPreservesChunksAndMakesLegacyEmbeddingErrorsRetryable() throws {
        let folder = try TempDir(), url = folder.url.appending(path: "legacy.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try IndexStore.migrator.migrate(queue, upTo: "v8-card-text-no-page")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO model (id, key) VALUES (1, 'legacy')")
            try db.execute(sql: "INSERT INTO fileIndexed (modelId,fileHash,chunks,partial,error,indexedAt,hasText) VALUES (1,'good',1,0,NULL,0,1), (1,'failed',0,0,'image could not be embedded',0,1)")
            try db.execute(sql: "INSERT INTO fileChunk (modelId,fileHash,seq,kind,hub,vector,page) VALUES (1,'good',0,0,0,?,2)", arguments: [IndexStore.float16Data([1, 0])])
            try db.execute(sql: "INSERT INTO fileText (id,fileHash,seq,page) VALUES (1,'good',0,2)")
            try db.execute(sql: "INSERT INTO fileTextIndex (rowid,tokens) VALUES (1,'orchard')")
        }
        try queue.close()
        let store = try IndexStore(url: url)
        let records = try store.fileIndexRecords(modelKey: "legacy")
        #expect(records["good"]?.chunks == 1)
        #expect(records["failed"]?.shouldRetry(at: Date()) == true)
        #expect(try store.keywordMatches(words: [["orchard"]], chunks: 10).first?.fileHash == "good")
        var count = 0
        try store.forEachFileChunk(hashes: ["good"], modelKey: "legacy", dimensions: 2) { _, _, _, page, _ in
            count += 1
            #expect(page == 2)
        }
        #expect(count == 1)
    }
}
