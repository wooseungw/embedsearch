import Foundation
import PDFKit
import Testing
@testable import SearchCore

/// Temporary measurement (removed after use): how full the chunks are and how far into each PDF
/// the chunk cap reaches, opendataloader-pdf vs PDFKit.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNK_STATS"] != nil))
func tmpChunkStats() throws {
    let names = ProcessInfo.processInfo.environment["CHUNK_STATS"]!.split(separator: ",").map(String.init)
    let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    let all = FileScanner(folders: [downloads]).scan().items.map { SearchEngine.filePath($0) }.filter { !FileScanner.isImage(path: $0) }
    let paths = names.compactMap { n in all.first { ($0 as NSString).lastPathComponent.hasPrefix(n) } }
    let reader = try #require(OpenDataLoader.locate(jar: PDFReadingTests.jar))
    let odl = reader.read(paths)
    let x = FileContentExtractor()
    func stats(_ s: PDFStructure) -> String {
        let chunks = PDFChunker.chunks(s, size: x.chunkCharacters, maxChunks: x.maxChunksPerPDF)
        let body = chunks.filter { !$0.isCard }
        let avg = body.isEmpty ? 0 : body.map(\.text.count).reduce(0, +) / body.count
        let total = s.blocks.map(\.text.count).reduce(0, +)
        var byKind: [String: Int] = [:]
        for b in s.blocks {
            let k: String
            switch b.kind { case .heading: k = "h"; case .paragraph: k = "p"; case .listItem: k = "li"; case .tableRow: k = "tr"; case .caption: k = "cap" }
            byKind[k, default: 0] += b.text.count
        }
        let kinds = byKind.sorted { $0.value > $1.value }.map { "\($0.key) \(100 * $0.value / max(1, total))%" }.joined(separator: " ")
        return "chunks \(chunks.count) avg \(avg) ch, last page \(body.last?.page ?? 0)/\(s.pageCount), text \(total / 1000)k [\(kinds)]"
    }
    for path in paths {
        let name = String((path as NSString).lastPathComponent.prefix(36))
        let pk = PDFStructure.pdfKit(PDFDocument(url: URL(filePath: path))!, maxPages: x.maxPages)
        print("STATS \(name)\n  pdfkit: \(stats(pk))\n  odl:    \(odl[path].map(stats) ?? "unread")")
    }
}
