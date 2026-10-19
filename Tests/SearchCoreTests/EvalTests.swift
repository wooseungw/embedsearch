import Foundation
import Testing
@testable import SearchCore

@Suite("Evaluation")
struct EvalTests {
    @Test func matcherSemantics() {
        let calc = fixtureItems[0]
        #expect(EvalMatcher(id: "app:com.apple.calculator").matches(calc))
        #expect(EvalMatcher(idPrefix: "app:com.apple.").matches(calc))
        #expect(EvalMatcher(kind: .application, title: "calc").matches(calc))        // subtitle "Calculator"
        #expect(EvalMatcher(kind: .application, title: "계산").matches(calc))
        #expect(!EvalMatcher(kind: .systemSetting, title: "계산").matches(calc))
        #expect(!EvalMatcher().matches(calc))                                          // empty matcher never matches
        let wifi = fixtureItems.first { $0.kind == .systemSetting }!
        #expect(EvalMatcher(kind: .systemSetting, title: "wifi").matches(wifi))       // normalized compact match
    }

    @Test func metrics() {
        let q = EvalQuery(q: "x", lang: "en", type: "exact", expect: [EvalMatcher(id: "a")])
        let outcomes = [1, 2, nil, 5, 11].map { EvalOutcome(query: q, rank: $0, top: [], latency: 0) }
        let m = EvalMetrics.compute(outcomes)
        #expect(m.count == 5)
        #expect(abs(m.mrr10 - (1 + 0.5 + 0.2) / 5) < 1e-12)
        #expect(m.success1 == 0.2)
        #expect(m.success5 == 0.6)
        #expect(m.success10 == 0.6)
    }

    @Test func runnerFindsFirstRelevantRank() async throws {
        let engine = SearchEngine(store: try IndexStore.inMemory(), embedder: FakeEmbedder(),
                                  sources: [StaticItemSource(items: fixtureItems)])
        await engine.refresh()
        let queries = [
            EvalQuery(q: "계산기", lang: "ko", type: "exact", expect: [EvalMatcher(id: "app:com.apple.calculator")]),
            EvalQuery(q: "ㄱㅅㄱ", lang: "ko", type: "chosung", expect: [EvalMatcher(id: "app:com.apple.calculator")]),
            EvalQuery(q: "zzzz qqqq", lang: "en", type: "exact", expect: [EvalMatcher(id: "app:com.apple.calculator")]),
        ]
        let report = await Evaluator.run(engine: engine, queries: queries, mode: .lexical)
        #expect(report.outcomes.map(\.rank) == [1, 1, nil])
        #expect(report.byLang.map(\.0) == ["en", "ko"])
        #expect(report.failures.count == 1)
    }

    static let evalFile = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "eval/queries.jsonl")

    @Test(.enabled(if: liveSystem && FileManager.default.fileExists(atPath: evalFile.path)))
    func evalSetIsWellFormedAndTargetsExist() async throws {
        let queries = try EvalSet.load(Self.evalFile)
        #expect((80...120).contains(queries.count), "\(queries.count) queries")
        #expect(Set(queries.map(\.q)).count == queries.count, "duplicate queries")
        #expect(Set(queries.map(\.lang)).isSubset(of: ["ko", "en", "mixed"]))
        #expect(queries.allSatisfy { !$0.expect.isEmpty })
        // Every expectation must point at something that exists in this Mac's corpus.
        var items: [SearchItem] = []
        for source in DefaultSources.all() { items += try await source.loadItems() }
        let unmatched = EvalSet.unmatchedExpectations(queries, items: items)
        #expect(unmatched.isEmpty, "\(unmatched)")
    }
}
