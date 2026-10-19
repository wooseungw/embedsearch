import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import SearchCore

@Suite("PDF reading")
struct PDFReadingTests {
    /// opendataloader-pdf's JSON shape: numbers as strings, lists nested in "list items" and kids,
    /// table text inside rows → cells → kids.
    static let sampleJSON = """
    {"file name": "paper.pdf", "number of pages": 3, "title": "Microsoft Word - draft.docx", "kids": [
      {"type": "heading", "heading level": "1", "page number": "1", "content": "Sparse Retrieval for Launchers"},
      {"type": "heading", "heading level": "2", "page number": "1", "content": "Abstract"},
      {"type": "paragraph", "page number": "1", "content": "We study how a launcher finds files by meaning on device."},
      {"type": "image", "page number": "1"},
      {"type": "heading", "heading level": "2", "page number": "2", "content": "1 Method"},
      {"type": "list", "page number": "2", "list items": [
        {"type": "list item", "page number": "2", "content": "Chunk pages at block boundaries.", "kids": [
          {"type": "list", "page number": "2", "list items": [
            {"type": "list item", "page number": "2", "content": "Keep section headings.", "kids": []}]}]}]},
      {"type": "table", "page number": "2", "rows": [
        {"type": "table row", "page number": "2", "cells": [
          {"type": "table cell", "kids": [{"type": "paragraph", "content": "Recall"}]},
          {"type": "table cell", "kids": [{"type": "paragraph", "content": "0.91"}]}]}]},
      {"type": "heading", "heading level": "2", "page number": "3", "content": "References"},
      {"type": "paragraph", "page number": "3", "content": "[1] Somebody. A paper about everything. 2020."}
    ]}
    """

