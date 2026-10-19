import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// What a file chunk was made from.
public enum ChunkKind: UInt8, Sendable, CaseIterable {
    /// A piece of a PDF's text.
    case text = 0
    /// Text recognized in an image (or in a PDF page without a text layer).
    case ocr = 1
    /// The image itself.
    case image = 2
    /// The first page of a PDF without a text layer, as an image.
    case pageImage = 3
    /// What a PDF is: its title, section headings and abstract (`PDFChunker`).
    case card = 4
}

/// What gets embedded for one file: text chunks and images, with their pages (1-based) in a PDF.
public struct FileContent: Sendable {
    public struct Text: Sendable {
        public var kind: ChunkKind
        public var text: String
        public var page: Int?
    }

    public struct Image: Sendable {
        public var kind: ChunkKind
        public var image: CGImage
        public var page: Int?
    }

    public var texts: [Text] = []
    public var images: [Image] = []
    /// Set when the file could not be read at all.
    public var error: String?
    /// Not readable right now (gone, on an offline volume, or only in iCloud): try again later
    /// instead of recording the file.
    public var unavailable = false

    public var isEmpty: Bool { texts.isEmpty && images.isEmpty }
}

/// Reads a file's content for embedding. Synchronous and thread-safe; run it off the main thread.
/// - PDFs: a `PDFStructure` — from opendataloader-pdf when the caller has one, else PDFKit's text
///   cleaned up — cut by `PDFChunker` into a card plus body chunks of about `chunkCharacters`, up to
///   `maxChunksPerPDF`; pages without text get text recognition (up to `maxOCRPages`), and a PDF
///   without any text also its first page as an image.
/// - Images: the picture, plus recognized text when there is some.
public struct FileContentExtractor: Sendable {
    /// Pages PDFKit reads when there is no structure from opendataloader-pdf.
    public var maxPages = 1000
    /// ~800 characters keep a chunk under ~1k tokens even for Korean, which bounds attention memory.
    public var chunkCharacters = 800
    /// ~38k characters: all of a typical paper or report (Downloads averaged ~45k with references).
    public var maxChunksPerPDF = 48
    public var maxOCRPages = 8
    /// Text recognition (Vision, ko + en) on images and scanned pages.
    public var recognizeText = true
    /// Longest side images are decoded to (the embedder resizes to its own budget anyway).
    public var maxImagePixels = 2048

    /// Part of every PDF's content hash: bumping it re-reads all PDFs (2: structure, all pages, cards).
    public static let pdfReadingVersion = "pdf2"

    public init() {}

    public func extract(path: String, structure: PDFStructure? = nil) -> FileContent {
        // PDFKit, ImageIO and Vision autorelease what they read, and GCD's global queues, where
        // `SearchEngine` reads files, drain no pool per block: without a pool each image's
        // buffers stayed until the worker thread ended (~5–7 MB per image, measured).
        autoreleasepool { read(path: path, structure: structure) }
    }

    private func read(path: String, structure: PDFStructure?) -> FileContent {
        let url = URL(filePath: path)
        if Self.isUnavailable(url) {
            var content = FileContent()
            content.unavailable = true
            content.error = "not available right now"
            return content
        }
        if FileScanner.isImage(path: path) { return extractImage(url) }
        return extractPDF(url, structure: structure)
    }

    /// Missing, unreadable, or an iCloud placeholder whose content is not on this Mac (reading it
    /// would download it).
    static func isUnavailable(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current
    }

    private func extractImage(_ url: URL) -> FileContent {
        var content = FileContent()
        guard let image = Self.decodeImage(url, maxPixels: maxImagePixels) else {
            content.error = "cannot decode image"
            return content
        }
        content.images.append(.init(kind: .image, image: image, page: nil))
        if recognizeText { content.texts += ocrChunks(image, page: nil) }
        return content
    }

    private func extractPDF(_ url: URL, structure given: PDFStructure?) -> FileContent {
        var content = FileContent()
        let structure: PDFStructure
        if let given {
            structure = given
        } else {
            guard let document = PDFDocument(url: url) else {
                content.error = "cannot open PDF"
                return content
            }
            guard !document.isLocked else {
                content.error = "PDF is password protected"
                return content
            }
            structure = PDFStructure.pdfKit(document, maxPages: maxPages)
        }
        let chunks = PDFChunker.chunks(structure, size: chunkCharacters, maxChunks: maxChunksPerPDF)
        content.texts = chunks.map { .init(kind: $0.isCard ? .card : .text, text: $0.text, page: $0.page) }
        // Scanned or picture-only pages: their text by recognition; a PDF without any text also
        // its first page as an image.
        if !structure.pagesWithoutText.isEmpty, let document = CGPDFDocument(url as CFURL) {
            if chunks.isEmpty, let first = Self.renderPage(document, number: 1, maxPixels: maxImagePixels) {
                content.images.append(.init(kind: .pageImage, image: first, page: 1))
            }
            if recognizeText {
                for number in structure.pagesWithoutText.prefix(maxOCRPages) {
                    guard let page = Self.renderPage(document, number: number, maxPixels: maxImagePixels) else { continue }
                    content.texts += ocrChunks(page, page: number)
                }
            }
        }
        if content.isEmpty { content.error = "no text or pages" }
        return content
    }

    private func ocrChunks(_ image: CGImage, page: Int?) -> [FileContent.Text] {
        let text = Self.recognizeText(image)
        guard text.count >= 10 else { return [] }
        return Self.chunks(text, size: chunkCharacters).prefix(2).map { .init(kind: .ocr, text: $0, page: page) }
    }

    // MARK: Helpers

    /// Whitespace-collapsed text in pieces of at most `size` characters, split between words (a
    /// longer word is cut). Pieces under 20 characters are dropped.
    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        var length = 0
        func flush() {
            if length >= 20 { out.append(current) }
            current = ""
            length = 0
        }
        for word in text.split(whereSeparator: \.isWhitespace) {
            var word = Substring(word)
            while !word.isEmpty {
                let n = word.count
                if length > 0 && length + 1 + n > size { flush() }
                if n > size {
                    current = String(word.prefix(size))
                    length = size
                    word = word.dropFirst(size)
                    flush()
                    continue
                }
                if length > 0 {
                    current += " "
                    length += 1
                }
                current += word
                length += n
                word = ""
            }
        }
        flush()
        return out
    }

    /// Decoded with EXIF orientation applied, at most `maxPixels` on the long side.
    static func decodeImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The first page on white, at most `maxPixels` on the long side.
    static func renderFirstPage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return renderPage(document, number: 1, maxPixels: maxPixels)
    }

    /// Page `number` (1-based) on white, at most `maxPixels` on the long side.
    static func renderPage(_ document: CGPDFDocument, number: Int, maxPixels: Int) -> CGImage? {
        guard let page = document.page(at: number) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixels) / max(box.width, box.height)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func recognizeText(_ image: CGImage) -> String {
        // A pool per page too, so a scanned PDF does not hold every page's buffers until it is done.
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
    }
}
