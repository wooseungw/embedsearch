import Foundation
import PDFKit
import SearchCore

/// Where a query's words are on a PDF's pages, for the result row's excerpt and the preview's
/// highlights. The index keeps no chunk text (its keyword index is contentless), so the page is
/// read again with PDFKit, starting at the page the matching chunk starts on
/// (`ScoreBreakdown.page`).
enum PageMatch {
    /// A chunk (~800 characters) that starts on a page ends on it or on one of the next pages.
    static let span = 3

    struct Excerpt: Sendable, Hashable {
        /// The page (1-based) the words were found on, or the chunk's page when they were not.
        var page: Int
        /// Text before the first match (with a leading "…" when cut), the match, and the text after.
        /// All empty when no word is on the pages: the match was by meaning only.
        var before = ""
        var match = ""
        var after = ""

        var isEmpty: Bool { match.isEmpty }
    }

    /// The query's content words (particles stripped, as keyword search uses them), two characters
    /// or more.
    static func words(_ query: String) -> [String] {
        var seen = Set<String>()
        return QueryAnalyzer.analyze(query).contentTokens.compactMap(\.last)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    /// Ranges (UTF-16, as `PDFPage.selection(for:)` takes them) of `words` in `text`, ignoring case,
    /// width and composition, in text order, not overlapping. A word in Latin letters or digits
    /// starts at a word start ("ai" is not in "maintain"; "local" is in "localize"); Korean is
    /// matched inside words, where its particles and compounds are.
    static func ranges(of words: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        var found: [NSRange] = []
        for word in words {
            let atWordStart = word.unicodeScalars.allSatisfy(\.isASCII)
            var start = 0
            while start < string.length {
                let r = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: NSRange(location: start, length: string.length - start))
                guard r.location != NSNotFound, r.length > 0 else { break }
                if !atWordStart || r.location == 0 || !isWordCharacter(string.character(at: r.location - 1)) {
                    found.append(r)
                }
                start = r.location + r.length
            }
        }
        // At the same place the longer word wins ("navsim" over "nav").
        found.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var out: [NSRange] = []
        for r in found where out.last.map({ NSMaxRange($0) <= r.location }) ?? true { out.append(r) }
        return out
    }

    /// A letter or digit, by UTF-16 unit (a surrogate half counts as one: it is part of a symbol).
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// `text` around `range`: up to `lead` characters before it (from a word start; a row has room
    /// for little, and the match must show) and the rest of the line's worth after it, whitespace
    /// collapsed.
    static func excerpt(_ text: String, around range: NSRange, page: Int, lead: Int = 10, length: Int = 120) -> Excerpt {
        let string = text as NSString
        guard string.length > 0 else { return Excerpt(page: page) }
        // Whole characters only: a cut through a surrogate pair would show as "�".
        var from = string.rangeOfComposedCharacterSequence(at: max(0, range.location - lead * 2)).location
        // Back up no further than `lead` characters of collapsed text, starting at a word.
        var head = collapse(string.substring(with: NSRange(location: from, length: range.location - from)))
        var cut = from > 0
        if head.count > lead {
            head = String(head.suffix(lead))
            cut = true
        }
        if cut, let space = head.firstIndex(of: " ") {
            head = String(head[head.index(after: space)...])
        }
        from = NSMaxRange(range)
        let rest = string.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: min(length * 2, string.length - from)))
        let tail = collapse(string.substring(with: rest))
        return Excerpt(page: page, before: (cut ? "…" : "") + head, match: collapse(string.substring(with: range)),
                       after: String(tail.prefix(length)))
    }

    /// The first of the pages `page`…`page + span − 1` that has any of `words`, as an excerpt
    /// around the first one; an empty excerpt for `page` when none has them.
    static func excerpt(in document: PDFDocument, words: [String], from page: Int) -> Excerpt {
        guard let (number, text, ranges) = firstMatch(in: document, words: words, from: page) else {
            return Excerpt(page: page)
        }
        return excerpt(text, around: ranges[0], page: number)
    }

    /// The first of the pages `page`…`page + span − 1` whose text has any of `words`: its number,
    /// text and the words' ranges.
    static func firstMatch(in document: PDFDocument, words: [String], from page: Int)
        -> (page: Int, text: String, ranges: [NSRange])? {
        // The page can be past the end: a PDF that lost pages since it was indexed.
        let end = min(page + span, document.pageCount + 1)
        guard !words.isEmpty, page >= 1, page < end else { return nil }
        for number in page..<end {
            guard let text = document.page(at: number - 1)?.string, !text.isEmpty else { continue }
            let ranges = ranges(of: words, in: text)
            if !ranges.isEmpty { return (number, text, ranges) }
        }
        return nil
    }

    /// On this Mac: reading an iCloud file whose content is only in the cloud would download it.
    static func isLocal(_ path: String) -> Bool {
        let values = try? URL(filePath: path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus == .current
    }

    /// Whitespace runs (line breaks too) as one space; ends kept as they are, but no line breaks.
    static func collapse(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        if pendingSpace { out.append(" ") }
        return out
    }
}
