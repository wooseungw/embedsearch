import Foundation

/// Shapes results that include files:
/// - A file found only by its name, and only loosely (initials, fuzzy: below
///   `RankingConfig.minFileNameScore`), is dropped — long, arbitrary file names match anything. A
///   file whose content matched (semantically, or by the words of its text) stays.
/// - Settings that match only loosely move to a trailing `.settings` section, after everything else.
///   Many of the ~760 setting rows share words with any query ("사진", "화면"), and their partial name
///   matches would bury a file found by its content. A setting stays in place when it is a confident
///   match: the query asks for settings ("설정", "settings"), or its name matches with a lexical score
///   of at least `RankingConfig.confidentSettingScore`.
enum ResultSections {
    static func arrange(_ results: [SearchResult], analysis: QueryAnalysis, config: RankingConfig) -> [SearchResult] {
        let results = results.filter { result in
            result.item.kind != .file || result.signals.contains(.semantic) || result.breakdown.keywordRank != nil
                || (result.breakdown.lexicalScore ?? 0) >= config.minFileNameScore
        }
        guard results.contains(where: { $0.item.kind == .file }),
              (analysis.intents[.systemSetting] ?? 0) == 0 else { return results }
        var main: [SearchResult] = []
        var later: [SearchResult] = []
        main.reserveCapacity(results.count)
        for result in results {
            if result.item.kind == .systemSetting, (result.breakdown.lexicalScore ?? 0) < config.confidentSettingScore {
                later.append(SearchResult(item: result.item, score: result.score, signals: result.signals,
                                          breakdown: result.breakdown, section: .settings))
            } else {
                main.append(result)
            }
        }
        return main + later
    }
}
