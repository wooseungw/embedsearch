import CoreGraphics
import CoreServices
import CoreText
import EmbedCore
import Foundation
import ImageIO
import Testing
@testable import SearchCore

/// Returns, for every image, the n-gram vector of a fixed label: a query near the label finds images.
/// Image calls fail as configured: the first `failFirst`, or all of them.
final class FakeImageEmbedder: ImageEmbedder, @unchecked Sendable {
    let info: EmbeddingModelInfo
    private let text: FakeEmbedder
    private let label: String
    private let failFirst: Int
    private let lock = NSLock()
    private var _calls = 0
    private var _failAll: Bool

    init(text: FakeEmbedder, label: String, failFirst: Int = 0, failAll: Bool = false) {
        self.info = text.info
        self.text = text
        self.label = label
        self.failFirst = failFirst
        self._failAll = failAll
    }

    var calls: Int { lock.withLock { _calls } }
    var failAll: Bool {
        get { lock.withLock { _failAll } }
        set { lock.withLock { _failAll = newValue } }
    }

    func embed(images: [ImageInput]) async throws -> [[Float]] {
        let call = lock.withLock {
            _calls += 1
            return (_calls, _failAll)
        }
        if call.1 || call.0 <= failFirst { throw FakeEmbedder.FakeError.boom }
        return images.map { _ in text.vector(label) }
    }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        try await text.embed(inputs)
    }
}

/// A fresh temporary folder, removed by `cleanUp()`.
struct TempFolder {
    /// Under /var, a symlink to /private/var: files must still be reported under this path.
    let url = FileManager.default.temporaryDirectory.appending(path: "filesearch-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appending(path: name) }

    func writePNG(_ name: String, gray: CGFloat = 0.3) throws {
        let file = path(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// One page per string; an empty string makes a page without text (a grey square).
    func writePDF(_ name: String, pages: [String]) throws {
        let file = path(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(file as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if text.isEmpty {
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
            } else {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                     CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
                CTFrameDraw(frame, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    func touch(_ name: String, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)],
                                              ofItemAtPath: path(name).path(percentEncoded: false))
    }
}

@Suite("File scanning and content")
struct FileScanningTests {
    @Test func scannerListsImagesAndPDFsOnly() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("사진.png")
        try folder.writePDF("docs/report.pdf", pages: ["hello"])
        try "notes".write(to: folder.path("notes.txt"), atomically: true, encoding: .utf8)
        try folder.writePNG(".hidden.png")

        let scan = FileScanner(folders: [folder.url]).scan()
        #expect(scan.failedFolders.isEmpty)
        let titles = scan.items.map(\.title).sorted()
        #expect(titles == ["report.pdf", "사진.png"])
        let report = try #require(scan.items.first { $0.title == "report.pdf" })
        #expect(report.kind == .file)
        #expect(report.id == "file:" + folder.path("docs/report.pdf").path(percentEncoded: false))
        #expect(report.keywords == ["report"])
        #expect(report.action == .openFile(path: folder.path("docs/report.pdf").path(percentEncoded: false)))
        #expect(report.title == report.title.precomposedStringWithCanonicalMapping)
    }

    @Test func modifiedFileGetsANewContentHash() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("a.pdf", pages: ["first"])
        try folder.touch("a.pdf", secondsAgo: 100)
        let before = try #require(FileScanner(folders: [folder.url]).scan().items.first)
        try folder.touch("a.pdf", secondsAgo: 50)
        let after = try #require(FileScanner(folders: [folder.url]).scan().items.first)
        #expect(before.id == after.id)
        #expect(IndexStore.contentHash(before) != IndexStore.contentHash(after))
    }

    @Test func unreadableFolderIsReported() {
        let scan = FileScanner(folders: [URL(filePath: "/nonexistent-\(UUID().uuidString)")]).scan()
        #expect(scan.items.isEmpty)
        #expect(scan.failedFolders.count == 1)
    }

    @Test func nestedFoldersAreMerged() {
        let folders = FileScanner.normalized([URL(filePath: "/a/b/"), URL(filePath: "/a"), URL(filePath: "/ab"), URL(filePath: "/a/")])
        #expect(folders.map { $0.path(percentEncoded: false) } == ["/a/", "/ab/"])
    }

    @Test func chunksSplitBetweenWords() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
        let chunks = FileContentExtractor.chunks(text, size: 24)
        #expect(chunks.allSatisfy { $0.count <= 24 && $0.count >= 20 })
        #expect(chunks.joined(separator: " ").hasPrefix("alpha beta gamma delta"))
        #expect(FileContentExtractor.chunks(String(repeating: "x", count: 50), size: 24) == [String(repeating: "x", count: 24), String(repeating: "x", count: 24)])
        #expect(FileContentExtractor.chunks("too short", size: 24).isEmpty)
    }

    @Test func pdfTextIsChunkedAndScansBecomeImages() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("text.pdf", pages: ["Train ticket from Seoul to Busan, departure nine thirty", "Seat 12A, car 5"])
        try folder.writePDF("scan.pdf", pages: [""])
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        let text = extractor.extract(path: folder.path("text.pdf").path(percentEncoded: false))
        #expect(text.error == nil)
        #expect(text.images.isEmpty)
        #expect(text.texts.map(\.kind) == [.text])
        #expect(text.texts[0].text.contains("Seoul to Busan"))
        #expect(text.texts[0].text.contains("Seat 12A"))

        let scan = extractor.extract(path: folder.path("scan.pdf").path(percentEncoded: false))
        #expect(scan.texts.isEmpty)
        #expect(scan.images.map(\.kind) == [.pageImage])
        #expect(scan.images[0].image.width == 2048 || scan.images[0].image.height == 2048)
    }

    @Test func missingFileIsUnavailableNotFailed() {
        let content = FileContentExtractor().extract(path: "/nonexistent-\(UUID().uuidString).pdf")
        #expect(content.unavailable)
    }

    @Test func unreadableFileReportsAnError() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try "not a pdf".write(to: folder.path("broken.pdf"), atomically: true, encoding: .utf8)
        try "not an image".write(to: folder.path("broken.png"), atomically: true, encoding: .utf8)
        let extractor = FileContentExtractor()
        #expect(extractor.extract(path: folder.path("broken.pdf").path(percentEncoded: false)).error != nil)
        #expect(extractor.extract(path: folder.path("broken.png").path(percentEncoded: false)).error != nil)
    }
}

