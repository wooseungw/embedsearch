import Foundation
import PDFKit

/// A PDF as text blocks in reading order, with headings and page numbers: what opendataloader-pdf
/// reports (`OpenDataLoader`), or what PDFKit's plain text gives after removing running headers
/// and footers, hyphenation breaks and binary junk (the fallback without Java).
public struct PDFStructure: Sendable {
    public enum BlockKind: Sendable, Equatable {
        case heading(level: Int)
        case paragraph
        case listItem
        case tableRow
        case caption
    }

    public struct Block: Sendable, Equatable {
        public var kind: BlockKind
        public var text: String
        /// 1-based.
        public var page: Int

        public init(kind: BlockKind, text: String, page: Int) {
            self.kind = kind
            self.text = text
            self.page = page
        }
    }

    /// The document title from its metadata, when it says something (not "Microsoft Word - …").
    public var title: String?
    public var pageCount: Int
    public var blocks: [Block]
    /// Pages without any text (scanned or picture-only), 1-based.
    public var pagesWithoutText: [Int]

    public init(title: String?, pageCount: Int, blocks: [Block], pagesWithoutText: [Int] = []) {
        self.title = title
        self.pageCount = pageCount
        self.blocks = blocks
        self.pagesWithoutText = pagesWithoutText
    }

    // MARK: opendataloader-pdf JSON

    /// Parses opendataloader-pdf's JSON output (`-f json`). Its numbers arrive as strings or numbers.
    public static func openDataLoaderJSON(_ data: Data) throws -> PDFStructure {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var blocks: [Block] = []
        var pagesWithText = Set<Int>()
        func int(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let s = value as? String { return Int(s) }
            return nil
        }
        func text(_ element: [String: Any]) -> String? {
            guard let content = element["content"] as? String else { return nil }
            let cleaned = ItemText.clean(content)
            return cleaned.isEmpty ? nil : cleaned
        }
        /// All text inside an element (table cells hold their text in nested kids).
        func flatText(_ value: Any?) -> [String] {
            if let element = value as? [String: Any] {
                var out: [String] = []
                if let t = text(element) { out.append(t) }
                for key in ["kids", "list items", "rows", "cells"] { out += flatText(element[key]) }
                return out
            }
            if let list = value as? [Any] { return list.flatMap(flatText) }
            return []
        }
        func walk(_ value: Any?) {
            guard let list = value as? [Any] else { return }
            for case let element as [String: Any] in list {
                let page = int(element["page number"]) ?? 1
                switch element["type"] as? String {
                case "heading":
                    if let t = text(element) {
                        blocks.append(Block(kind: .heading(level: int(element["heading level"]) ?? 1), text: t, page: page))
                        pagesWithText.insert(page)
                    }
                case "paragraph", "text block", "formula":
                    if let t = text(element) {
                        blocks.append(Block(kind: .paragraph, text: t, page: page))
                        pagesWithText.insert(page)
                    }
                case "caption":
                    if let t = text(element) {
                        blocks.append(Block(kind: .caption, text: t, page: page))
                        pagesWithText.insert(page)
                    }
                case "list item":
                    if let t = text(element) {
                        blocks.append(Block(kind: .listItem, text: t, page: page))
                        pagesWithText.insert(page)
                    }
                case "table":
                    for case let row as [String: Any] in (element["rows"] as? [Any]) ?? [] {
                        let cells = flatText(row["cells"])
                        guard !cells.isEmpty else { continue }
                        let rowPage = int(row["page number"]) ?? page
                        blocks.append(Block(kind: .tableRow, text: cells.joined(separator: " | "), page: rowPage))
                        pagesWithText.insert(rowPage)
                    }
                    continue
                default:
                    break
                }
                walk(element["list items"])
                walk(element["kids"])
            }
        }
        walk(root["kids"])
        let pageCount = int(root["number of pages"]) ?? (blocks.map(\.page).max() ?? 0)
        return PDFStructure(title: usefulTitle(root["title"] as? String), pageCount: pageCount, blocks: blocks,
                            pagesWithoutText: (1...max(1, pageCount)).filter { !pagesWithText.contains($0) && pageCount > 0 })
    }

