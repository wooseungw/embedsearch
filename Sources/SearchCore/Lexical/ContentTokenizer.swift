import Foundation

/// Tokens of file text for keyword search (the FTS5 index in `IndexStore`), and of the queries run
/// against it — chunks and queries go through the same `tokens`.
///
/// The words of `TextNormalizer.normalize`, each cut into runs of Hangul syllables and runs of
/// anything else. A Hangul run becomes its overlapping two-syllable bigrams ("다이캐스팅" → 다이 이캐
/// 캐스 스팅; a single syllable stays as is): Korean writes compounds and particles into one word, and
/// bigrams let "캐스팅" match inside "다이캐스팅을" without a morphological analyzer. Other runs stay
/// whole, so "NAVSIM을" still yields "navsim". Single Latin letters (initials, list markers, math
/// variables) are dropped; digits and mixed tokens ("3d", "v2") are kept.
public enum ContentTokenizer {
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var run: [Unicode.Scalar] = []
        var runIsHangul = false
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            if runIsHangul, run.count > 1 {
                for i in 0..<(run.count - 1) { out.append(String(String.UnicodeScalarView(run[i...(i + 1)]))) }
            } else if runIsHangul || !(run.count == 1 && run[0].value < 0x250 && run[0].properties.isAlphabetic) {
                out.append(String(String.UnicodeScalarView(run)))
            }
        }
        for word in TextNormalizer.normalize(text).split(separator: " ") {
            for scalar in word.unicodeScalars {
                let hangul = Hangul.isSyllable(scalar.value)
                if !run.isEmpty, hangul != runIsHangul { flush() }
                runIsHangul = hangul
                run.append(scalar)
            }
            if !run.isEmpty { flush() }
        }
        return out
    }

    /// A query's content words (`QueryAnalysis.contentTokens`: stopwords and kind words such as
    /// "설정" gone), each as its tokens, which keyword search matches as a phrase; distinct, and
    /// words without tokens left out. Korean particles are stripped first: a document keeps
    /// "공정에서" whole, and its bigrams include "공정"; the query's "공정에서" would add "정에"
    /// and "에서", which a document that says "공정은" lacks.
    public static func queryWords(_ analysis: QueryAnalysis) -> [[String]] {
        var seen = Set<[String]>()
        return analysis.contentTokens.map { tokens($0.last ?? "") }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
