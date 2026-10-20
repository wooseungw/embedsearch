import Foundation
import PDFKit
import SearchCore

/// Excerpts for the result rows of PDFs found by their content: the page that matched, read again
/// (see `PageMatch`) only for the rows on screen, off the main thread, and remembered.
@MainActor
final class PageExcerpts {
    static let shared = PageExcerpts()

    struct Key: Hashable {
        let path: String
        /// The item's size and modification time (`FileScanner`): a changed file is read again.
        let version: String
        let page: Int
        let words: [String]
    }

    private var cache: [Key: PageMatch.Excerpt] = [:]
    /// Reads under way: a row that asks again (results for the same query twice) waits for them.
    private var reading: [Key: Task<PageMatch.Excerpt, Never>] = [:]
    /// Excerpts are a few hundred bytes; this many cover several screens of results.
    private let capacity = 256

    /// The key for `result` under `query`, or nil when it is not a PDF page match.
    static func key(for result: SearchResult, query: String) -> Key? {
        guard result.item.kind == .file, let page = result.breakdown.page,
              case .openFile(let path) = result.item.action, !FileScanner.isImage(path: path) else { return nil }
        return Key(path: path, version: result.item.embeddingText, page: page, words: PageMatch.words(query))
    }

    func cached(_ key: Key) -> PageMatch.Excerpt? { cache[key] }

    func excerpt(_ key: Key) async -> PageMatch.Excerpt {
        if let hit = cache[key] { return hit }
        if let read = reading[key] { return await read.value }
        let read = Task.detached(priority: .userInitiated) {
            // PDFKit autoreleases what it reads, and these threads drain no pool per task.
            autoreleasepool {
                guard PageMatch.isLocal(key.path), let document = PDFDocument(url: URL(filePath: key.path)),
                      !document.isLocked else {
                    return PageMatch.Excerpt(page: key.page)
                }
                return PageMatch.excerpt(in: document, words: key.words, from: key.page)
            }
        }
        reading[key] = read
        let excerpt = await read.value
        reading[key] = nil
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = excerpt
        return excerpt
    }
}
