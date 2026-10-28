import Testing
@testable import SearchCore

@Suite("Fusion confidence")
struct AdaptiveRankingTests {
    @Test func aWeakFuzzyMatchCannotDisplaceTheStrongerSemanticAnswer() {
        let input = HybridRanker.Input(analysis: QueryAnalyzer.analyze("adjust monitor luminance"), lexical: [
            LexicalHit(itemID: "wrong", score: 0.241, tier: .fuzzy),
            LexicalHit(itemID: "answer", score: 0.215, tier: .fuzzy)
        ], semantic: [
            .init(itemID: "answer", cosine: 0.785), .init(itemID: "wrong", cosine: 0.764)
        ], kinds: ["wrong": .systemSetting, "answer": .systemSetting])
        let result = HybridRanker.rank(input, mode: .hybrid, config: .default, limit: 2)
        #expect(result.first?.itemID == "answer")
    }

    @Test(arguments: ["ㄱㅅㄱ", "calc"])
    func initialsAndStrongNamesKeepTheirLexicalEvidence(_ query: String) {
        let initials = query == "ㄱㅅㄱ"
        let input = HybridRanker.Input(analysis: QueryAnalyzer.analyze(query), lexical: [
            .init(itemID: "named", score: initials ? 0.4 : 0.9, tier: initials ? .initials : .prefix)
        ], semantic: [.init(itemID: "other", cosine: 0.6), .init(itemID: "named", cosine: 0.5)],
            kinds: ["named": .application, "other": .application])
        #expect(HybridRanker.rank(input, mode: .hybrid, config: .default, limit: 2).first?.itemID == "named")
    }
}
