import CryptoKit
import Foundation
import Testing
@testable import SearchCore

// The straightforward implementations the optimized lexical index, normalizer, hashing, query
// memory and top-k replaced, kept verbatim as executable specifications: the optimized code must
// produce bit-identical results on fixtures and on randomized adversarial text.

enum Reference {
    // MARK: TextNormalizer

    static func normalize(_ text: String) -> String {
        let lowered = text.precomposedStringWithCanonicalMapping.lowercased()
        var out = String.UnicodeScalarView()
        out.reserveCapacity(lowered.unicodeScalars.count)
        var pendingSpace = false
        for scalar in lowered.unicodeScalars {
            if let mapped = mapScalar(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(mapped)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    static func compact(_ text: String) -> String {
        normalize(text).replacingOccurrences(of: " ", with: "")
    }

    private static func mapScalar(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        let v = s.value
        if (0xFF01...0xFF5E).contains(v), let ascii = Unicode.Scalar(v - 0xFEE0) {
            return mapScalar(ascii)
        }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
            return s
        default:
            return nil
        }
    }

    // MARK: Hangul

    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { Hangul.isSyllable($0.value) || (0x3131...0x318E).contains($0.value) }
    }

    static func choseongString(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let v = s.value
            if Hangul.isSyllable(v) {
                out.append(Unicode.Scalar(Hangul.choseong[Int((v - Hangul.syllableBase) / 588)])!)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    static func keystrokeJamo(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        func append(_ v: UInt32) { out.append(Unicode.Scalar(v)!) }
        for s in text.unicodeScalars {
            let v = s.value
            if Hangul.isSyllable(v) {
                let index = Int(v - Hangul.syllableBase)
                append(Hangul.choseong[index / 588])
                Hangul.jungseongKeys[(index % 588) / 28].forEach(append)
                Hangul.jongseongKeys[index % 28].forEach(append)
            } else if let keys = Hangul.compoundCompatibility[v] {
                keys.forEach(append)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    // MARK: Lexical matching

    struct Term {
        let norm: [UInt8]
        let compact: [UInt8]
        let jamo: [UInt8]
        let jamoCompact: [UInt8]
        let jamoScalars: [UInt32]
        let wordJamos: [[UInt8]]
        let wordJamoScalars: [[UInt32]]
        let choseong: [UInt8]
        let wordChoseongs: [[UInt8]]
        let initials: [UInt8]
        let hasHangul: Bool
        let length: Int
        let choseongLength: Int

        init(_ text: String) {
            let norm = Reference.normalize(text)
            let compact = norm.replacingOccurrences(of: " ", with: "")
            let words = norm.split(separator: " ").map(String.init)
            let jamoNorm = Reference.keystrokeJamo(norm)
            let jamoCompact = Reference.keystrokeJamo(compact)
            self.norm = Array(norm.utf8)
            self.compact = Array(compact.utf8)
            self.jamo = Array(jamoNorm.utf8)
            self.jamoCompact = Array(jamoCompact.utf8)
            self.jamoScalars = jamoCompact.unicodeScalars.map(\.value)
            let wordJamoStrings = words.map(Reference.keystrokeJamo)
            self.wordJamos = wordJamoStrings.map { Array($0.utf8) }
            self.wordJamoScalars = wordJamoStrings.map { $0.unicodeScalars.map(\.value) }
            self.hasHangul = Reference.containsHangul(compact)
            if hasHangul {
                let cho = Reference.choseongString(compact)
                self.choseong = Array(cho.utf8)
                self.choseongLength = cho.unicodeScalars.count
                self.wordChoseongs = words.map { Array(Reference.choseongString($0).utf8) }
            } else {
                self.choseong = []
                self.choseongLength = 0
                self.wordChoseongs = []
            }
            let latinWords = words.filter { $0.unicodeScalars.first.map { $0.isASCII && $0.properties.isAlphabetic } ?? false }
            self.initials = latinWords.count >= 2 && latinWords.count == words.count
                ? Array(String(latinWords.compactMap(\.first)).utf8) : []
            self.length = compact.unicodeScalars.count
        }
    }

    struct Query {
        let norm: [UInt8]
        let compact: [UInt8]
        let jamo: [UInt8]
        let jamoCompact: [UInt8]
        let jamoScalars: [UInt32]
        let isChoseong: Bool
        let length: Int
        let isEmpty: Bool

        init(_ text: String) {
            let norm = Reference.normalize(text)
            let compact = norm.replacingOccurrences(of: " ", with: "")
            let jamoCompact = Reference.keystrokeJamo(compact)
            self.norm = Array(norm.utf8)
            self.compact = Array(compact.utf8)
            self.jamo = Array(Reference.keystrokeJamo(norm).utf8)
            self.jamoCompact = Array(jamoCompact.utf8)
            self.jamoScalars = jamoCompact.unicodeScalars.map(\.value)
            self.isChoseong = Hangul.isChoseongQuery(compact)
            self.length = compact.unicodeScalars.count
            self.isEmpty = compact.isEmpty
        }
    }

    static func match(_ q: Query, _ t: Term, allowFuzzy: Bool) -> LexicalMatcher.Match? {
        guard !q.isEmpty, t.length > 0 else { return nil }
        if q.norm == t.norm || q.compact == t.compact { return .init(score: 1.0, tier: .exact) }
        let coverage = min(1, Float(q.length) / Float(t.length))
        if hasPrefix(t.jamoCompact, q.jamoCompact) || hasPrefix(t.jamo, q.jamo) {
            return .init(score: 0.82 + 0.08 * coverage, tier: .prefix)
        }
        if let wordMatch = wordPrefix(q, t) {
            return .init(score: 0.68 + 0.08 * (wordMatch ? 1 : coverage), tier: .wordPrefix)
        }
        if q.length >= 2, contains(t.jamoCompact, q.jamoCompact) {
            return .init(score: 0.54 + 0.08 * coverage, tier: .substring)
        }
        if q.isChoseong {
            if t.hasHangul, let sub = choseongSubtier(q.compact, t) {
                let cov = min(1, Float(q.length) / Float(max(1, t.choseongLength)))
                return .init(score: 0.38 + 0.03 * Float(sub) + 0.06 * cov, tier: .initials)
            }
        } else if q.length >= 2, !t.initials.isEmpty, hasPrefix(t.initials, q.compact) {
            let cov = Float(q.length) / Float(t.initials.count)
            return .init(score: 0.41 + 0.06 * cov + (cov >= 1 ? 0.06 : 0), tier: .initials)
        }
        guard allowFuzzy, q.length >= 2, !q.isChoseong else { return nil }
        return fuzzy(q, t)
    }

    private static func wordPrefix(_ q: Query, _ t: Term) -> Bool? {
        guard t.wordJamos.count > 1 else { return nil }
        if !q.jamo.contains(0x20) {
            var found: Bool? = nil
            for w in t.wordJamos.dropFirst() where hasPrefix(w, q.jamoCompact) {
                if w.count == q.jamoCompact.count { return true }
                found = false
            }
            return found
        }
        return contains(t.jamo, [0x20] + q.jamo) ? false : nil
    }

    private static func choseongSubtier(_ q: [UInt8], _ t: Term) -> Int? {
        if t.choseong == q { return 3 }
        if hasPrefix(t.choseong, q) { return 2 }
        if t.wordChoseongs.dropFirst().contains(where: { hasPrefix($0, q) }) { return 1 }
        if contains(t.choseong, q) { return 0 }
        return nil
    }

    private static func fuzzy(_ q: Query, _ t: Term) -> LexicalMatcher.Match? {
        var best: Float = 0
        let qs = q.jamoScalars
        if qs.count >= 4 {
            let maxEdits = qs.count >= 8 ? 2 : 1
            func consider(_ c: ArraySlice<UInt32>) {
                guard abs(c.count - qs.count) <= maxEdits, plausible(qs[...], c),
                      let d = osa(qs[...], c, limit: maxEdits) else { return }
                best = max(best, 0.33 - 0.04 * Float(d))
            }
            if t.wordJamoScalars.count > 1 { for w in t.wordJamoScalars { consider(w[...]) } }
            if t.jamoScalars.count > qs.count {
                consider(t.jamoScalars.prefix(qs.count))
                consider(t.jamoScalars.prefix(qs.count + 1))
            } else {
                consider(t.jamoScalars[...])
            }
        }
        if let span = subsequenceSpan(qs, t.jamoScalars) {
            let tightness = Float(qs.count) / Float(span.length)
            best = max(best, 0.18 + 0.10 * tightness + (span.start == 0 ? 0.02 : 0))
        }
        return best > 0 ? .init(score: best, tier: .fuzzy) : nil
    }

    private static func subsequenceSpan(_ q: [UInt32], _ t: [UInt32]) -> (start: Int, length: Int)? {
        guard !q.isEmpty, q.count <= t.count else { return nil }
        var qi = 0
        var start = -1
        for (ti, c) in t.enumerated() where c == q[qi] {
            if start < 0 { start = ti }
            qi += 1
            if qi == q.count { return (start, ti - start + 1) }
        }
        return nil
    }

    private static func hasPrefix(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.starts(with: b) }

    private static func contains(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard b.count <= a.count else { return false }
        if b.isEmpty { return true }
        return (0...(a.count - b.count)).contains { a[$0..<($0 + b.count)].elementsEqual(b) }
    }

    static func osa(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        let n = a.count, m = b.count
        if abs(n - m) > limit { return nil }
        if n == 0 { return m <= limit ? m : nil }
        if m == 0 { return n <= limit ? n : nil }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n][m] <= limit ? d[n][m] : nil
    }

    private static func plausible(_ q: ArraySlice<UInt32>, _ c: ArraySlice<UInt32>) -> Bool {
        guard let q0 = q.first, let c0 = c.first else { return false }
        if q0 == c0 { return true }
        let qi = q.startIndex, ci = c.startIndex
        return q.count > 1 && c.count > 1 && q[qi + 1] == c0 && c[ci + 1] == q0
    }

    // MARK: Lexical index

    struct Index {
        let items: [SearchItem]
        var terms: [Term] = []
        var titleTerm: [Int] = []
        var keywordTerms: [[Int]] = []
        var weight: [Float] = []
        var fuzzyEligible: [Bool] = []

        init(_ items: [SearchItem]) {
            self.items = items
            var termIndex: [String: Int] = [:]
            var terms: [Term] = []
            var df: [Int] = []
            var isTitle: [Bool] = []
            func intern(_ text: String) -> Int? {
                let key = Reference.normalize(text)
                guard !key.isEmpty else { return nil }
                if let id = termIndex[key] { return id }
                termIndex[key] = terms.count
                terms.append(Term(key))
                df.append(0)
                isTitle.append(false)
                return terms.count - 1
            }
            for item in items {
                let t = intern(item.title) ?? intern(item.id)!
                isTitle[t] = true
                var seen: Set<Int> = [t]
                var kws: [Int] = []
                for k in item.keywords {
                    guard let id = intern(k), seen.insert(id).inserted else { continue }
                    kws.append(id)
                }
                for id in seen { df[id] += 1 }
                titleTerm.append(t)
                keywordTerms.append(kws)
            }
            self.terms = terms
            weight = df.map { 0.9 / (1 + 0.5 * logf(Float(max(1, $0)))) }
            fuzzyEligible = zip(isTitle, df).map { $0 || $1 <= 2 }
        }

        func search(_ analysis: QueryAnalysis, limit: Int) -> [LexicalHit] {
            Reference.search(self, analysis, limit: limit)
        }
    }

    private static func search(_ index: Index, _ analysis: QueryAnalysis, limit: Int) -> [LexicalHit] {
        let items = index.items, terms = index.terms, titleTerm = index.titleTerm
        let keywordTerms = index.keywordTerms, weight = index.weight, fuzzyEligible = index.fuzzyEligible
        guard !analysis.normalized.isEmpty, !items.isEmpty else { return [] }
        func scores(_ q: Query) -> [(Float, UInt8)] {
            terms.indices.map { i in
                Reference.match(q, terms[i], allowFuzzy: fuzzyEligible[i]).map { ($0.score, UInt8($0.tier.rawValue)) } ?? (0, 0)
            }
        }
        func itemScore(_ i: Int, _ ts: [(Float, UInt8)]) -> (Float, UInt8) {
            var (s, tier) = ts[titleTerm[i]]
            for k in keywordTerms[i] {
                let v = ts[k].0 * weight[k]
                if v > s { s = v; tier = ts[k].1 }
            }
            return (s, tier)
        }
        let whole = scores(Query(analysis.normalized))
        var best = items.indices.map { itemScore($0, whole) }
        let tokens = analysis.contentTokens
        if tokens.count >= 2 || analysis.hasReducedForm {
            let tokenScores = tokens.map { $0.map { scores(Query($0)) } }
            for i in items.indices {
                var sum: Float = 0
                var matched = 0
                var worstTier: UInt8 = .max
                for variants in tokenScores {
                    var tokenBest: Float = 0
                    var tokenTier: UInt8 = 0
                    for ts in variants {
                        let (s, tier) = itemScore(i, ts)
                        if s > tokenBest { tokenBest = s; tokenTier = tier }
                    }
                    if tokenBest > 0 { matched += 1; worstTier = min(worstTier, tokenTier) }
                    sum += tokenBest
                }
                guard matched > 0 else { continue }
                let mean = sum / Float(tokens.count)
                let factor: Float = matched == tokens.count ? 0.92 : 0.75 * Float(matched) / Float(tokens.count)
                let s = mean * factor
                if s > best[i].0 { best[i] = (s, worstTier) }
            }
        }
        func kindOrder(_ k: ItemKind) -> Int {
            switch k {
            case .application: 0
            case .command: 1
            case .systemSetting: 2
            case .shortcut: 3
            case .file: 4
            }
        }
        let hits = items.indices.filter { best[$0].0 > 0 }.sorted { a, b in
            if best[a].0 != best[b].0 { return best[a].0 > best[b].0 }
            let ka = kindOrder(items[a].kind), kb = kindOrder(items[b].kind)
            if ka != kb { return ka < kb }
            if items[a].title.count != items[b].title.count { return items[a].title.count < items[b].title.count }
            return items[a].id < items[b].id
        }
        return hits.prefix(limit).map {
            LexicalHit(itemID: items[$0].id, score: Double(best[$0].0), tier: MatchTier(rawValue: Int(best[$0].1)) ?? .fuzzy)
        }
    }

    // MARK: Store, ranking, vectors

    static func contentHash(_ item: SearchItem) -> String {
        SHA256.hash(data: Data(item.embeddingContent.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func topK(_ values: [Float], k: Int) -> [Int] {
        Array(values.indices.sorted { values[$0] > values[$1] || (values[$0] == values[$1] && $0 < $1) }.prefix(max(0, k)))
    }
}

/// Deterministic generator of adversarial launcher text.
struct TextFuzzer {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }

    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }

    static let pieces: [String] = [
        "a", "b", "c", "s", "x", "e", "ab", "calc", "wi", "fi", "Wi‑Fi", "VS", "Code", "Studio", "NEW", "42", "7",
        "계", "산", "기", "계산기", "설정", "시스템", "값", "갑", "와", "됐", "닭", "앉", "의", "ㄱ", "ㅅ", "ㄳ", "ㅘ", "ㅏ", "ㆍ",
        "디스플레이", "밝기", "키보드", "카카오톡", "메모", "é", "e\u{301}", "\u{FE0E}", "🌐", "中", "浏览器", "Ａｂ", "ß", "İ",
        " ", " ", " ", "  ", "-", "·", "_", "/", "(", ")", "\u{00A0}", "\u{3000}", "!", "'", "\u{1100}\u{1161}", "\u{11A8}",
    ]

    mutating func text(maxPieces: Int = 5) -> String {
        (0..<(1 + Int(next() % UInt64(maxPieces)))).map { _ in pick(Self.pieces) }.joined()
    }
}

@Suite("Reference equivalence")
struct ReferenceEquivalenceTests {
    static let samples: [String] = {
        var fuzzer = TextFuzzer(seed: 7)
        let fixed = fixtureItems.flatMap { [$0.title] + $0.keywords + [$0.subtitle ?? ""] }
            + ["", " ", "ㄱㅅㄱ", "ㅅㅈ", "vsc", "safri", "calcualtor", "게산기", "카톡", "press \u{FE0E} key", "a \u{301}b", "ㄱ ㅅ"]
        return fixed + (0..<400).map { _ in fuzzer.text() }
    }()

    @Test func normalizationAndHangulMatchReference() {
        for s in Self.samples {
            #expect(TextNormalizer.normalize(s) == Reference.normalize(s), "\(s.debugDescription)")
            #expect(TextNormalizer.compact(s) == Reference.compact(s), "\(s.debugDescription)")
            #expect(Hangul.keystrokeJamo(s) == Reference.keystrokeJamo(s), "\(s.debugDescription)")
            #expect(Hangul.choseongString(s) == Reference.choseongString(s), "\(s.debugDescription)")
            #expect(Hangul.containsHangul(s) == Reference.containsHangul(s), "\(s.debugDescription)")
        }
    }

    @Test func matcherMatchesReference() {
        var fuzzer = TextFuzzer(seed: 11)
        let queries = Self.samples.prefix(150) + (0..<120).map { _ in fuzzer.text(maxPieces: 3) }
        let terms = Self.samples
        var mismatches: [String] = []
        for t in terms {
            let term = LexTerm(t), ref = Reference.Term(t)
            for q in queries {
                let query = LexQuery(q), refQuery = Reference.Query(q)
                for allowFuzzy in [true, false] {
                    let got = LexicalMatcher.match(query, term, allowFuzzy: allowFuzzy)
                    let want = Reference.match(refQuery, ref, allowFuzzy: allowFuzzy)
                    if got?.score.bitPattern != want?.score.bitPattern || got?.tier != want?.tier {
                        mismatches.append("\(q.debugDescription) vs \(t.debugDescription): \(String(describing: got)) ≠ \(String(describing: want))")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, e.g. \(mismatches.prefix(5))")
    }

    /// Queries longer than 64 jamo exceed the bit-parallel edit distance and take the DP; against
    /// packed terms they must still decode the packed bytes, not read them as UTF-8.
    @Test func longQueriesMatchReference() {
        let base = String(repeating: "계산기", count: 10)                    // 70 jamo
        let queries = [base, String(repeating: "계산기", count: 9) + "게산기", String(repeating: "계산기", count: 9) + "계산",
                       String(repeating: "calculator", count: 7), String(repeating: "calculator", count: 6) + "calcualtor"]
        let terms = [base, String(repeating: "계산기", count: 9) + "게산기", String(repeating: "계산기 ", count: 10),
                     String(repeating: "calculator", count: 7), String(repeating: "calculator ", count: 7) + "x", "계산기", "ㄱ" + base]
        for q in queries {
            for t in terms {
                for allowFuzzy in [true, false] {
                    let got = LexicalMatcher.match(LexQuery(q), LexTerm(t), allowFuzzy: allowFuzzy)
                    let want = Reference.match(Reference.Query(q), Reference.Term(t), allowFuzzy: allowFuzzy)
                    #expect(got?.score.bitPattern == want?.score.bitPattern && got?.tier == want?.tier,
                            "\(q) vs \(t): \(String(describing: got)) ≠ \(String(describing: want))")
                }
            }
        }
    }

    @Test func indexRankingMatchesReference() {
        var fuzzer = TextFuzzer(seed: 3)
        var items = fixtureItems
        for i in 0..<250 {
            items.append(makeItem("fuzz:\(i)", ItemKind.allCases[i % 4], title: fuzzer.text(),
                                  keywords: (0..<Int(fuzzer.next() % 5)).map { _ in fuzzer.text() }))
        }
        let index = LexicalIndex(items: items), reference = Reference.Index(items)
        let queries = Self.samples.prefix(150) + (0..<150).map { _ in fuzzer.text(maxPieces: 3) }
            + ["설정 키보드", "디스플레이 밝기를", "wifi 설정", "시스템 환경 설정", "앱에서 메모"]
        for q in queries {
            let analysis = QueryAnalyzer.analyze(q)
            for limit in [5, 50, .max] {
                #expect(index.search(analysis, limit: limit) == reference.search(analysis, limit: limit), "\(q.debugDescription)")
            }
        }
    }

    @Test func contentHashMatchesReference() {
        var fuzzer = TextFuzzer(seed: 5)
        for i in 0..<200 {
            let item = makeItem("h\(i)", title: fuzzer.text(), text: fuzzer.text(maxPieces: 12))
            #expect(IndexStore.contentHash(item) == Reference.contentHash(item))
        }
    }

    @Test func queryMemoryIndexMatchesLinearScan() {
        var fuzzer = TextFuzzer(seed: 9)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = (0..<400).map { i in
            QueryMemoryRecord(query: TextNormalizer.normalize(fuzzer.text(maxPieces: 3)), itemID: "i\(i % 37)", count: 1,
                              weight: 1 + Double(i % 7), lastUsed: now.addingTimeInterval(-Double(i) * 1_000))
        }
        let index = QueryMemoryIndex(records)
        let config = RankingConfig()
        for q in Self.samples.prefix(300) {
            let n = TextNormalizer.normalize(q)
            #expect(index.boosts(query: n, now: now, config: config) == Frecency.memoryBoosts(records, query: n, now: now, config: config))
        }
    }

    @Test func topKMatchesReference() {
        var fuzzer = TextFuzzer(seed: 13)
        for n in [0, 1, 2, 7, 50, 300] {
            // Few distinct values, so ties are common.
            let values = (0..<n).map { _ in Float(fuzzer.next() % 9) / 8 }
            for k in [0, 1, 3, 50, 400] {
                #expect(VectorIndex.topK(values, k: k) == Reference.topK(values, k: k))
            }
        }
    }
}
