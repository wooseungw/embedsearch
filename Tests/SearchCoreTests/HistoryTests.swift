import EmbedCore
import Foundation
import Testing
@testable import SearchCore

private actor GatedQueryEmbedder: TextEmbedder {
    nonisolated let info = EmbeddingModelInfo(modelID: "gated", revision: "1", dimensions: 2)
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        if inputs.contains(where: { if case .query = $0 { true } else { false } }) {
            waiting = true
            await withCheckedContinuation { gate = $0 }
        }
        return inputs.map { _ in [1, 0] }
    }
    func resume() { gate?.resume(); gate = nil }
}

@Suite("Search history privacy")
struct HistoryTests {
    @Test func disabledHistoryDoesNotRecordSelectionsOrQueryVectors() async throws {
        let store = try IndexStore.inMemory(), embedder = FakeEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems)])
        try await engine.setHistoryPolicy(enabled: false, retentionDays: 30)
        await engine.refresh()
        await engine.recordSelection(itemID: fixtureItems[0].id, query: "private query")
        _ = try await engine.fullSearch("private query", limit: 5)
        #expect(try store.queryMemoryRecords().isEmpty)
        #expect(try store.usageRecords().isEmpty)
        #expect(try store.queryVector("private query", modelKey: embedder.info.cacheKey) == nil)
    }

    @Test func retentionRemovesExpiredRecordsButKeepsRecentOnes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), store = try IndexStore.inMemory()
        try store.recordSelection(itemID: "old", query: "old secret", at: now.addingTimeInterval(-31 * 86400), halfLife: 86400)
        try store.recordSelection(itemID: "recent", query: "recent", at: now.addingTimeInterval(-29 * 86400), halfLife: 86400)
        try store.saveQueryVector([1, 0], query: "old secret", modelKey: "m", now: now.addingTimeInterval(-31 * 86400))
        try store.saveQueryVector([1, 0], query: "recent", modelKey: "m", now: now.addingTimeInterval(-29 * 86400))
        let engine = SearchEngine(store: store, embedder: nil, sources: [], now: { now })
        await engine.loadFromStore()
        #expect(try store.queryMemoryRecords().map(\.query) == ["recent"])
        #expect(Set(try store.usageRecords().keys) == ["recent"])
        #expect(try store.queryVector("old secret", modelKey: "m", now: now) == nil)
        #expect(try store.queryVector("recent", modelKey: "m", now: now) != nil)
    }

    @Test func clearAlsoRemovesPersonalizationFromTheRunningEngine() async throws {
        let store = try IndexStore.inMemory()
        let engine = SearchEngine(store: store, embedder: FakeEmbedder(), sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        await engine.recordSelection(itemID: fixtureItems[0].id, query: "캘")
        try await engine.clearHistory()
        #expect(try store.queryMemoryRecords().isEmpty)
        #expect(try store.usageRecords().isEmpty)
        let results = await engine.instantSearch("캘", limit: 10)
        #expect(results.allSatisfy { !$0.signals.contains(.memory) && !$0.signals.contains(.frecency) })
    }

    @Test func aQueryStartedBeforeDeletionCannotRestoreItsVector() async throws {
        let store = try IndexStore.inMemory(), embedder = GatedQueryEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: [fixtureItems[0]])])
        await engine.refresh()
        let search = Task { try await engine.fullSearch("secret", limit: 5) }
        while !(await embedder.waiting) { await Task.yield() }
        try await engine.clearHistory()
        await embedder.resume()
        _ = try await search.value
        #expect(try store.queryVector("secret", modelKey: embedder.info.cacheKey) == nil)
    }
}
