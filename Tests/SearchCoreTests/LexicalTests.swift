import Foundation
import Testing
@testable import SearchCore

@Suite("Lexical matcher tiers")
struct LexicalMatcherTests {
    func m(_ q: String, _ t: String, fuzzy: Bool = true) -> LexicalMatcher.Match? {
        LexicalMatcher.match(LexQuery(q), LexTerm(t), allowFuzzy: fuzzy)
    }

    @Test func tiersAreOrdered() throws {
        let exact = try #require(m("계산기", "계산기"))
        let prefix = try #require(m("계산", "계산기"))
        let wordPrefix = try #require(m("밝기", "디스플레이 밝기"))
        let substring = try #require(m("산기", "계산기"))
        let initials = try #require(m("ㄱㅅㄱ", "계산기"))
        let fuzzy = try #require(m("calculater", "calculator"))
        #expect(exact.tier == .exact)
        #expect(prefix.tier == .prefix)
        #expect(wordPrefix.tier == .wordPrefix)
        #expect(substring.tier == .substring)
        #expect(initials.tier == .initials)
        #expect(fuzzy.tier == .fuzzy)
        let scores = [exact, prefix, wordPrefix, substring, initials, fuzzy].map(\.score)
        #expect(scores == scores.sorted(by: >))
        #expect(Set(scores).count == scores.count)
    }

    @Test func caseWidthAndSeparatorsDoNotMatter() {
        #expect(m("CALCULATOR", "Calculator")?.tier == .exact)
        #expect(m("wifi", "Wi‑Fi")?.tier == .exact)
        #expect(m("wi-fi", "Wi‑Fi")?.tier == .exact)
        #expect(m("시스템설정", "시스템 설정")?.tier == .exact)
    }

    @Test func partialLastSyllableIsPrefix() {
        #expect(m("계사", "계산기")?.tier == .prefix)    // typing 산 shows 사 first
        #expect(m("캘리", "캘린더")?.tier == .prefix)
        #expect(m("디스플레이 바", "디스플레이 밝기")?.tier == .prefix)
        #expect(m("밝", "디스플레이 밝기")?.tier == .wordPrefix)
        #expect(m("바", "디스플레이 밝기")?.tier == .wordPrefix)
    }

    @Test func choseongVariants() {
        #expect(m("ㄱㅅㄱ", "계산기")?.tier == .initials)
        #expect(m("ㅋㅋㅇㅌ", "카카오톡")?.tier == .initials)
        #expect(m("ㅅㅈ", "시스템 설정")?.tier == .initials)        // word 초성
        #expect(m("ㅅㅅㅌㅅㅈ", "시스템 설정")?.tier == .initials)
        #expect(m("ㄱㄴ", "계산기") == nil)
        // A whole-term 초성 match beats a word-level one.
        #expect(m("ㄱㅅㄱ", "계산기")!.score > m("ㅅㅈ", "시스템 설정")!.score)
    }

    @Test func latinInitials() {
        #expect(m("vsc", "Visual Studio Code")?.tier == .initials)
        #expect(m("ss", "System Settings")?.tier == .initials)
    }

    @Test func fuzzyTyposAndSubsequence() {
        #expect(m("calcualtor", "Calculator")?.tier == .fuzzy)  // transposition
        #expect(m("safri", "Safari")?.tier == .fuzzy)           // deletion → subsequence
        #expect(m("게산기", "계산기")?.tier == .fuzzy)           // one jamo off
        #expect(m("카톡", "카카오톡")?.tier == .fuzzy)           // subsequence
        #expect(m("calculater", "calculator", fuzzy: false) == nil)
        #expect(m("xyz", "calculator") == nil)
    }

    @Test func singleCharacterDoesNotSubstringMatch() {
        #expect(m("a", "Safari") == nil)
        #expect(m("s", "Safari")?.tier == .prefix)
    }

    @Test func coverageBreaksTiesWithinTier() {
        #expect(m("메모", "메모장")!.score > m("메모", "메모리 사용량 보기")!.score)
    }

    @Test func editDistance() {
        func d(_ a: String, _ b: String, _ k: Int) -> Int? {
            EditDistance.osa(a.unicodeScalars.map(\.value)[...], b.unicodeScalars.map(\.value)[...], limit: k)
        }
        #expect(d("abc", "abc", 1) == 0)
        #expect(d("abc", "acb", 1) == 1)
        #expect(d("kitten", "sitting", 3) == 3)
        #expect(d("kitten", "sitting", 2) == nil)
        #expect(d("", "ab", 2) == 2)
    }