@Suite("Folder watching")
struct FolderWatcherTests {
    @Test func reportsImageAndPDFChangesOnly() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let changes = Counter()
        let watcher = try #require(FolderWatcher(folders: [folder.url], latency: 0.2) { changes.increment() })
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(to: folder.path("notes.txt"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .seconds(1.5))
        #expect(changes.count == 0)
        try folder.writePNG("new.png")
        for _ in 0..<50 where changes.count == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(changes.count >= 1)
    }

    @Test func classifiesEvents() {
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
        let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        #expect(FolderWatcher.matters(path: "/a/b.PDF", flags: file))
        #expect(FolderWatcher.matters(path: "/a/b.heic", flags: file))
        #expect(!FolderWatcher.matters(path: "/a/.DS_Store", flags: file))
        #expect(!FolderWatcher.matters(path: "/a/b.pdf.crdownload", flags: file))
        #expect(FolderWatcher.matters(path: "/a/sub", flags: dir))
        #expect(!FolderWatcher.matters(path: "/a/sub", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemXattrMod)))
        #expect(!FolderWatcher.matters(path: "/a/.git/x.png", flags: file, roots: ["/a"]))
        #expect(!FolderWatcher.matters(path: "/a/Photos Library.photoslibrary/resources/x.jpeg", flags: file, roots: ["/a"]))
        #expect(!FolderWatcher.matters(path: "/a/Big.app", flags: dir, roots: ["/a"]))
        #expect(FolderWatcher.matters(path: "/a/v1.2/x.png", flags: file, roots: ["/a"]))
        #expect(!FolderWatcher.matters(path: "/a", flags: dir, roots: ["/a"]))
        #expect(FolderWatcher.matters(path: "/a", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged), roots: ["/a"]))
    }
}

