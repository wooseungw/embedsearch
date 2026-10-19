import EmbedCore
import Foundation
import Testing
@testable import SearchCore

/// Source whose items can be swapped between refreshes.
final class MutableSource: ItemSource, @unchecked Sendable {
    let name = "mutable"
    private let lock = NSLock()
    private var _items: [SearchItem]
    var failing = false
    init(_ items: [SearchItem]) { _items = items }
    var items: [SearchItem] {
        get { lock.withLock { _items } }
        set { lock.withLock { _items = newValue } }
    }
    func loadItems() async throws -> [SearchItem] {
        if failing { throw FakeEmbedder.FakeError.boom }
        return items
    }
}

@Suite("Search engine")
struct SearchEngineTests {
    @Test func refreshEmbedsOnceThenUsesCache() async throws {
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems)])
        let first = await engine.refreshWithStats()
        #expect(first.embeddedNew == fixtureItems.count)
        #expect(first.embeddingCacheHits == 0)
        #expect(first.vectorCount == fixtureItems.count)
        #expect(await engine.currentState == .ready(itemCount: fixtureItems.count))

        let embeddedBefore = embedder.embeddedCount
        let second = await engine.refreshWithStats()
        #expect(second.embeddedNew == 0)
        #expect(second.embeddingCacheHits == fixtureItems.count)
        #expect(embedder.embeddedCount == embeddedBefore)
        #expect(second.sync.unchanged == fixtureItems.count)

        // A fresh engine over the same store (app relaunch) hits the cache too.
        let embedder2 = FakeEmbedder()
        let relaunch = SearchEngine(store: store, embedder: embedder2, sources: [StaticItemSource(items: fixtureItems)])
        await relaunch.loadFromStore()
        #expect(await relaunch.vectorCount == fixtureItems.count)
        #expect(embedder2.embeddedCount == 0)
    }

    @Test func changedAndVanishedItemsAreHandled() async throws {
        let source = MutableSource(fixtureItems)
        let embedder = FakeEmbedder()
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: embedder, sources: [source])
        await engine.refresh()
        var updated = Array(fixtureItems.dropLast())                     // shortcut vanished
        updated[0] = makeItem(fixtureItems[0].id, title: "계산기", subtitle: "Calculator", keywords: ["math"], text: "new card")
        source.items = updated
        let stats = await engine.refreshWithStats()
        #expect(stats.sync.deleted == 1)
        #expect(stats.sync.updated == 1)
        #expect(stats.embeddedNew == 1)                                  // only the changed card
        #expect(await engine.vectorCount == updated.count)
        #expect(await engine.item(id: fixtureItems.last!.id) == nil)
    }

    @Test func failingSourceDoesNotDeleteItems() async throws {
        let source = MutableSource(fixtureItems)
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: nil, sources: [source])
        await engine.refresh()
        source.failing = true
        let stats = await engine.refreshWithStats()
        #expect(stats.sourceErrors["mutable"] != nil)
        #expect(stats.sync.deleted == 0)
        #expect(await engine.itemCount == fixtureItems.count)
    }

    @Test func hybridSearchUsesBothSignals() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: FakeEmbedder(),
                                  sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        let results = try await engine.fullSearch("계산기", limit: 5)
        let top = try #require(results.first)
        #expect(top.item.id == "app:com.apple.calculator")
        #expect(top.signals.isSuperset(of: [.lexical, .semantic]))
        #expect(top.breakdown.lexicalRank == 1)
        #expect(top.breakdown.cosine != nil)
        #expect(top.breakdown.final == top.score)

        let semantic = try await engine.search("계산기", mode: .semantic, limit: 3)
        #expect(semantic.first?.item.id == "app:com.apple.calculator")
        #expect(semantic.allSatisfy { $0.breakdown.lexicalRank == nil })
    }

    @Test func storedQueryVectorsNeedNoModelAfterRelaunch() async throws {
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        let calls = embedder.calls
        let first = try await engine.fullSearch("계산기", limit: 10)
        let firstSemantic = try await engine.search("계산기", mode: .semantic, limit: 10)
        #expect(embedder.calls == calls + 1)
        #expect(first.contains { $0.signals.contains(.semantic) })
        #expect(!firstSemantic.isEmpty)

        // A relaunch (new engine, model not loaded) reads the query's vector from the store and
        // ranks exactly the same: the cosines too (the score in semantic mode), so the fresh vector
        // was used at stored precision.
        let embedder2 = FakeEmbedder()
        let relaunch = SearchEngine(store: store, embedder: embedder2, sources: [StaticItemSource(items: fixtureItems)])
        await relaunch.loadFromStore()
        let again = try await relaunch.fullSearch("계산기", limit: 10)
        let againSemantic = try await relaunch.search("계산기", mode: .semantic, limit: 10)
        #expect(embedder2.calls == 0)
        #expect(again.map(\.id) == first.map(\.id))
        #expect(again.map(\.score) == first.map(\.score))
        #expect(again.map(\.breakdown.cosine) == first.map(\.breakdown.cosine))
        #expect(againSemantic.map(\.id) == firstSemantic.map(\.id))
        #expect(againSemantic.map(\.score) == firstSemantic.map(\.score))
        _ = try await relaunch.fullSearch("캘린더", limit: 10)
        #expect(embedder2.calls == 1)
    }

    @Test func queryVectorsCanStayOutOfTheStore() async throws {
        let store = try IndexStore.inMemory()
        let engine = SearchEngine(store: store, embedder: FakeEmbedder(), sources: [StaticItemSource(items: fixtureItems)])
        await engine.setStoresQueryVectors(false)
        await engine.refresh()
        _ = try await engine.fullSearch("계산기", limit: 10)
        #expect(try store.queryVector("계산기", modelKey: FakeEmbedder().info.cacheKey) == nil)

        // Not saved, so the next engine embeds it (and, storing, saves it)…
        let embedder2 = FakeEmbedder()
        let storing = SearchEngine(store: store, embedder: embedder2, sources: [StaticItemSource(items: fixtureItems)])
        await storing.loadFromStore()
        _ = try await storing.fullSearch("계산기", limit: 10)
        #expect(embedder2.calls == 1)

        // …and one that does not store embeds it although it is stored.
        let embedder3 = FakeEmbedder()
        let notStoring = SearchEngine(store: store, embedder: embedder3, sources: [StaticItemSource(items: fixtureItems)])
        await notStoring.setStoresQueryVectors(false)
        await notStoring.loadFromStore()
        _ = try await notStoring.fullSearch("계산기", limit: 10)
        #expect(embedder3.calls == 1)
    }

    @Test func noEmbedderMeansDegradedLexicalResults() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: nil, sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        guard case .degraded = await engine.currentState else { Issue.record("expected degraded"); return }
        let results = try await engine.fullSearch("ㄱㅅㄱ", limit: 3)
        #expect(results.first?.item.id == "app:com.apple.calculator")
        #expect(results.allSatisfy { !$0.signals.contains(.semantic) })
        #expect(try await engine.search("계산기", mode: .semantic, limit: 3).isEmpty)
    }

    @Test func failingEmbedderDegradesButSearchStillWorks() async throws {
        let embedder = FakeEmbedder()
        embedder.failing = true
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: embedder, sources: [StaticItemSource(items: fixtureItems)])
        let stats = await engine.refreshWithStats()
        #expect(stats.embeddingError != nil)
        guard case .degraded = await engine.currentState else { Issue.record("expected degraded"); return }
        let results = try await engine.fullSearch("calculator", limit: 3)
        #expect(results.first?.item.id == "app:com.apple.calculator")
    }

    @Test func lateEmbedderInstallsAndEmbeds() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: nil, sources: [StaticItemSource(items: fixtureItems)])
        await engine.reportModelLoading(progress: 0.4)
        await engine.refresh()
        #expect(await engine.currentState == .loadingModel(progress: 0.4))
        await engine.setEmbedder(FakeEmbedder())
        #expect(await engine.vectorCount == fixtureItems.count)
        #expect(await engine.currentState == .ready(itemCount: fixtureItems.count))
    }

    @Test func stateStreamYieldsCurrentThenProgress() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: FakeEmbedder(),
                                  sources: [StaticItemSource(items: fixtureItems)])
        await engine.setEmbeddingBatchSize(4)
        let stream = await engine.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .idle)
        await engine.refresh()
        var seen: [EngineState] = []
        while let s = await iterator.next() {
            seen.append(s)
            if case .ready = s { break }
        }
        #expect(seen.first == .indexing(done: 0, total: fixtureItems.count))
        #expect(seen.contains(.indexing(done: 4, total: fixtureItems.count)))
        #expect(seen.last == .ready(itemCount: fixtureItems.count))
    }

    @Test func recordSelectionPromotesItemForThatQuery() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: nil, sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        let before = await engine.instantSearch("캘", limit: 5).map(\.item.id)
        #expect(before.first == "app:com.apple.calendar")
        // The user typed "캘" and opened something else twice → it moves up for "캘" and its prefixes.
        await engine.recordSelection(itemID: "app:com.apple.calculator", query: "캘")
        await engine.recordSelection(itemID: "app:com.apple.calculator", query: "캘")
        let after = await engine.instantSearch("캘", limit: 5)
        #expect(after.first?.item.id == "app:com.apple.calculator")
        #expect(after.first?.signals.contains(.memory) == true)
        // Usage signals can be switched off (evaluation).
        var config = RankingConfig()
        config.useUsageSignals = false
        await engine.setConfig(config)
        #expect(await engine.instantSearch("캘", limit: 5).first?.item.id == "app:com.apple.calendar")
    }

    @Test func instantSearchIsFastOnTwoThousandItems() async throws {
        let words = ["설정", "디스플레이", "네트워크", "키보드", "사운드", "알림", "개인정보", "보안", "배터리", "Bluetooth",
                     "Wi-Fi", "display", "sound", "keyboard", "privacy", "network", "battery", "screen", "time", "mouse"]
        var items = fixtureItems
        for i in 0..<2_000 {
            let a = words[i % words.count], b = words[(i / 7) % words.count], c = words[(i / 13) % words.count]
            items.append(makeItem("syn:\(i)", i % 3 == 0 ? .systemSetting : .application, title: "\(a) \(b) \(i)",
                                  subtitle: "\(c) › \(b)", keywords: [a, b, c, "\(c) \(a) 옵션 \(i % 50)", "keyword\(i % 300)"]))
        }
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: nil, sources: [StaticItemSource(items: items)])
        await engine.refresh()
        let queries = ["ㄷㅅㅍ", "디스플", "keybaord", "설정", "network 설정", "s", "계산기", "개인정보 보호", "wifi"]
        for q in queries { _ = await engine.instantSearch(q, limit: 10) }   // warm-up
        var worst = 0.0
        for q in queries {
            let start = Date()
            _ = await engine.instantSearch(q, limit: 10)
            worst = max(worst, Date().timeIntervalSince(start))
        }
        // Debug builds are several times slower than release; the < 5 ms target is checked with the
        // release CLI (docs/eval-results.md). This bound only catches algorithmic regressions.
        #expect(worst < 0.1, "worst instantSearch \(worst * 1000) ms")
    }
}

extension SearchEngine {
    func setEmbeddingBatchSize(_ n: Int) { embeddingBatchSize = n }
}