    @Test func parsesOpenDataLoaderJSON() throws {
        let structure = try PDFStructure.openDataLoaderJSON(Data(Self.sampleJSON.utf8))
        #expect(structure.pageCount == 3)
        #expect(structure.title == nil)  // "Microsoft Word - …" says nothing
        #expect(structure.blocks.map(\.kind) == [
            .heading(level: 1), .heading(level: 2), .paragraph, .heading(level: 2), .listItem, .listItem,
            .tableRow, .heading(level: 2), .paragraph,
        ])
        #expect(structure.blocks[6].text == "Recall | 0.91")
        #expect(structure.blocks[5].text == "Keep section headings.")
        #expect(structure.blocks[5].page == 2)
        #expect(structure.pagesWithoutText.isEmpty)
    }

    @Test func chunksCarryCardSectionsAndPagesWithoutReferences() throws {
        let structure = try PDFStructure.openDataLoaderJSON(Data(Self.sampleJSON.utf8))
        let chunks = PDFChunker.chunks(structure, size: 800, maxChunks: 10)
        let card = try #require(chunks.first)
        #expect(card.isCard)
        #expect(card.text.hasPrefix("Sparse Retrieval for Launchers"))
        #expect(card.text.contains("1 Method"))
        #expect(card.text.contains("finds files by meaning"))
        // Short sections share one chunk, the later heading inline.
        let body = Array(chunks.dropFirst())
        try #require(body.count == 1)
        #expect(body[0].text.hasPrefix("[Abstract] We study"))
        #expect(body[0].text.contains("on device. 1 Method Chunk pages"))
        #expect(body[0].text.contains("Recall | 0.91"))
        #expect(body[0].page == 1)
        #expect(!chunks.contains { $0.text.contains("A paper about everything") })
        #expect(PDFChunker.chunks(structure, size: 800, maxChunks: 1).count == 1)
    }

    @Test func chunksFillUpAndHeadingsStartChunksOnceHalfFull() throws {
        let sentence = "Dense retrieval maps every passage into one vector space for search."  // 68
        let paragraph = Array(repeating: sentence, count: 3).joined(separator: " ")         // 206
        let structure = PDFStructure(title: nil, pageCount: 3, blocks: [
            .init(kind: .heading(level: 1), text: "Intro", page: 1),
            .init(kind: .paragraph, text: paragraph, page: 1),
            .init(kind: .paragraph, text: paragraph, page: 2),
            .init(kind: .paragraph, text: paragraph, page: 2),
            .init(kind: .heading(level: 1), text: "Method", page: 2),
            .init(kind: .paragraph, text: paragraph, page: 3),
        ])
        let body = PDFChunker.chunks(structure, size: 400, maxChunks: 10).filter { !$0.isCard }
        // The second paragraph fills the first chunk (185 characters left) between words and goes
        // on in the next, which the third makes over half full, so "Method" starts a third.
        #expect(body.allSatisfy { $0.text.count <= 400 })
        try #require(body.map(\.page) == [1, 2, 3])
        #expect(body[0].text.hasPrefix("[Intro] Dense") && body[0].text.count >= 380)
        #expect(body[1].text.hasPrefix("[Intro] vector space for search. Dense"))
        #expect(body[2].text.hasPrefix("[Method] Dense"))
        // Nothing lost: every word of the body is in some chunk, in order.
        let words = body.map { $0.text.replacingOccurrences(of: "^\\[[A-Za-z]+\\] ", with: "", options: .regularExpression) }
            .joined(separator: " ").split(separator: " ")
        #expect(words == Array(repeating: paragraph, count: 4).joined(separator: " ").split(separator: " "))
        #expect(PDFChunker.split("one two three", fitting: 7) == ("one two", "three"))
        #expect(PDFChunker.split("unbreakable", fitting: 4) == ("", "unbreakable"))
    }

    @Test func pdfKitFallbackDropsRunningHeadersAndJoinsHyphenation() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let pages = (1...4).map { i in
            "JOURNAL OF TESTS VOL 3\nPage body \(i) talks about infor-\nmation retrieval on device.\n\(i)"
        }
        try writeLinedPDF(folder.path("doc.pdf"), pages: pages)
        let document = try #require(PDFDocument(url: folder.path("doc.pdf")))
        let structure = PDFStructure.pdfKit(document, maxPages: 10)
        try #require(structure.blocks.count == 4)
        #expect(structure.blocks.allSatisfy { !$0.text.contains("JOURNAL OF TESTS") })
        #expect(structure.blocks[0].text.contains("information retrieval"))
        #expect(structure.blocks[3].page == 4)
    }

    @Test func runsSplitWhereFileNamesRepeat() {
        let batches = OpenDataLoader.batches(["/a/x.pdf", "/a/y.pdf", "/b/X.pdf", "/b/z.pdf"], size: 3)
        #expect(batches == [["/a/x.pdf", "/a/y.pdf"], ["/b/X.pdf", "/b/z.pdf"]])
        #expect(OpenDataLoader.batches(["/1.pdf", "/2.pdf", "/3.pdf"], size: 2) == [["/1.pdf", "/2.pdf"], ["/3.pdf"]])
    }

    /// The real CLI, when Java and the fetched JAR (scripts/fetch-opendataloader.sh) are here.
    static let jar = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "vendor/opendataloader/opendataloader-pdf-cli.jar")

    @Test(.enabled(if: OpenDataLoader.locate(jar: jar) != nil, "needs Java 11+ and the vendored JAR"))
    func readsARealPDF() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("one.pdf", pages: ["Train ticket from Seoul to Busan, departure nine thirty, seat 12A"])
        try folder.writePDF("two.pdf", pages: ["Hotel booking in Jeju for two nights", ""])
        try "not a pdf".write(to: folder.path("broken.pdf"), atomically: true, encoding: .utf8)
        let reader = try #require(OpenDataLoader.locate(jar: Self.jar))
        let paths = ["one.pdf", "two.pdf", "broken.pdf"].map { folder.path($0).path(percentEncoded: false) }
        let read = reader.read(paths)
        #expect(read[paths[0]]?.blocks.map(\.text).joined().contains("Seoul to Busan") == true)
        #expect(read[paths[1]]?.pagesWithoutText == [2])
        #expect(read[paths[2]] == nil)
    }
}

/// A PDF whose pages hold the given lines ("\n" separated), one CTLine per line, top down.
private func writeLinedPDF(_ url: URL, pages: [String]) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for page in pages {
        context.beginPDFPage(nil)
        for (i, line) in page.split(separator: "\n").enumerated() {
            let string = NSAttributedString(string: String(line), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(i) * 18)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
}