/// Thread-safe counter for callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Chunk index and storage")
struct ChunkIndexTests {
    @Test func bestChunkMinusHubDecides() {
        var index = ChunkIndex(dimensions: 4)
        index.append(itemID: "a", kind: .text, hub: 0.5, vector: [1, 0, 0, 0])
        index.append(itemID: "a", kind: .text, hub: 0, vector: [0, 0, 1, 0])
        index.append(itemID: "b", kind: .image, hub: 0, vector: [0.8, 0.6, 0, 0])
        #expect(index.rowCount == 3)
        #expect(index.itemCount == 2)
        #expect(index.chunkCount(of: "a") == 2)

        let penalized = index.search([1, 0, 0, 0], k: 5, hubWeight: 1)
        #expect(penalized.map(\.itemID) == ["b", "a"])
        #expect(penalized[0].kind == .image)
        #expect(abs(penalized[0].cosine - 0.8) < 1e-3)
        #expect(abs(penalized[1].score - 0.5) < 1e-3)

        let raw = index.search([1, 0, 0, 0], k: 1, hubWeight: 0)
        #expect(raw.map(\.itemID) == ["a"])

        index.removeAll { $0 == "a" }
        #expect(index.rowCount == 1)
        #expect(index.search([1, 0, 0, 0], k: 5, hubWeight: 1).map(\.itemID) == ["b"])
    }

    @Test func scoringSpansSeveralBlocks() {
        var index = ChunkIndex(dimensions: 2)
        for i in 0..<(ChunkIndex.block * 2 + 7) {
            let angle = Float(i) / Float(ChunkIndex.block * 3)
            index.append(itemID: "i\(i % 1000)", kind: .text, hub: 0, vector: [cos(angle), sin(angle)])
        }
        let hits = index.search([1, 0], k: 3, hubWeight: 0)
        #expect(hits.map(\.itemID) == ["i0", "i1", "i2"])
    }

    @Test func reservedAndShrunkCapacityFollowsTheRows() {
        let d = 64
        func vector(_ i: Int) -> [Float] {
            var v = [Float](repeating: 0, count: d)
            v[i % d] = 1
            v[(i + 3) % d] = Float(i % 7) / 7
            return VectorMath.normalized(v)
        }
        /// What an array reserved for exactly `rows` rows holds (malloc rounds sizes up).
        func exactBytes(rows: Int) -> Int {
            var probe: [UInt16] = []
            probe.reserveCapacity(rows * d)
            return probe.capacity * MemoryLayout<UInt16>.size
        }
        // Reserved up front: the rows fit without the arrays doubling.
        var reserved = ChunkIndex(dimensions: d)
        reserved.reserveCapacity(forAdditionalRows: 3000)
        for i in 0..<3000 { reserved.append(itemID: "i\(i % 900)", kind: .text, hub: 0.01 * Float(i % 5), page: i % 4, vector: vector(i)) }
        #expect(reserved.vectorCapacityBytes == exactBytes(rows: 3000))

        // Grown one append at a time, then a third removed: shrinking gives the spare room back
        // and changes no result.
        var grown = ChunkIndex(dimensions: d)
        for i in 0..<3000 { grown.append(itemID: "i\(i % 900)", kind: .text, hub: 0.01 * Float(i % 5), page: i % 4, vector: vector(i)) }
        grown.removeAll { $0.hasSuffix("1") || $0.hasSuffix("5") || $0.hasSuffix("7") }
        let query = vector(11)
        let before = grown.search(query, k: 20, hubWeight: 0.3)
        let rows = grown.rowCount
        #expect(grown.vectorCapacityBytes > exactBytes(rows: rows) * 9 / 8)
        grown.shrinkToFit()
        #expect(grown.rowCount == rows)
        #expect(grown.vectorCapacityBytes == exactBytes(rows: rows))
        #expect(grown.search(query, k: 20, hubWeight: 0.3) == before)
        grown.shrinkToFit()  // nothing to give back: no copy, same results
        #expect(grown.search(query, k: 20, hubWeight: 0.3) == before)
        let unique = VectorMath.normalized([Float](repeating: 1, count: d))
        grown.append(itemID: "new", kind: .image, hub: 0, vector: unique)
        #expect(grown.search(unique, k: 1, hubWeight: 0).first?.itemID == "new")
    }

