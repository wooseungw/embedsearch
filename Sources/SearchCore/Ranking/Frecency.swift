import Foundation

/// Firefox-style exponential decay of selection counts combined with zoxide's recency buckets.
public enum Frecency {
    /// `value` decayed by `elapsed` seconds with the given half-life.
    public static func decay(_ value: Double, elapsed: TimeInterval, halfLife: TimeInterval) -> Double {
        guard halfLife > 0 else { return value }
        return value * pow(2, -max(0, elapsed) / halfLife)
    }

    /// zoxide: used within the hour ×4, within a day ×2, within a week ÷2, older ÷4.
    public static func recencyMultiplier(elapsed: TimeInterval) -> Double {
        switch max(0, elapsed) {
        case ..<3_600: 4
        case ..<86_400: 2
        case ..<604_800: 0.5
        default: 0.25
        }
    }

    public static func score(_ record: UsageRecord, now: Date, halfLife: TimeInterval) -> Double {
        let elapsed = now.timeIntervalSince(record.lastUsed)
        return decay(record.frecency, elapsed: elapsed, halfLife: halfLife) * recencyMultiplier(elapsed: elapsed)
    }

    public static func boost(_ record: UsageRecord?, now: Date, config: RankingConfig) -> Double {
        guard let record else { return 0 }
        let s = score(record, now: now, halfLife: config.frecencyHalfLife)
        return min(config.frecencyCap, config.frecencyWeight * log1p(s))
    }

    /// Query-memory boost per item for the normalized query `query`.
    public static func memoryBoosts(_ records: [QueryMemoryRecord], query: String, now: Date,
                                    config: RankingConfig) -> [String: Double] {
        guard !query.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        for r in records {
            let factor: Double
            if r.query == query {
                factor = 1
            } else if r.query.hasPrefix(query) {
                factor = config.memoryPrefixFactor
            } else if query.hasPrefix(r.query), r.query.count >= 2 {
                factor = config.memoryExtensionFactor
            } else {
                continue
            }
            let w = decay(r.weight, elapsed: now.timeIntervalSince(r.lastUsed), halfLife: config.frecencyHalfLife)
            let b = config.memoryWeight * factor * log1p(w)
            if b > (out[r.itemID] ?? 0) { out[r.itemID] = b }
        }
        return out
    }
}

/// `Frecency.memoryBoosts` without scanning every record per keystroke. Each matching condition
/// (equal, or one query a prefix of the other) implies that the remembered and the current query
/// start with the same character, so records are bucketed by first character and only the current
/// query's bucket is scanned — same result.
struct QueryMemoryIndex: Sendable {
    private var buckets: [String: [QueryMemoryRecord]] = [:]

    init(_ records: [QueryMemoryRecord] = []) {
        for r in records {
            guard let key = Self.key(r.query) else { continue }  // an empty query never matches
            buckets[key, default: []].append(r)
        }
    }

    /// Replaces the record with the same (query, item) — compared as bytes, like the table's
    /// primary key — or adds it.
    mutating func upsert(_ r: QueryMemoryRecord) {
        guard let key = Self.key(r.query) else { return }
        let same = { (o: QueryMemoryRecord) in o.itemID.utf8.elementsEqual(r.itemID.utf8) && o.query.utf8.elementsEqual(r.query.utf8) }
        if let i = buckets[key]?.firstIndex(where: same) {
            buckets[key]![i] = r
        } else {
            buckets[key, default: []].append(r)
        }
    }

    func boosts(query: String, now: Date, config: RankingConfig) -> [String: Double] {
        guard let key = Self.key(query), let records = buckets[key] else { return [:] }
        return Frecency.memoryBoosts(records, query: query, now: now, config: config)
    }

    private static func key(_ query: String) -> String? { query.first.map(String.init) }
}