    // MARK: PDFKit fallback

    /// Plain text per page, with lines that repeat at the top or bottom of most pages (running
    /// headers, footers, page numbers) removed, words split by a line-end hyphen joined, and
    /// unbroken runs over 60 characters (embedded LaTeX/base64) dropped.
    public static func pdfKit(_ document: PDFDocument, maxPages: Int) -> PDFStructure {
        let count = min(document.pageCount, maxPages)
        var pages: [[String]] = []
        for i in 0..<count {
            let text = document.page(at: i)?.string ?? ""
            pages.append(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        let shape = { (line: String) in line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression) }
        // Lines a header or footer can occupy: two at each end of a full page, one on a short one
        // (whose middle is body text).
        let edgeLines = { (count: Int) in count >= 8 ? 2 : 1 }
        var edges: [String: Int] = [:]
        for lines in pages {
            let n = edgeLines(lines.count)
            for line in Set(lines.prefix(n) + lines.suffix(n)) { edges[shape(line), default: 0] += 1 }
        }
        let repeated = Set(edges.filter { $0.value >= max(3, count / 2) }.keys)

        var blocks: [Block] = []
        var withoutText: [Int] = []
        for (i, lines) in pages.enumerated() {
            let n = edgeLines(lines.count)
            let kept = lines.enumerated().filter { j, line in
                let edge = j < n || j >= lines.count - n
                return !(edge && repeated.contains(shape(line)))
            }.map(\.1)
            var paragraph = ""
            for line in kept {
                if paragraph.hasSuffix("-"), let first = line.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) {
                    paragraph.removeLast()
                    paragraph += line
                } else {
                    paragraph += paragraph.isEmpty ? line : " " + line
                }
            }
            let words: [Substring] = paragraph.split(separator: " ").filter { $0.count <= 60 }
            let text: String = words.joined(separator: " ")
            // A page number or a stray mark is not text; a short line is.
            if text.count < 10 {
                withoutText.append(i + 1)
            } else {
                blocks.append(Block(kind: .paragraph, text: text, page: i + 1))
            }
        }
        let title = usefulTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        return PDFStructure(title: title, pageCount: document.pageCount, blocks: blocks, pagesWithoutText: withoutText)
    }

    /// A metadata title that names the document (many are "Microsoft Word - x.docx", "untitled" or
    /// a file name).
    static func usefulTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = ItemText.clean(raw)
        let lower = title.lowercased()
        guard title.count >= 4, lower != "none", lower != "untitled", !lower.hasPrefix("microsoft"),
              !lower.hasSuffix(".pdf"), !lower.hasSuffix(".doc"), !lower.hasSuffix(".docx"), !lower.hasSuffix(".hwp"),
              !lower.hasSuffix(".pptx") else { return nil }
        return title
    }
}

/// Turns a `PDFStructure` into chunks for embedding: one card that says what the document is (title,
/// section headings, abstract or opening), then the body in pieces of about `size` characters, each
/// led by its section heading. References and bibliography sections are left out — they read like
/// every paper and match everything.
///
/// Chunks are filled close to `size`, because `maxChunks` caps how far into a long PDF the index
/// reaches: a heading starts a new chunk only once the current one is half full (a short section
/// shares it, its heading inline), and a block that does not fit fills the rest of the chunk
/// between words when at least `minSplit` characters are left. (Ending every chunk at a heading or
/// a block left opendataloader-pdf's chunks ~20% emptier and reached ~2 pages less of a paper.)
public enum PDFChunker {
    public struct Chunk: Sendable, Equatable {
        public var text: String
        public var page: Int
        public var isCard: Bool
    }

    static let skippedSections = ["references", "bibliography", "참고문헌", "참고 문헌", "acknowledgments", "acknowledgements", "감사의 글"]
    static let abstractHeadings = ["abstract", "초록", "요약", "summary", "개요"]
    /// Less room than this left in a chunk: the next block starts a new one instead of splitting.
    static let minSplit = 160