    @Test func storeRoundTripsAndPrunesFileChunks() throws {
        let store = try IndexStore.inMemory()
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        try store.saveFileChunks([
            (a, FileIndexRecord(chunks: 2), [FileChunk(kind: .text, hub: 0.25, vector: [1, 0, 0, 0]),
                                            FileChunk(kind: .ocr, hub: 0.5, vector: [0, 1, 0, 0])]),
            (b, FileIndexRecord(chunks: 0, partial: true, error: "cannot decode image"), []),
        ], modelKey: "m")
        let records = try store.fileIndexRecords(modelKey: "m")
        #expect(records[a] == FileIndexRecord(chunks: 2))
        #expect(records[b] == FileIndexRecord(chunks: 0, partial: true, error: "cannot decode image"))

        var rows: [(String, ChunkKind, Float, [Float])] = []
        try store.forEachFileChunk(hashes: [a, b], modelKey: "m", dimensions: 4) { hash, kind, hub, _, bytes in
            rows.append((hash, kind, hub, IndexStore.floats(float16: Data(bytes))))
        }
        #expect(rows.map(\.1) == [.text, .ocr])
        #expect(rows.map(\.2) == [0.25, 0.5])
        #expect(rows[1].3 == [0, 1, 0, 0])
        #expect(try store.fileChunkBytes() == 16)

        #expect(try store.pruneFileIndex(keeping: [a], modelKey: "m") == 1)
        #expect(try store.fileIndexRecords(modelKey: "m").keys.sorted() == [a])
        try store.saveEmbeddings([a: [1, 0, 0, 0]], modelKey: "other")
        try store.pruneOtherModels(keeping: "other")
        #expect(try store.fileIndexRecords(modelKey: "m").isEmpty)
        #expect(try store.fileChunkBytes() == 0)
    }
}

