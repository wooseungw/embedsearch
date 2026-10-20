import Foundation

/// Which signals a search may use. `hybrid` is what the App gets from `fullSearch`.
public enum SearchMode: String, Sendable, CaseIterable, Codable {
    case lexical, semantic, hybrid
}

/// Pure fusion of the per-signal rank lists into final results (no I/O, unit-testable).
public enum HybridRanker {
    public struct SemanticHit: Sendable, Hashable {
        public let itemID: String
        public let cosine: Double
        /// File hits: the hubness-corrected score the file list is ranked by (see `ChunkIndex`).
        public let score: Double?
        /// File hits: the page the best chunk starts on (see `ScoreBreakdown.page`).
        public let page: Int?
        public init(itemID: String, cosine: Double, score: Double? = nil, page: Int? = nil) {
            self.itemID = itemID
            self.cosine = cosine
            self.score = score
            self.page = page
        }
    }

    /// A file whose text has the query's words (see `IndexStore.keywordMatches`).
    public struct KeywordHit: Sendable, Hashable {
        public let itemID: String
        /// IDF-weighted share of the query's tokens in the file's best chunk, 0…1.
        public let coverage: Double
        /// The page that chunk starts on.
        public let page: Int?
        public init(itemID: String, coverage: Double, page: Int? = nil) {
            self.itemID = itemID
            self.coverage = coverage
            self.page = page
        }
    }

    public struct Input: Sendable {
        public var analysis: QueryAnalysis
        /// Ranked lexical hits (best first).
        public var lexical: [LexicalHit]
        /// Ranked semantic hits (best first); nil when semantic search did not run.
        public var semantic: [SemanticHit]?
        /// Ranked file-content matches (best first), already past `minFileScore`; `hybrid` only.
        public var fileSemantic: [SemanticHit]
        /// Ranked file keyword matches (best first), already past `minFileKeywordCoverage`; `hybrid` only.
        public var fileKeyword: [KeywordHit]
        public var kinds: [String: ItemKind]
        public var frecency: [String: Double]
        public var memory: [String: Double]

        public init(analysis: QueryAnalysis, lexical: [LexicalHit], semantic: [SemanticHit]?,
                    fileSemantic: [SemanticHit] = [], fileKeyword: [KeywordHit] = [], kinds: [String: ItemKind],
                    frecency: [String: Double] = [:], memory: [String: Double] = [:]) {
            self.analysis = analysis
            self.lexical = lexical
            self.semantic = semantic
            self.fileSemantic = fileSemantic
            self.fileKeyword = fileKeyword
            self.kinds = kinds
            self.frecency = frecency
            self.memory = memory
        }
    }

    public struct Ranked: Sendable, Hashable {
        public let itemID: String
        public let score: Double
        public let signals: Set<MatchSignal>
        public let breakdown: ScoreBreakdown
    }

    public static func rrf(rank: Int, k: Double) -> Double { 1 / (k + Double(rank)) }

    public static func rank(_ input: Input, mode: SearchMode, config: RankingConfig, limit: Int) -> [Ranked] {
        rank(analysis: input.analysis, lexical: input.lexical, semantic: input.semantic, fileSemantic: input.fileSemantic,
             fileKeyword: input.fileKeyword, kind: { input.kinds[$0] }, frecency: input.frecency, memory: input.memory, mode: mode, config: config,
             limit: limit)
    }

