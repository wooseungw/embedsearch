import Foundation

/// One expected target. Every non-nil field must match; `title` is a normalized substring of the
/// item's title or subtitle, so matchers survive small OS wording changes.
public struct EvalMatcher: Codable, Sendable, Hashable, CustomStringConvertible {
    public var id: String?
    public var idPrefix: String?
    public var kind: ItemKind?
    public var title: String?

    public init(id: String? = nil, idPrefix: String? = nil, kind: ItemKind? = nil, title: String? = nil) {
        self.id = id
        self.idPrefix = idPrefix
        self.kind = kind
        self.title = title
    }

    public func matches(_ item: SearchItem) -> Bool {
        matches(item, needle: title.map(TextNormalizer.compact), haystack: { Self.haystack(item) })
    }

    /// `matches` with the normalized title needle and item haystack supplied (computed once by
    /// callers that test many pairs).
    func matches(_ item: SearchItem, needle: String?, haystack: () -> String) -> Bool {
        if let id, item.id != id { return false }
        if let idPrefix, !item.id.hasPrefix(idPrefix) { return false }
        if let kind, item.kind != kind { return false }
        if let needle {
            if needle.isEmpty || !haystack().contains(needle) { return false }
        }
        return id != nil || idPrefix != nil || kind != nil || title != nil
    }

    static func haystack(_ item: SearchItem) -> String {
        TextNormalizer.compact(item.title) + "\u{1F}" + TextNormalizer.compact(item.subtitle ?? "")
    }

    public var description: String {
        [id.map { "id=\($0)" }, idPrefix.map { "id^=\($0)" }, kind.map { "kind=\($0.rawValue)" }, title.map { "title~\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public struct EvalQuery: Codable, Sendable, Hashable {
    public var q: String
    /// "ko", "en" or "mixed".
    public var lang: String
    /// e.g. "exact", "prefix", "typo", "chosung", "paraphrase", "intent", "crosslang".
    public var type: String
    public var expect: [EvalMatcher]
    public var note: String?

    public func isRelevant(_ item: SearchItem) -> Bool { expect.contains { $0.matches(item) } }
}

public enum EvalSet {
    /// Reads JSON Lines; blank lines and lines starting with `//` or `#` are ignored.
    public static func load(_ url: URL) throws -> [EvalQuery] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var out: [EvalQuery] = []
        for (n, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") { continue }
            do {
                out.append(try decoder.decode(EvalQuery.self, from: Data(trimmed.utf8)))
            } catch {
                throw EvalError.badLine(n + 1, String(describing: error))
            }
        }
        return out
    }

    /// Matchers (as "query → matcher") that match no item of the corpus.
    public static func unmatchedExpectations(_ queries: [EvalQuery], items: [SearchItem]) -> [String] {
        var haystacks = [String?](repeating: nil, count: items.count)
        var out: [String] = []
        for q in queries {
            for m in q.expect {
                let needle = m.title.map(TextNormalizer.compact)
                let found = items.indices.contains { i in
                    m.matches(items[i], needle: needle) {
                        if let h = haystacks[i] { return h }
                        let h = EvalMatcher.haystack(items[i])
                        haystacks[i] = h
                        return h
                    }
                }
                if !found { out.append("\(q.q) → \(m)") }
            }
        }
        return out
    }
}

public enum EvalError: Error, CustomStringConvertible {
    case badLine(Int, String)
    public var description: String {
        switch self {
        case .badLine(let n, let e): "eval set line \(n): \(e)"
        }
    }
}

public struct EvalOutcome: Sendable {
    public let query: EvalQuery
    /// 1-based rank of the first relevant result within the cutoff, nil if none.
    public let rank: Int?
    public let top: [SearchResult]
    public let latency: TimeInterval
}

public struct EvalMetrics: Sendable, Equatable {
    public var count = 0
    public var mrr10 = 0.0
    public var success1 = 0.0
    public var success5 = 0.0
    public var success10 = 0.0

    public static func compute(_ outcomes: [EvalOutcome]) -> EvalMetrics {
        var m = EvalMetrics()
        m.count = outcomes.count
        guard !outcomes.isEmpty else { return m }
        for o in outcomes {
            guard let r = o.rank else { continue }
            if r <= 10 { m.mrr10 += 1 / Double(r); m.success10 += 1 }
            if r <= 5 { m.success5 += 1 }
            if r == 1 { m.success1 += 1 }
        }
        let n = Double(outcomes.count)
        m.mrr10 /= n
        m.success1 /= n
        m.success5 /= n
        m.success10 /= n
        return m
    }
}

public struct EvalReport: Sendable {
    public let mode: SearchMode
    public let overall: EvalMetrics
    public let byLang: [(String, EvalMetrics)]
    public let byType: [(String, EvalMetrics)]
    public let outcomes: [EvalOutcome]
    public var failures: [EvalOutcome] { outcomes.filter { $0.rank != 1 } }
    public var latencyP50: TimeInterval { percentile(0.5) }
    public var latencyP95: TimeInterval { percentile(0.95) }

    private func percentile(_ p: Double) -> TimeInterval {
        let sorted = outcomes.map(\.latency).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

public enum Evaluator {
    public static let cutoff = 10

    public static func run(_ queries: [EvalQuery], mode: SearchMode,
                           search: (String, SearchMode) async throws -> [SearchResult]) async -> EvalReport {
        var outcomes: [EvalOutcome] = []
        for q in queries {
            let start = Date()
            let results = (try? await search(q.q, mode)) ?? []
            let latency = Date().timeIntervalSince(start)
            let rank = results.prefix(cutoff).firstIndex { q.isRelevant($0.item) }.map { $0 + 1 }
            outcomes.append(EvalOutcome(query: q, rank: rank, top: Array(results.prefix(5)), latency: latency))
        }
        return report(mode: mode, outcomes)
    }

    public static func run(engine: SearchEngine, queries: [EvalQuery], mode: SearchMode) async -> EvalReport {
        await run(queries, mode: mode) { q, m in try await engine.search(q, mode: m, limit: cutoff) }
    }

    static func report(mode: SearchMode, _ outcomes: [EvalOutcome]) -> EvalReport {
        func grouped(_ key: (EvalQuery) -> String) -> [(String, EvalMetrics)] {
            Dictionary(grouping: outcomes) { key($0.query) }
                .map { ($0.key, EvalMetrics.compute($0.value)) }
                .sorted { $0.0 < $1.0 }
        }
        return EvalReport(mode: mode, overall: EvalMetrics.compute(outcomes), byLang: grouped(\.lang),
                          byType: grouped(\.type), outcomes: outcomes)
    }
}