@Suite("File search in the engine")
struct FileEngineTests {
    private func makeEngine(_ store: IndexStore, _ embedder: any TextEmbedder, images: FakeImageEmbedder?,
                            folder: TempFolder, now: @escaping @Sendable () -> Date = { Date() }) async -> SearchEngine {
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems)], now: now)
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        await engine.setFileContentExtractor(extractor)
        await engine.setFileFolders([folder.url])
        await engine.setImageEmbedder(images)
        return engine
    }

    @Test func filesAreIndexedSearchedAndKeptInSync() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("doc1.pdf", pages: ["Coffee receipt, americano and latte, total 9500 won, paid by card"])
        try folder.writePNG("IMG_0001.png")
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let images = FakeImageEmbedder(text: embedder, label: "sunset over the ocean beach")
        let engine = await makeEngine(store, embedder, images: images, folder: folder)

        let first = await engine.refreshWithStats()
        #expect(first.filesIndexed == 2)
        #expect(first.fileErrors == 0)
        #expect(first.fileChunks == 2)
        #expect(images.calls == 1)

        let receipt = try await engine.fullSearch("coffee receipt", limit: 5)
        #expect(receipt.first?.item.title == "doc1.pdf")
        #expect(receipt.first?.signals.contains(.semantic) == true)
        let beach = try await engine.fullSearch("ocean beach sunset", limit: 5)
        #expect(beach.first?.item.title == "IMG_0001.png")
        // Files do not crowd out items: an app query still finds the app first.
        let calculator = try await engine.fullSearch("계산기", limit: 5)
        #expect(calculator.first?.item.id == "app:com.apple.calculator")

        // Unchanged files are not read again.
        let second = await engine.refreshWithStats()
        #expect(second.filesIndexed == 0)

        // A changed file is re-indexed; a deleted one leaves the index and the store.
        try folder.writePDF("doc1.pdf", pages: ["Train ticket from Seoul to Busan, KTX, seat 12A"])
        try folder.touch("doc1.pdf", secondsAgo: 5)
        try FileManager.default.removeItem(at: folder.path("IMG_0001.png"))
        let third = await engine.refreshWithStats()
        #expect(third.filesIndexed == 1)
        #expect(third.fileChunks == 1)
        let ticket = try await engine.fullSearch("train ticket busan", limit: 5)
        #expect(ticket.first?.item.title == "doc1.pdf")
        #expect(try await engine.fullSearch("ocean beach sunset", limit: 5).allSatisfy { $0.item.title != "IMG_0001.png" })
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).count == 1)

        let summary = await engine.fileIndexSummary()
        #expect(summary.folders.count == 1)
        let entry = summary.folders[0]
        #expect(entry.documents == 1 && entry.images == 0)
        #expect(entry.indexed == 1 && entry.pending == 0 && entry.chunks == 1)
        #expect(entry.bytes == FileIndexCost.bytesPerFile + FileIndexCost.bytesPerChunk(dimensions: 64))
        #expect(entry.estimatedBytes == entry.bytes)

        // Removing the folder removes its files.
        await engine.setFileFolders([])
        await engine.refresh()
        #expect(await engine.allItems().allSatisfy { $0.kind != .file })
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).isEmpty)
    }

    @Test func warmStartServesFilesWithoutTheModel() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("trip.pdf", pages: ["Hotel booking in Jeju, check in Friday, two nights"])
        let store = try IndexStore.inMemory()
        let first = await makeEngine(store, FakeEmbedder(), images: nil, folder: folder)
        await first.refresh()

        let embedder = FakeEmbedder()
        let engine = await makeEngine(store, embedder, images: nil, folder: folder)
        await engine.loadFromStore()
        #expect(await engine.fileChunkCount == 1)
        #expect(embedder.calls == 0)
        let hits = try await engine.fullSearch("jeju hotel booking", limit: 3)
        #expect(hits.first?.item.title == "trip.pdf")
    }

    @Test func imagesSkippedWithoutAnImageEmbedderAreRedoneLater() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("photo.png")
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let engine = await makeEngine(store, embedder, images: nil, folder: folder)
        let first = await engine.refreshWithStats()
        #expect(first.filesIndexed == 1)
        #expect(first.fileChunks == 0)
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values.first?.partial == true)

        let images = FakeImageEmbedder(text: embedder, label: "mountain")
        await engine.setImageEmbedder(images)
        let second = await engine.refreshWithStats()
        #expect(second.filesIndexed == 1)
        #expect(second.fileChunks == 1)
        #expect(images.calls == 1)
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values.first?.partial == false)
    }

    @Test func aTransientImageFailureIsRetriedWithoutReembeddingSuccessfulFiles() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        for name in ["a", "b", "c", "d"] { try folder.writePNG("\(name).png") }
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        // One failed image must not be classified as permanently broken because others worked.
        let images = FakeImageEmbedder(text: embedder, label: "x", failFirst: 1)
        let engine = await makeEngine(store, embedder, images: images, folder: folder)
        await engine.setImageRetryInterval(.zero)
        let first = await engine.refreshWithStats()
        #expect(first.filesIndexed == 4 && first.fileChunks == 3)
        let records = try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values
        #expect(records.filter { $0.error != nil && $0.retryable && $0.retryCount == 1 }.count == 1)
        await engine.refresh()
        #expect(images.calls == 5)
        #expect(await engine.fileChunkCount == 4)
    }

    @Test func aFailingVisionModelIsRetriedAfterItsCooldown() async throws {
        let clock = TestClock()
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        for name in ["a", "b", "c", "d"] { try folder.writePNG("\(name).png") }
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let images = FakeImageEmbedder(text: embedder, label: "x", failAll: true)
        let engine = await makeEngine(store, embedder, images: images, folder: folder, now: { clock.now() })
        await engine.refresh()
        // Given up after three failures in a row: every file waits for its images.
        #expect(images.calls == 3)
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values.allSatisfy(\.partial))
        await engine.refresh()
        #expect(images.calls == 3)  // still cooling down

        images.failAll = false
        clock.advance(601)
        await engine.setImageRetryInterval(.zero)
        await engine.setImageEmbedder(images)
        let retried = await engine.refreshWithStats()
        #expect(retried.filesIndexed == 4 && retried.fileChunks == 4)
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values.allSatisfy { !$0.partial })
    }

    @Test func aFileWhoseTextFailsDoesNotHoldUpTheOthers() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("good.pdf", pages: ["Quarterly sales report for the northern region"])
        try folder.writePDF("bad.pdf", pages: ["POISON text that the embedder rejects every time"])
        let store = try IndexStore.inMemory()
        let embedder = PoisonEmbedder()
        let engine = await makeEngine(store, embedder, images: nil, folder: folder)
        let stats = await engine.refreshWithStats()
        #expect(stats.embeddingError == nil)
        #expect(stats.filesIndexed == 2 && stats.fileErrors == 1 && stats.fileChunks == 1)
        #expect(await engine.currentState == EngineState.ready(itemCount: fixtureItems.count + 2))
        let hits = try await engine.fullSearch("quarterly sales report", limit: 5)
        #expect(hits.contains { $0.item.title == "good.pdf" })
    }

    @Test func installingTheEmbedderDuringARefreshEmbedsOnce() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("a.png")
        try folder.writePNG("b.png")
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let images = FakeImageEmbedder(text: embedder, label: "x")
        let engine = SearchEngine(store: store, embedder: nil, sources: [StaticItemSource(items: fixtureItems)])
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        await engine.setFileContentExtractor(extractor)
        await engine.setFileFolders([folder.url])
        await engine.setImageEmbedder(images)
        await engine.refresh()
        async let install: Void = engine.setEmbedder(embedder)
        async let refresh: Void = engine.refresh()
        _ = await (install, refresh)
        #expect(images.calls == 2)
        #expect(await engine.fileChunkCount == 2)
    }

    @Test func estimateCountsFilesBeforeIndexing() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("a.png")
        try folder.writePNG("b.png")
        try folder.writePDF("c.pdf", pages: ["x"])
        let estimate = FileIndexSummary.estimate(folder: folder.url, dimensions: 768)
        #expect(estimate.images == 2 && estimate.documents == 1)
        #expect(estimate.pending == 3 && estimate.indexed == 0 && estimate.bytes == 3 * FileIndexCost.bytesPerFile)
        let chunkBytes = Double(FileIndexCost.bytesPerChunk(dimensions: 768))
        let expected = 3 * FileIndexCost.bytesPerFile + 2 * Int(FileIndexCost.defaultImageChunks * chunkBytes)
            + Int(FileIndexCost.defaultDocumentChunks * chunkBytes)
        #expect(estimate.estimatedBytes == expected)
        #expect(estimate.pendingSeconds > 0)
    }

    @Test func rankerFusesFileMatchesAsTheirOwnList() {
        let analysis = QueryAnalyzer.analyze("x")
        let kinds: [String: ItemKind] = ["app": .application, "file": .file]
        let input = HybridRanker.Input(analysis: analysis, lexical: [],
                                       semantic: [.init(itemID: "app", cosine: 0.6)],
                                       fileSemantic: [.init(itemID: "file", cosine: 0.7)], kinds: kinds)
        let hybrid = HybridRanker.rank(input, mode: .hybrid, config: .default, limit: 10)
        #expect(Set(hybrid.map(\.itemID)) == ["app", "file"])
        #expect(hybrid.first { $0.itemID == "file" }?.signals == [.semantic])
        #expect(HybridRanker.rank(input, mode: .semantic, config: .default, limit: 10).map(\.itemID) == ["app"])
        #expect(HybridRanker.rank(input, mode: .lexical, config: .default, limit: 10).isEmpty)
    }

    @Test func looseSettingsMoveBelowFiles() {
        func result(_ id: String, _ kind: ItemKind, lexical: Double?) -> SearchResult {
            SearchResult(item: makeItem(id, kind, title: id), score: 0, signals: lexical == nil ? [.semantic] : [.lexical],
                         breakdown: ScoreBreakdown(lexicalScore: lexical))
        }
        let results = [result("loose", .systemSetting, lexical: 0.4), result("file", .file, lexical: nil),
                       result("app", .application, lexical: 0.9), result("named", .systemSetting, lexical: 0.82),
                       result("semantic", .systemSetting, lexical: nil)]
        let arranged = ResultSections.arrange(results, analysis: QueryAnalyzer.analyze("음식 사진"), config: .default)
        #expect(arranged.map(\.id) == ["file", "app", "named", "loose", "semantic"])
        #expect(arranged.map(\.section) == [.main, .main, .main, .settings, .settings])
        // Asking for settings, or no files among the results: the ranking stands.
        #expect(ResultSections.arrange(results, analysis: QueryAnalyzer.analyze("사진 설정"), config: .default) == results)
        let noFiles = results.filter { $0.item.kind != .file }
        #expect(ResultSections.arrange(noFiles, analysis: QueryAnalyzer.analyze("음식 사진"), config: .default) == noFiles)
    }

    @Test func looseNameOnlyFileMatchesAreDropped() {
        func file(_ id: String, lexical: Double?, semantic: Bool) -> SearchResult {
            SearchResult(item: makeItem(id, .file, title: id), score: 0, signals: semantic ? [.semantic] : [.lexical],
                         breakdown: ScoreBreakdown(lexicalScore: lexical))
        }
        let results = [file("initials", lexical: 0.41, semantic: false), file("named", lexical: 0.58, semantic: false),
                       file("content", lexical: 0.2, semantic: true)]
        let arranged = ResultSections.arrange(results, analysis: QueryAnalyzer.analyze("사진"), config: .default)
        #expect(arranged.map(\.id) == ["named", "content"])
    }

    @Test func engineListsLooseSettingsAfterFiles() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("dinner.pdf", pages: ["Photo album of the family dinner, food pictures from the restaurant"])
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let settings = [makeItem("setting:photos-privacy", .systemSetting, title: "응용 프로그램이 사진에 접근하는 것을 허용",
                                 text: "photos privacy access dinner food album")]
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems + settings)])
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        await engine.setFileContentExtractor(extractor)
        await engine.setFileFolders([folder.url])
        await engine.refresh()
        let results = try await engine.fullSearch("dinner 사진", limit: 20)
        let file = try #require(results.firstIndex { $0.item.title == "dinner.pdf" })
        let setting = try #require(results.firstIndex { $0.id == "setting:photos-privacy" })
        #expect(file < setting)
        #expect(results[setting].section == .settings)
        #expect(results[file].section == .main)
    }

    @Test func anAppNamedExactlyLikeTheQueryComesFirst() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("스크린샷 2026-07-07.png")
        let app = SearchItem(id: "app:screenshot", kind: .application, title: "스크린샷", subtitle: "Screenshot",
                             keywords: ["스크린샷", "Screenshot", "캡처"], embeddingTitle: "스크린샷",
                             embeddingText: "스크린샷 (Screenshot) · macOS 앱", action: .openApplication(path: "/Applications/Utilities/Screenshot.app"),
                             icon: .systemSymbol("camera"))
        let store = try IndexStore.inMemory()
        let embedder = FakeEmbedder()
        let images = FakeImageEmbedder(text: embedder, label: "스크린샷 화면 캡처")
        let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: fixtureItems + [app])])
        var extractor = FileContentExtractor()
        extractor.recognizeText = false
        await engine.setFileContentExtractor(extractor)
        await engine.setFileFolders([folder.url])
        await engine.setImageEmbedder(images)
        await engine.refresh()
        for query in ["스크린샷", "screenshot", "Screenshot"] {
            #expect(try await engine.fullSearch(query, limit: 5).first?.id == "app:screenshot", "\(query)")
            #expect(await engine.instantSearch(query, limit: 5).first?.id == "app:screenshot", "\(query)")
        }
        // An alias is not a name: "캡처" ranks as usual.
        let alias = try await engine.fullSearch("캡처", limit: 5)
        #expect(alias.contains { $0.id == "app:screenshot" })
    }

    @Test func clearFileMatchOutranksVagueItemMatch() {
        let analysis = QueryAnalyzer.analyze("영수증")
        let kinds: [String: ItemKind] = ["app": .application, "file": .file]
        func ranked(fileScore: Double) -> [String] {
            let input = HybridRanker.Input(analysis: analysis, lexical: [], semantic: [.init(itemID: "app", cosine: 0.4)],
                                           fileSemantic: [.init(itemID: "file", cosine: 0.7, score: fileScore)], kinds: kinds)
            return HybridRanker.rank(input, mode: .hybrid, config: .default, limit: 10).map(\.itemID)
        }
        #expect(ranked(fileScore: 0.25) == ["file", "app"])
        // Just past the threshold, the app's kind prior still wins.
        #expect(ranked(fileScore: RankingConfig.default.minFileScore) == ["app", "file"])
    }
}

