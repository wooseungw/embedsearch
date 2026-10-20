import CoreText
import Foundation
import PDFKit
import Testing

@Suite("PageMatch: the query's words on a PDF page")
struct PageMatchTests {
    @Test func wordsAreTheContentWordsWithoutParticles() {
        #expect(PageMatch.words("회의록에서 attention") == ["회의록", "attention"])
        // Stopwords and one-letter words carry no place to point at.
        #expect(PageMatch.words("the x NAVSIM") == ["navsim"])
        #expect(PageMatch.words("설정") == ["설정"])
    }

    @Test func rangesIgnoreCaseAndWidthAndDoNotOverlap() {
        let text = "NAVSIM is a benchmark. navsim again, and ＮＡＶＳＩＭ."
        let ranges = PageMatch.ranges(of: ["navsim", "nav"], in: text)
        let found = ranges.map { (text as NSString).substring(with: $0) }
        #expect(found == ["NAVSIM", "navsim", "ＮＡＶＳＩＭ"])
        #expect(PageMatch.ranges(of: ["missing"], in: text).isEmpty)
        // Latin words start at a word start; their ends may go on (no stemming).
        let english = "We maintain AI safety; certain local and localized parts."
        #expect(PageMatch.ranges(of: ["ai", "local"], in: english).map { (english as NSString).substring(with: $0) }
                == ["AI", "local", "local"])
        // Korean in a longer word (particles, compounds).
        let korean = "이번 주 회의록을 정리했습니다"
        #expect(PageMatch.ranges(of: ["회의록"], in: korean).map { (korean as NSString).substring(with: $0) } == ["회의록"])
    }

    @Test func excerptStartsAtAWordAndCollapsesLines() {
        let text = "Introduction to the study of\nautonomous driving: the NAVSIM\nbenchmark scores driving policies in simulation."
        let range = (text as NSString).range(of: "NAVSIM")
        let excerpt = PageMatch.excerpt(text, around: range, page: 4, lead: 20, length: 30)
        #expect(excerpt.page == 4)
        #expect(excerpt.before == "…driving: the ")
        #expect(excerpt.match == "NAVSIM")
        #expect(excerpt.after == " benchmark scores driving poli")
        // Near the start nothing is cut.
        let start = PageMatch.excerpt(text, around: (text as NSString).range(of: "study"), page: 1, lead: 24)
        #expect(start.before == "Introduction to the ")
    }

    @Test func excerptKeepsWholeCharacters() {
        let text = String(repeating: "😀", count: 40) + " NAVSIM"
        let excerpt = PageMatch.excerpt(text, around: (text as NSString).range(of: "NAVSIM"), page: 1, lead: 5)
        #expect(!excerpt.before.unicodeScalars.contains { $0.value == 0xFFFD })
        #expect(excerpt.before.hasPrefix("…"))
    }

    @Test func firstMatchLooksAtTheChunksPageAndTheNextOnes() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pagematch-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePDF(url, pages: ["Quarterly sales report", "", "The NAVSIM benchmark", "More text", "Late NAVSIM mention"])
        let document = try #require(PDFDocument(url: url))

        let match = try #require(PageMatch.firstMatch(in: document, words: ["navsim"], from: 1))
        #expect(match.page == 3)
        #expect((match.text as NSString).substring(with: match.ranges[0]) == "NAVSIM")
        // Pages past the chunk's reach are not searched.
        #expect(PageMatch.firstMatch(in: document, words: ["mention"], from: 1) == nil)
        #expect(PageMatch.firstMatch(in: document, words: ["mention"], from: 4)?.page == 5)
        // A page past the end (the PDF lost pages since it was indexed) finds nothing.
        #expect(PageMatch.firstMatch(in: document, words: ["navsim"], from: 9) == nil)
        #expect(PageMatch.excerpt(in: document, words: ["navsim"], from: 9).isEmpty)
        // No words found: the chunk's page, without an excerpt.
        let none = PageMatch.excerpt(in: document, words: ["missing"], from: 2)
        #expect(none.page == 2 && none.isEmpty)
        #expect(PageMatch.excerpt(in: document, words: ["sales"], from: 1).match == "sales")
    }

    /// One page per string; an empty string makes a page without text.
    private func writePDF(_ url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0),
                                                     CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
                CTFrameDraw(frame, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
