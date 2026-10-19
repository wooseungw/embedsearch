import Foundation

public struct LexicalHit: Sendable, Hashable {
    public let itemID: String
    public let score: Double
    public let tier: MatchTier
}

/// In-memory lexical index over item titles and keywords.
///
/// Identical strings across items share one term (settings index words repeat a lot), so a query
/// is matched once per unique term and items take the max over their terms. Keywords are weighted
/// 0.9 × idf (a keyword shared by many items, like "설정" or "off", says little); titles weigh 1.0.
///
/// Layout: terms live in one `TermStore` arena; a CSR posting list maps each term to its
/// (item, position) pairs (position 0 = title, k = k-th keyword), so a query only touches the items
/// of the terms it matched. A 128-bit character fingerprint per term rejects most terms before any
/// byte comparison.
public struct LexicalIndex: Sendable {
    private let itemIDs: [String]
    private let itemKindOrder: [UInt8]
    private let titleLengths: [Int32]
    private let terms: TermStore
    private let termWeight: [Float]
    private let fuzzyEligible: [Bool]
    /// Postings of term t: `postingStart[t] ..< postingStart[t + 1]`.
    private let postingStart: [UInt32]
    private let postingItem: [UInt32]
    private let postingPosition: [UInt32]

    public var count: Int { itemIDs.count }

    public init(items: [SearchItem]) {
        var termIndex: [String: Int32] = [:]
        termIndex.reserveCapacity(items.count * 4)
        var keys: [String] = []
        var df: [Int32] = []
        var isTitle: [Bool] = []
        func intern(_ text: String) -> Int32? {
            let key = TextNormalizer.normalize(text)
            guard !key.isEmpty else { return nil }
            if let id = termIndex[key] { return id }
            let id = Int32(keys.count)
            termIndex[key] = id
            keys.append(key)
            df.append(0)
            isTitle.append(false)
            return id
        }

        // Per item: title term first, then distinct keyword terms in keyword order (= position).
        var itemTermStart: [Int32] = [0]
        var itemTerms: [Int32] = []
        itemTermStart.reserveCapacity(items.count + 1)
        itemTerms.reserveCapacity(items.count * 8)
        var seen = Set<Int32>()
        for item in items {
            let t = intern(item.title) ?? intern(item.id)!
            isTitle[Int(t)] = true
            seen.removeAll(keepingCapacity: true)
            seen.insert(t)
            itemTerms.append(t)
            for k in item.keywords {
                guard let id = intern(k), seen.insert(id).inserted else { continue }
                itemTerms.append(id)
            }
            for id in itemTerms[Int(itemTermStart.last!)...] { df[Int(id)] += 1 }
            itemTermStart.append(Int32(itemTerms.count))
        }
        termIndex = [:]

        var store = TermStore()
        for key in keys { store.append(key) }
        store.shrinkToFit()

        // Invert item → terms into term → (item, position), items ascending within a term.
        var start = [UInt32](repeating: 0, count: keys.count + 1)
        for t in itemTerms { start[Int(t) + 1] += 1 }
        for t in 0..<keys.count { start[t + 1] += start[t] }
        var fill = start
        var postingItem = [UInt32](repeating: 0, count: itemTerms.count)
        var postingPosition = [UInt32](repeating: 0, count: itemTerms.count)
        for i in items.indices {
            let lo = Int(itemTermStart[i]), hi = Int(itemTermStart[i + 1])
            for j in lo..<hi {
                let t = Int(itemTerms[j])
                let slot = Int(fill[t])
                fill[t] += 1
                postingItem[slot] = UInt32(i)
                postingPosition[slot] = UInt32(j - lo)
            }
        }

        self.itemIDs = items.map(\.id)
        self.itemKindOrder = items.map { Self.kindOrder($0.kind) }
        self.titleLengths = items.map { Int32(clamping: $0.title.count) }
        self.terms = store
        self.termWeight = df.map { 0.9 / (1 + 0.5 * logf(Float(max(1, $0)))) }
        self.fuzzyEligible = zip(isTitle, df).map { title, d in title || d <= 2 }
        self.postingStart = start
        self.postingItem = postingItem
        self.postingPosition = postingPosition
    }