    public static func chunks(_ structure: PDFStructure, size: Int, maxChunks: Int) -> [Chunk] {
        guard maxChunks > 0, !structure.blocks.isEmpty else { return [] }
        var out: [Chunk] = []
        if let card = card(structure, size: size) { out.append(card) }

        var section: String?
        var skipping: Int?   // heading level of a skipped section
        var current = ""
        var currentPage = 1
        func flush() {
            if current.count >= 20 { out.append(Chunk(text: current, page: currentPage, isCard: false)) }
            current = ""
        }
        for block in structure.blocks {
            guard out.count < maxChunks else { break }
            if case .heading(let level) = block.kind {
                if let skipped = skipping, level > skipped { continue }
                skipping = nil
                let name = block.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                    .replacingOccurrences(of: "^[0-9ivx.]+\\s*", with: "", options: .regularExpression)
                if skippedSections.contains(name) {
                    flush()
                    skipping = level
                    continue
                }
                section = String(block.text.prefix(60))
                if current.count * 2 >= size || current.count + 1 + block.text.count > size {
                    flush()
                } else if !current.isEmpty {
                    current += " " + block.text
                }
                continue
            }
            if skipping != nil { continue }
            let prefix = section.map { "[\($0)] " } ?? ""
            for piece in pieces(block.text, size: size - prefix.count) {
                if current.isEmpty {
                    current = prefix + piece
                    currentPage = block.page
                    continue
                }
                let room = size - current.count - 1
                if piece.count <= room {
                    current += " " + piece
                    continue
                }
                var rest = piece
                if room >= minSplit {
                    let (head, tail) = split(piece, fitting: room)
                    if !head.isEmpty {
                        current += " " + head
                        rest = tail
                    }
                }
                flush()
                guard !rest.isEmpty else { continue }
                current = prefix + rest
                currentPage = block.page
            }
        }
        flush()
        return Array(out.prefix(maxChunks))
    }

    /// Title, section headings and the abstract (or the opening text), up to `size` characters.
    static func card(_ structure: PDFStructure, size: Int) -> Chunk? {
        var headings: [String] = []
        var seen = Set<String>()
        for block in structure.blocks {
            if case .heading = block.kind, block.text.count <= 80, seen.insert(block.text.lowercased()).inserted {
                headings.append(block.text)
            }
        }
        // Without a title or headings a card would only repeat the opening chunk.
        guard structure.title != nil || !headings.isEmpty else { return nil }
        let title = structure.title ?? headings.first
        var abstract = ""
        var inAbstract = false
        for block in structure.blocks {
            if case .heading = block.kind {
                if inAbstract { break }
                let name = block.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                inAbstract = abstractHeadings.contains(name)
                continue
            }
            if inAbstract { abstract += (abstract.isEmpty ? "" : " ") + block.text }
            if abstract.count > size { break }
        }
        if abstract.isEmpty {
            // No abstract: the first paragraphs.
            for block in structure.blocks where block.kind == .paragraph {
                abstract += (abstract.isEmpty ? "" : " ") + block.text
                if abstract.count > size / 2 { break }
            }
        }
        var parts: [String] = []
        if let title { parts.append(title) }
        let outline = headings.filter { $0 != title }.prefix(12).joined(separator: " · ")
        if !outline.isEmpty { parts.append(outline) }
        if !abstract.isEmpty { parts.append(abstract) }
        let text = String(parts.joined(separator: "\n").prefix(size))
        guard text.count >= 20 else { return nil }
        return Chunk(text: text, page: 1, isCard: true)
    }

    /// `text` in pieces of at most `size` characters, split between words.
    static func pieces(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        return FileContentExtractor.chunks(text, size: max(40, size))
    }

    /// The words of `text` that fit in `room` characters, and the rest (`head` is empty when the
    /// first word does not fit).
    static func split(_ text: String, fitting room: Int) -> (head: String, tail: String) {
        var length = 0
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text[index...].firstIndex(of: " ") ?? text.endIndex
            let wordLength = text[index..<next].count
            if length + (length > 0 ? 1 : 0) + wordLength > room { break }
            length += (length > 0 ? 1 : 0) + wordLength
            end = next
            index = next < text.endIndex ? text.index(after: next) : next
        }
        let tail = text[end...].drop { $0 == " " }
        return (String(text[..<end]), String(tail))
    }
}
