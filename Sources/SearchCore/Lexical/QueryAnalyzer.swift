import Foundation

/// Query-side preprocessing shared by lexical matching and intent routing.
public struct QueryAnalysis: Sendable, Equatable {
    public let raw: String
    public let normalized: String
    public let words: [String]
    /// Words that carry the "what" of the query: stopwords and kind words ("앱", "설정", "settings")
    /// removed (unless nothing else is left). Each token lists its spelling variants
    /// (original first, then with a trailing Korean particle stripped).
    public let contentTokens: [[String]]
    /// Kind boosts in [0, 1] derived from words such as "설정", "app", "명령", "끄기".
    public let intents: [ItemKind: Double]

    /// True when content tokens differ from the plain word list (something was stripped/varied).
    public var hasReducedForm: Bool { contentTokens.map { $0[0] } != words || contentTokens.contains { $0.count > 1 } }
}

public enum QueryAnalyzer {
    /// Kind words: routed to a kind and removed from the content tokens when other words remain.
    static let kindNouns: [ItemKind: Set<String>] = [
        .systemSetting: ["설정", "환경설정", "세팅", "settings", "setting", "preferences", "preference", "prefs", "시스템환경설정"],
        .application: ["앱", "어플", "어플리케이션", "애플리케이션", "응용프로그램", "프로그램", "app", "apps", "application"],
        .command: ["명령", "명령어", "command", "commands", "cmd"],
        .shortcut: ["단축어", "shortcut", "shortcuts"],
    ]
    /// Verbs that hint at a kind but are also real content (kept as tokens), weaker boost.
    static let kindVerbs: [ItemKind: Set<String>] = [
        .application: ["열기", "열어", "열어줘", "실행", "open", "launch"],
        .command: ["끄기", "꺼", "꺼줘", "잠금", "잠그기", "잠가", "잠궈", "lock", "재시작", "재부팅", "restart", "reboot",
                   "종료", "shutdown", "로그아웃", "logout", "비우기", "empty", "토글", "toggle", "추출", "eject",
                   "mute", "음소거", "sleep", "잠자기", "켜기"],
    ]
    static let stopwords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "my", "me", "i", "how", "do", "does", "is", "are", "please",
        "can", "what", "where", "with", "and", "or", "in", "at", "want",
        "좀", "어떻게", "어디", "어디서", "방법", "하는", "하는법", "법", "해줘", "줘", "하자", "싶어", "싶다", "수", "있는", "곳", "거", "것", "때",
    ]
    /// Korean particles stripped from the end of a token (longest first).
    static let particles: [String] = [
        "에서", "으로", "에게", "한테", "까지", "부터", "하고", "이랑",
        "을", "를", "이", "가", "은", "는", "에", "로", "의", "도", "와", "과", "랑", "만",
    ]

    public static func analyze(_ query: String) -> QueryAnalysis {
        let normalized = TextNormalizer.normalize(query)
        let words = normalized.split(separator: " ").map(String.init)

        var intents: [ItemKind: Double] = [:]
        var kindNounIndices = Set<Int>()
        for (i, w) in words.enumerated() {
            for (kind, nouns) in kindNouns where nouns.contains(w) {
                kindNounIndices.insert(i)
                intents[kind] = max(intents[kind] ?? 0, 1.0)
            }
            for (kind, verbs) in kindVerbs where verbs.contains(w) {
                intents[kind] = max(intents[kind] ?? 0, 0.5)
            }
        }
        // "설정 앱" style two-word joins, e.g. "환경 설정", "시스템 환경 설정".
        let joined = words.joined()
        if joined.hasSuffix("환경설정") { intents[.systemSetting] = 1.0 }

        var content: [[String]] = []
        for (i, w) in words.enumerated() where !kindNounIndices.contains(i) && !stopwords.contains(w) {
            content.append(variants(of: w))
        }
        if content.isEmpty {
            // The query is only kind words / stopwords ("설정", "app"): search them literally, no routing.
            content = words.map { [$0] }
            intents = [:]
        }
        return QueryAnalysis(raw: query, normalized: normalized, words: words, contentTokens: content, intents: intents)
    }

    static func variants(of word: String) -> [String] {
        guard Hangul.containsHangul(word) else { return [word] }
        for p in particles where word.hasSuffix(p) && word.count >= p.count + 1 {
            let stem = String(word.dropLast(p.count))
            // Keep at least two syllables unless the particle is two syllables long ("앱에서" → "앱").
            if stem.count >= 2 || p.count >= 2 { return [word, stem] }
        }
        return [word]
    }
}