    /// `rank` with item kinds looked up on demand (the engine keeps no id → kind dictionary).
    static func rank(analysis: QueryAnalysis, lexical: [LexicalHit], semantic inputSemantic: [SemanticHit]?,
                     fileSemantic: [SemanticHit] = [], fileKeyword: [KeywordHit] = [], kind: (String) -> ItemKind?,
                     frecency: [String: Double],
                     memory: [String: Double], mode: SearchMode, config: RankingConfig, limit: Int) -> [Ranked] {
        struct Acc {
            let id: String
            var lexRank: Int?
            var lexScore: Double?
            var semRank: Int?
            var fileRank: Int?
            var fileMargin: Double = 0
            var keywordRank: Int?
            var keywordCoverage: Double?
            var filePage: Int?
            var keywordPage: Int?
            var cosine: Double?
            var frecency: Double = 0
            var memory: Double = 0
        }
        // Candidates live in an array; the dictionary only maps an id to its slot.
        var accs: [Acc] = []
        var slots: [String: Int] = [:]
        let capacity = lexical.count + (inputSemantic?.count ?? 0) + fileSemantic.count + fileKeyword.count + memory.count
        accs.reserveCapacity(capacity)
        slots.reserveCapacity(capacity)
        func slot(_ id: String) -> Int {
            if let s = slots[id] { return s }
            slots[id] = accs.count
            accs.append(Acc(id: id))
            return accs.count - 1
        }

        if mode != .semantic {
            // A file name matched only loosely (initials, fuzzy: below `minFileNameScore`) is noise,
            // not a match: it is left out, as if it had not matched, rather than scored.
            var r = 0
            for hit in lexical.prefix(max(0, config.lexicalCandidates))
            where kind(hit.itemID) != .file || hit.score >= config.minFileNameScore {
                r += 1
                let s = slot(hit.itemID)
                accs[s].lexRank = r
                accs[s].lexScore = hit.score
            }
        }
        let semantic = mode == .lexical ? [] : (inputSemantic ?? [])
        for (i, hit) in semantic.enumerated() {
            let inCandidates = i < config.semanticCandidates
            if let s = slots[hit.itemID] {
                accs[s].cosine = hit.cosine
                if inCandidates { accs[s].semRank = i + 1 }
            } else if inCandidates, mode == .semantic || hit.cosine >= config.minSemanticCosine {
                let s = slot(hit.itemID)
                accs[s].semRank = i + 1
                accs[s].cosine = hit.cosine
            }
        }
        if mode == .hybrid {
            for (i, hit) in fileSemantic.prefix(max(0, config.fileCandidates)).enumerated() {
                let s = slot(hit.itemID)
                accs[s].fileRank = i + 1
                accs[s].fileMargin = max(0, (hit.score ?? config.minFileScore) - config.minFileScore)
                accs[s].filePage = hit.page
                if accs[s].cosine == nil { accs[s].cosine = hit.cosine }
            }
            for (i, hit) in fileKeyword.prefix(max(0, config.fileKeywordCandidates)).enumerated() {
                let s = slot(hit.itemID)
                accs[s].keywordRank = i + 1
                accs[s].keywordCoverage = hit.coverage
                accs[s].keywordPage = hit.page
            }
        }
        if mode != .semantic, config.useUsageSignals {
            for (id, m) in memory where m > 0 && kind(id) != nil {
                accs[slot(id)].memory = m
            }
            for s in accs.indices { accs[s].frecency = frecency[accs[s].id] ?? 0 }
        }

        // Score every candidate with a kind, then keep the best `limit` under the same total order
        // as a full sort (score desc, lexical rank, id).
        var scores = [Double](repeating: 0, count: accs.count)
        var signalBits = [UInt8](repeating: 0, count: accs.count)
        var scored: [Int] = []
        scored.reserveCapacity(accs.count)
        for (s, a) in accs.enumerated() {
            guard let kind = kind(a.id) else { continue }
            var score = 0.0
            var bits: UInt8 = 0
            if mode == .semantic {
                score = a.cosine ?? 0
                bits = Signals.semantic
            } else {
                if let r = a.lexRank {
                    score += config.lexicalRRFWeight * rrf(rank: r, k: config.rrfK)
                    score += config.lexicalScoreWeight * (a.lexScore ?? 0)
                    bits |= Signals.lexical
                }
                if let r = a.semRank {
                    score += config.semanticRRFWeight * rrf(rank: r, k: config.rrfK)
                    score += config.cosineWeight * max(0, (a.cosine ?? 0) - config.cosineFloor)
                    bits |= Signals.semantic
                }
                if let r = a.fileRank {
                    score += config.fileSemanticRRFWeight * rrf(rank: r, k: config.rrfK)
                    score += config.fileScoreWeight * a.fileMargin
                    bits |= Signals.semantic
                }
                if let r = a.keywordRank {
                    score += config.fileKeywordRRFWeight * rrf(rank: r, k: config.rrfK)
                    score += config.fileKeywordScoreWeight * max(0, (a.keywordCoverage ?? 0) - config.minFileKeywordCoverage)
                    bits |= Signals.lexical
                }
                if a.frecency > 0 { score += a.frecency; bits |= Signals.frecency }
                if a.memory > 0 { score += a.memory; bits |= Signals.memory }
                score += config.kindPrior[kind] ?? 0
                score += config.intentWeight * (analysis.intents[kind] ?? 0)
            }
            scores[s] = score
            signalBits[s] = bits
            scored.append(s)
        }
        let before = { (x: Int, y: Int) -> Bool in
            if scores[x] != scores[y] { return scores[x] > scores[y] }
            let lx = accs[x].lexRank ?? .max, ly = accs[y].lexRank ?? .max
            if lx != ly { return lx < ly }
            return accs[x].id < accs[y].id
        }
        let best: [Int]
        if limit >= scored.count {
            best = scored.sorted(by: before)
        } else {
            var heap = TopK<Int>(capacity: max(0, limit), before: before)
            for s in scored { heap.offer(s) }
            best = heap.sortedDescending()
        }
        return best.map { s in
            let a = accs[s]
            return Ranked(itemID: a.id, score: scores[s], signals: Signals.sets[Int(signalBits[s])],
                          breakdown: ScoreBreakdown(lexicalRank: a.lexRank, lexicalScore: a.lexScore, semanticRank: a.semRank ?? a.fileRank,
                                                    cosine: a.cosine, keywordRank: a.keywordRank, keywordCoverage: a.keywordCoverage,
                                                    frecencyBoost: a.frecency + a.memory, final: scores[s],
                                                    page: a.keywordPage ?? a.filePage))
        }
    }

    /// Signal sets as bits, mapped to one shared `Set` per combination (no set allocated per result).
    private enum Signals {
        static let lexical: UInt8 = 1, semantic: UInt8 = 2, frecency: UInt8 = 4, memory: UInt8 = 8
        static let sets: [Set<MatchSignal>] = (0..<16).map { bits in
            Set(zip([lexical, semantic, frecency, memory], [MatchSignal.lexical, .semantic, .frecency, .memory])
                .compactMap { bits & Int($0.0) != 0 ? $0.1 : nil })
        }
    }
}