    /// The bit-parallel edit distance used for packed terms must equal the DP exactly, limit included.
    @Test func bitParallelEditDistanceEqualsDP() {
        let alphabet: [UInt8] = [0x61, 0x80, 0x9E]          // "a", "ㄱ", "ㅏ" in PackedJamo
        func strings(_ n: Int) -> [[UInt8]] {
            n == 0 ? [[]] : strings(n - 1).flatMap { s in alphabet.map { s + [$0] } }
        }
        func check(_ p: [UInt8], _ t: [UInt8], _ limit: Int) -> Bool {
            var match = [UInt64](repeating: 0, count: 256)
            for (i, b) in p.enumerated() { match[Int(b)] |= 1 << UInt64(i) }
            let expected = EditDistance.osa(p.map(PackedJamo.scalar)[...], t.map(PackedJamo.scalar)[...], limit: limit)
            let got = match.withUnsafeBufferPointer { m in
                t.withUnsafeBufferPointer { EditDistance.osa(packedMatch: m.baseAddress!, patternLength: p.count, $0, limit: limit) }
            }
            return got == expected
        }
        var mismatches = 0
        let texts = (0...5).flatMap(strings)
        for p in (1...4).flatMap(strings) {
            for t in texts {
                for limit in 0...3 where !check(p, t, limit) { mismatches += 1 }
            }
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let p = (0..<Int.random(in: 1...64, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            let t = (0..<Int.random(in: 0...70, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            if !check(p, t, Int.random(in: 0...3, using: &rng)) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

@Suite("Lexical index")
struct LexicalIndexTests {
    let index = LexicalIndex(items: fixtureItems)

    func top(_ q: String, _ n: Int = 3) -> [String] {
        index.search(QueryAnalyzer.analyze(q), limit: n).map(\.itemID)
    }

    @Test func exactKoreanAndEnglishNames() {
        #expect(top("계산기").first == "app:com.apple.calculator")
        #expect(top("calculator").first == "app:com.apple.calculator")
        #expect(top("Calc").first == "app:com.apple.calculator")
        #expect(top("메모").first == "app:com.apple.Notes")
        #expect(top("사파리").first == "app:com.apple.Safari")
    }

    @Test func choseongAndPartialSyllables() {
        #expect(top("ㄱㅅㄱ").first == "app:com.apple.calculator")
        #expect(top("ㅋㅋㅇㅌ").first == "app:com.kakao.KakaoTalkMac")
        #expect(top("계사").first == "app:com.apple.calculator")
        #expect(top("캘리").first == "app:com.apple.calendar")
    }

    @Test func multiWordAndKindWords() {
        #expect(top("메모 앱").first == "app:com.apple.Notes")
        #expect(top("화면 밝기").first == "setting:com.apple.Displays-Settings.extension#ambienceSection")
        #expect(top("turn off bluetooth").first == "setting:com.apple.BluetoothSettings#Main")
        #expect(top("vsc").first == "app:com.microsoft.VSCode")
    }

    @Test func sharedKeywordsAreDownweighted() throws {
        // "설정" is a keyword of four settings items but the title of the System Settings app.
        #expect(top("설정").first == "app:com.apple.systempreferences")
        let hits = index.search(QueryAnalyzer.analyze("설정"))
        let app = try #require(hits.first { $0.itemID == "app:com.apple.systempreferences" })
        let shared = try #require(hits.first { $0.itemID == "setting:com.apple.BluetoothSettings#Main" })
        #expect(app.score > shared.score)
    }

    @Test func particlesAreStripped() {
        #expect(top("휴지통을 비우기").first == "cmd:empty-trash")
    }

    @Test func emptyQuery() {
        #expect(index.search(QueryAnalyzer.analyze("   ")).isEmpty)
    }
}

@Suite("Vector index")
struct VectorIndexTests {
    func unit(_ xs: [Float]) -> [Float] {
        let n = sqrt(xs.reduce(0) { $0 + $1 * $1 })
        return xs.map { $0 / n }
    }

    @Test func topKMatchesFullSort() {
        var rng = SystemRandomNumberGenerator()
        var index = VectorIndex(dimensions: 16)
        var vectors: [String: [Float]] = [:]
        for i in 0..<300 {
            let v = unit((0..<16).map { _ in Float.random(in: -1...1, using: &rng) })
            vectors["i\(i)"] = v
            index.upsert(id: "i\(i)", vector: v)
        }
        let q = unit((0..<16).map { _ in Float.random(in: -1...1, using: &rng) })
        let expected = vectors.map { ($0.key, zip($0.value, q).reduce(0) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.1 > $1.1 }.prefix(10).map(\.0)
        let got = index.search(q, k: 10)
        #expect(got.map(\.id) == Array(expected))
        for (a, b) in zip(got.map(\.score), got.map(\.score).dropFirst()) { #expect(a >= b) }
    }

    @Test func upsertReplaceAndRemove() {
        var index = VectorIndex(dimensions: 2)
        index.upsert(id: "a", vector: [1, 0])
        index.upsert(id: "b", vector: [0, 1])
        index.upsert(id: "c", vector: unit([1, 1]))
        #expect(index.count == 3)
        #expect(index.search([1, 0], k: 1).first?.id == "a")

        index.upsert(id: "a", vector: [-1, 0])           // replace in place
        #expect(index.count == 3)
        #expect(index.search([1, 0], k: 1).first?.id == "c")

        let removed = index.remove(id: "a")              // swap-remove keeps other rows intact
        let removedAgain = index.remove(id: "a")
        #expect(removed && !removedAgain)
        #expect(index.count == 2)
        #expect(index.vector(for: "c") == unit([1, 1]))
        #expect(index.vector(for: "b") == [0, 1])
        #expect(index.search([0, 1], k: 5).map(\.id) == ["b", "c"])
    }

    @Test func topKEdgeCases() {
        #expect(VectorIndex.topK([], k: 3).isEmpty)
        #expect(VectorIndex.topK([0.1, 0.5], k: 0).isEmpty)
        #expect(VectorIndex.topK([0.1, 0.5, 0.3], k: 10) == [1, 2, 0])
        #expect(VectorIndex.topK([0.2, 0.2, 0.2], k: 2) == [0, 1])
    }
}