/// `FakeEmbedder` that rejects any batch containing "POISON", like a model that fails on one input.
final class PoisonEmbedder: TextEmbedder, @unchecked Sendable {
    private let base = FakeEmbedder()
    var info: EmbeddingModelInfo { base.info }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        for input in inputs {
            if case .document(_, let text) = input, text.contains("POISON") { throw FakeEmbedder.FakeError.boom }
        }
        return try await base.embed(inputs)
    }
}

extension FileEngineTests {
    @Test func retriesAreBoundedAndAForcedRebuildCanRecover() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("retry.png")
        let store = try IndexStore.inMemory(), text = FakeEmbedder()
        let images = FakeImageEmbedder(text: text, label: "mountain", failAll: true)
        let engine = await makeEngine(store, text, images: images, folder: folder)
        await engine.setImageRetryInterval(.zero)
        for _ in 0..<7 { await engine.refresh() }
        #expect(images.calls == 3)
        #expect(try store.fileIndexRecords(modelKey: text.info.cacheKey).values.first?.retryCount == 3)
        images.failAll = false
        try await engine.reindexFiles(in: folder.url)
        #expect(images.calls == 4)
        #expect(await engine.fileChunkCount == 1)
        #expect(try store.fileIndexRecords(modelKey: text.info.cacheKey).values.first?.retryable == false)
    }

    @Test func retryDeadlineSurvivesReopeningTheStore() async throws {
        let folder = try TempFolder(), clock = TestClock()
        defer { folder.cleanUp() }
        try folder.writePNG("retry.png")
        try folder.writePNG("normal.png")
        let url = folder.path("index.sqlite"), text = FakeEmbedder()
        let store = try IndexStore(url: url)
        let images = FakeImageEmbedder(text: text, label: "mountain", failFirst: 1)
        let first = await makeEngine(store, text, images: images, folder: folder, now: { clock.now() })
        await first.refresh()
        let reopened = try IndexStore(url: url)
        let next = await makeEngine(reopened, text, images: images, folder: folder, now: { clock.now() })
        await next.loadFromStore()
        await next.refresh()
        #expect(images.calls == 2)
        clock.advance(601)
        await next.refresh()
        #expect(images.calls == 3)
        #expect(await next.fileChunkCount == 2)
    }

    @Test func unreadablePDFAwaitsExplicitRebuildInsteadOfRetryingForever() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try Data("not a PDF".utf8).write(to: folder.path("broken.pdf"))
        let store = try IndexStore.inMemory(), text = FakeEmbedder()
        let engine = await makeEngine(store, text, images: nil, folder: folder)
        let first = await engine.refreshWithStats()
        let second = await engine.refreshWithStats()
        #expect(first.fileErrors == 1 && second.filesIndexed == 0)
        #expect(try store.fileIndexRecords(modelKey: text.info.cacheKey).values.first?.retryable == false)
        try await engine.reindexFiles(in: folder.url)
        #expect(await engine.fileIndexSummary().folders.first?.failed == 1)
    }
}