    /// Ranked lexical hits (score desc). Empty for an empty query.
    public func search(_ analysis: QueryAnalysis, limit: Int = .max) -> [LexicalHit] {
        guard !analysis.normalized.isEmpty, !itemIDs.isEmpty, limit > 0 else { return [] }
        let n = itemIDs.count

        // Whole query: per-item best term score.
        var best = ItemScores(count: n)
        scorePass(LexQuery(analysis.normalized), into: &best)

        // Token-wise scoring for multi-word queries or when kind words/particles were stripped.
        let tokens = analysis.contentTokens
        if tokens.count >= 2 || analysis.hasReducedForm {
            var sum = [Float](repeating: 0, count: n)
            var matched = [Int32](repeating: 0, count: n)
            var worstTier = [UInt8](repeating: .max, count: n)
            var touched: [Int32] = []
            var tokenBest = ItemScores(count: n)
            var variant = ItemScores(count: n)
            for variants in tokens {
                // Best variant per item; on equal scores the earlier variant wins.
                for text in variants {
                    scorePass(LexQuery(text), into: &variant)
                    for i in variant.touched {
                        let s = variant.score[Int(i)]
                        if s > tokenBest.score[Int(i)] { tokenBest.set(Int(i), s, variant.tier[Int(i)], 0) }
                    }
                    variant.reset()
                }
                // Adding the tokens that scored 0 would not change the float sum, so only matched
                // tokens are accumulated, still in token order.
                for i in tokenBest.touched {
                    let i = Int(i)
                    if matched[i] == 0 { touched.append(Int32(i)) }
                    matched[i] += 1
                    worstTier[i] = min(worstTier[i], tokenBest.tier[i])
                    sum[i] += tokenBest.score[i]
                }
                tokenBest.reset()
            }
            let tokenCount = Float(tokens.count)
            for i in touched {
                let i = Int(i)
                let mean = sum[i] / tokenCount
                let factor: Float = Int(matched[i]) == tokens.count ? 0.92 : 0.75 * Float(matched[i]) / tokenCount
                let s = mean * factor
                if s > best.score[i] { best.set(i, s, worstTier[i], 0) }
            }
        }

        // Top `limit` by (score desc, kind, shorter title, id) — a total order, so selecting with a
        // bounded heap and sorting the survivors equals sorting everything.
        let hits = best.touched, scores = best.score, tiers = best.tier
        let k = min(limit, hits.count)
        let ordered: [Int32]
        if k == hits.count {
            ordered = hits.sorted { before(Int($0), Int($1), scores) }
        } else {
            var heap = TopK<Int32>(capacity: k) { a, b in before(Int(a), Int(b), scores) }
            for i in hits { heap.offer(i) }
            ordered = heap.sortedDescending()
        }
        return ordered.map {
            LexicalHit(itemID: itemIDs[Int($0)], score: Double(scores[Int($0)]),
                       tier: MatchTier(rawValue: Int(tiers[Int($0)])) ?? .fuzzy)
        }
    }

    @inline(__always)
    private func before(_ a: Int, _ b: Int, _ score: [Float]) -> Bool {
        if score[a] != score[b] { return score[a] > score[b] }
        if itemKindOrder[a] != itemKindOrder[b] { return itemKindOrder[a] < itemKindOrder[b] }
        if titleLengths[a] != titleLengths[b] { return titleLengths[a] < titleLengths[b] }
        return itemIDs[a] < itemIDs[b]
    }

