import Foundation

/// Every knob of the hybrid ranker. Defaults are tuned on `eval/queries.jsonl` (see docs/eval-results.md).
///
/// Final score = RRF(lexical rank) + RRF(semantic rank) + lexicalScoreWeight·lexicalScore
///   + cosineWeight·max(0, cosine − cosineFloor) + frecency + query memory + kind prior + intent boost,
///   and for files RRF(content match rank) and RRF(keyword match rank) with their margins.
/// RRF terms are ~1/61 ≈ 0.016 at rank 1, so the other weights are on that scale.
public struct RankingConfig: Sendable, Equatable {
    public var rrfK: Double = 60
    public var lexicalRRFWeight: Double = 1.0
    public var semanticRRFWeight: Double = 1.0
    /// Rewards strong lexical tiers (exact 1.0 … fuzzy ~0.2) beyond their rank.
    public var lexicalScoreWeight: Double = 0.02
    public var cosineWeight: Double = 0.0
    public var cosineFloor: Double = 0.3
    /// Items found only by the embedding must reach this cosine to be shown.
    public var minSemanticCosine: Double = 0.35
    public var lexicalCandidates: Int = 50
    public var semanticCandidates: Int = 50

    /// Frecency boost = min(cap, weight · ln(1 + decayed count × zoxide recency bucket)).
    public var frecencyWeight: Double = 0.004
    public var frecencyCap: Double = 0.012
    public var frecencyHalfLife: TimeInterval = 14 * 86_400

    /// Query memory boost = weight · match factor · ln(1 + decayed selections).
    public var memoryWeight: Double = 0.03
    /// Factor when the current query is a prefix of a remembered query ("ca" vs remembered "cal").
    public var memoryPrefixFactor: Double = 0.6
    /// Factor when a remembered query is a prefix of the current one ("cal" remembered, typing "calc").
    public var memoryExtensionFactor: Double = 0.3

    /// Multiplied by the analyzer's intent strength (1.0 for kind nouns like "설정", 0.5 for verbs).
    public var intentWeight: Double = 0.01
    public var kindPrior: [ItemKind: Double] = [.application: 0.002, .command: 0.001]

    /// File content (see `ChunkIndex`): a file is a semantic match when its best chunk's cosine minus
    /// `hubWeight` × that chunk's hubness reaches `minFileScore`. Matches are fused as their own RRF
    /// list (files never displace items from the item list) plus `fileScoreWeight` × how far they
    /// clear `minFileScore`, so a clear content match outranks items that match only vaguely.
    /// Tuned on ~/Downloads (312 files, 24 file queries: MRR 0.69 → 0.87, all in the top 5) while
    /// the item eval set stayed at its file-free level (hybrid MRR 0.895 → 0.900). Below hubWeight
    /// 1.0, files flood item queries.
    public var fileSemanticRRFWeight: Double = 1.0
    public var fileScoreWeight: Double = 0.3
    public var minFileScore: Double = 0.09
    public var hubWeight: Double = 1.0
    public var fileCandidates: Int = 30

    /// Keyword search over file text (`IndexStore.keywordMatches`): the `fileKeywordChunks` best
    /// chunks by bm25, each file's best one kept. A file is listed when that chunk covers at least
    /// `minFileKeywordCoverage` of the query (IDF-weighted share of its tokens), so a query whose
    /// distinctive words a file lacks does not pull it in through common ones ("카카오톡 알림" and
    /// a document with "알림"). Fused like file content matches: its own RRF list, contributing
    /// `.lexical`, plus `fileKeywordScoreWeight` × how far the coverage clears the minimum.
    /// 0.5/61 + 0.01 × 0.3 < 1/61, so a file found only by its words never outranks the best
    /// semantic-only item (an item query keeps its first result), while a file both lists find
    /// adds the two up. Tuned on ~/Downloads (274 files with text, 7074 chunks), keyword list off →
    /// on: section-heading queries MRR 0.601 → 0.702, file queries 0.862 → 0.840 (the e-ticket now
    /// edges out the booking PDF for "항공권 예약 확인"), content queries 0.899 → 0.899, item eval
    /// (hybrid) 0.907 → 0.907. 0.8 gained 0.011 more on headings but cost a second file query
    /// (0.819); 0.3 kept file queries at 0.842 but gave back a third of the heading gain (0.674).
    public var fileKeywordRRFWeight: Double = 0.5
    public var fileKeywordScoreWeight: Double = 0.01
    public var minFileKeywordCoverage: Double = 0.7
    /// A file the content search did not also find is listed for its words only when they are rare
    /// across files (`IndexStore.KeywordMatch.rarity`: 1 = a word one file has). 0.87 lets through
    /// a word in up to 2 of ~/Downloads' 274 files (0.90; "densepass") and stops one in 3 or more
    /// (0.84; "travel", "뉴스"; "meeting" 0.79, "회의" 0.65); two words in 10 files each pass (1.26).
    public var minFileKeywordRarity: Double = 0.87
    public var fileKeywordCandidates: Int = 30
    public var fileKeywordChunks: Int = 200
    /// No keyword matches when an app, setting or command name matches the query at least this
    /// well (lexical score: exact 1.0, word prefix ≈ 0.68+, substring ≈ 0.6, a keyword many settings
    /// share ≈ 0.58, initials and fuzzy below 0.45): the query names that item, and documents with
    /// the same words would push it down. Above 1: always use them.
    public var fileKeywordMaxItemNameScore: Double = 0.55

    /// With files among the results, a setting keeps its rank only when its name matches at least
    /// this well (word-prefix of a title ≈ 0.68+, substring ≤ 0.62; partial multi-word matches and
    /// keywords shared by many settings score lower) or the query asks for settings; the others
    /// move to a section after everything else (`ResultSections`).
    public var confidentSettingScore: Double = 0.65
    /// A file found by its name alone needs at least this lexical score (a substring match or
    /// better): initials and fuzzy matches of long, arbitrary file names are noise.
    public var minFileNameScore: Double = 0.5

    /// Off for evaluation runs so personal history does not leak into the metrics.
    public var useUsageSignals: Bool = true

    public init() {}

    public static let `default` = RankingConfig()
}