extension FileEngineTests {
    @Test func allFailedTextFilesStillHavePersistentRetryState() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePDF("bad.pdf", pages: ["POISON content that currently cannot be embedded"])
        let store = try IndexStore.inMemory(), embedder = PoisonEmbedder()
        let engine = await makeEngine(store, embedder, images: nil, folder: folder)
        let stats = await engine.refreshWithStats()
        #expect(stats.filesIndexed == 1)
        #expect(try store.fileIndexRecords(modelKey: embedder.info.cacheKey).values.first?.retryable == true)
    }

    @Test func aTransientImageRetriesWithoutAnotherFileEvent() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("retry.png")
        let store = try IndexStore.inMemory(), text = FakeEmbedder()
        let images = FakeImageEmbedder(text: text, label: "mountain", failFirst: 1)
        let engine = await makeEngine(store, text, images: images, folder: folder)
        await engine.setImageRetryInterval(.milliseconds(50))
        await engine.refresh()
        let deadline = ContinuousClock.now + .seconds(4)
        while await engine.fileChunkCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await engine.fileChunkCount == 1)
        #expect(images.calls == 2)
    }
}

extension FileEngineTests {
    @Test func forceReindexUpdatesAllAliasesOfASharedFileVersion() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.writePNG("one/shared.png")
        try folder.writePNG("two/shared.png")
        for name in ["one/shared.png", "two/shared.png"] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: folder.path(name).path)
        }
        let store = try IndexStore.inMemory(), text = FakeEmbedder()
        let first = FakeImageEmbedder(text: text, label: "mountain")
        let engine = await makeEngine(store, text, images: first, folder: folder)
        await engine.refresh()
        #expect(first.calls == 1)
        await engine.setImageEmbedder(FakeImageEmbedder(text: text, label: "beach"))
        try await engine.reindexFiles(in: folder.path("one"))
        let found = try await engine.fullSearch("beach", limit: 50).filter { $0.item.kind == .file }
        #expect(found.count == 2)
        #expect(found.allSatisfy { ($0.breakdown.cosine ?? 0) > 0.99 })
    }
}