    /// Matches `query` against every term and scatters each match to the term's items: an item's
    /// score is its best term (title as is, keywords × weight), ties going to the earlier position.
    private func scorePass(_ query: LexQuery, into out: inout ItemScores) {
        guard !query.isEmpty else { return }
        query.withView { q in
            terms.withArena { arena in
                let budget = q.fuzzyMissingBudget
                let masks = arena.masks
                withUnsafeTemporaryAllocation(of: Int32.self, capacity: masks.count + 1) { candidates in
                    // Phase 1, branch-free: terms whose fingerprint leaves at most `budget` query
                    // scalars missing.
                    var n = 0
                    for t in 0..<masks.count {
                        candidates[n] = Int32(truncatingIfNeeded: t)
                        n &+= q.mask.missing(from: masks[t]) <= budget ? 1 : 0
                    }
                    // Phase 2: match them; a term that lacks a query scalar can only match by typos.
                    for c in 0..<n {
                        let t = Int(candidates[c])
                        let match: LexicalMatcher.Match?
                        if q.mask.missing(from: masks[t]) == 0 {
                            match = LexicalMatcher.match(q, arena.view(t), allowFuzzy: fuzzyEligible[t])
                        } else if fuzzyEligible[t] {
                            match = LexicalMatcher.matchTypos(q, arena.view(t))
                        } else {
                            continue
                        }
                        guard let m = match else { continue }
                        let tier = UInt8(m.tier.rawValue)
                        let keywordScore = m.score * termWeight[t]
                        for p in Int(postingStart[t])..<Int(postingStart[t + 1]) {
                            let position = postingPosition[p]
                            out.offer(Int(postingItem[p]), position == 0 ? m.score : keywordScore, tier, position)
                        }
                    }
                }
            }
        }
    }

    private static func kindOrder(_ kind: ItemKind) -> UInt8 {
        switch kind {
        case .application: 0
        case .command: 1
        case .systemSetting: 2
        case .shortcut: 3
        case .file: 4
        }
    }
}

/// Dense per-item scores with a list of touched items (score 0 = untouched; matches are > 0), so a
/// pass costs O(items it touched) and resetting does too.
private struct ItemScores {
    var score: [Float]
    var tier: [UInt8]
    var position: [UInt32]
    var touched: [Int32] = []

    init(count: Int) {
        score = [Float](repeating: 0, count: count)
        tier = [UInt8](repeating: 0, count: count)
        position = [UInt32](repeating: 0, count: count)
    }

    @inline(__always)
    mutating func offer(_ i: Int, _ s: Float, _ t: UInt8, _ p: UInt32) {
        let current = score[i]
        if current == 0 {
            touched.append(Int32(i))
        } else if !(s > current || (s == current && p < position[i])) {
            return
        }
        score[i] = s
        tier[i] = t
        position[i] = p
    }

    @inline(__always)
    mutating func set(_ i: Int, _ s: Float, _ t: UInt8, _ p: UInt32) {
        if score[i] == 0 { touched.append(Int32(i)) }
        score[i] = s
        tier[i] = t
        position[i] = p
    }

    mutating func reset() {
        for i in touched { score[Int(i)] = 0 }
        touched.removeAll(keepingCapacity: true)
    }
}

/// Bounded binary heap keeping the `capacity` best elements under a strict total order `before`
/// (root = worst kept element).
struct TopK<Element> {
    private var heap: [Element] = []
    private let capacity: Int
    private let before: (Element, Element) -> Bool

    init(capacity: Int, before: @escaping (Element, Element) -> Bool) {
        self.capacity = capacity
        self.before = before
        heap.reserveCapacity(capacity)
    }

    @inline(__always)
    mutating func offer(_ e: Element) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(e)
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard before(heap[p], heap[i]) else { return }
                heap.swapAt(i, p)
                i = p
            }
        } else if before(e, heap[0]) {
            heap[0] = e
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < heap.count, before(heap[m], heap[l]) { m = l }
                if r < heap.count, before(heap[m], heap[r]) { m = r }
                if m == i { return }
                heap.swapAt(i, m)
                i = m
            }
        }
    }

    /// Best first.
    func sortedDescending() -> [Element] { heap.sorted(by: before) }
}

