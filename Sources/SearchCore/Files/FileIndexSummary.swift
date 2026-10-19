import Foundation

/// Per-folder state of file search: what is indexed, what is pending, the disk space it takes and
/// what the pending files are expected to add.
public struct FileIndexSummary: Sendable, Equatable {
    public struct Folder: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var images = 0
        public var documents = 0
        /// Files whose content is embedded (`failed` of them had none that could be read).
        public var indexed = 0
        public var failed = 0
        public var pending = 0
        public var chunks = 0
        /// Bytes this folder takes in the database now.
        public var bytes = 0
        /// Bytes once every pending file is indexed (estimate).
        public var estimatedBytes = 0
        /// Time to index the pending files (estimate).
        public var pendingSeconds = 0.0
        /// The folder could not be read at the last scan.
        public var error: String?

        public var files: Int { images + documents }

        public init(path: String) { self.path = path }
    }

    public var folders: [Folder] = []

    public var bytes: Int { folders.reduce(0) { $0 + $1.bytes } }
    public var estimatedBytes: Int { folders.reduce(0) { $0 + $1.estimatedBytes } }
    public var pending: Int { folders.reduce(0) { $0 + $1.pending } }
    public var pendingSeconds: Double { folders.reduce(0) { $0 + $1.pendingSeconds } }

    public init(folders: [Folder] = []) { self.folders = folders }

    /// One file item as the summary sees it.
    struct FileState {
        let path: String
        let isImage: Bool
        /// nil while pending.
        let record: FileIndexRecord?
    }

    /// Sums `files` into `folders`. Pending files are estimated with the average chunk count of the
    /// indexed files of their type when there are enough, else with `FileIndexCost` defaults.
    static func make(folders: [URL], files: [FileState], dimensions: Int, scanErrors: [String: String]) -> FileIndexSummary {
        var byPath: [String: Folder] = [:]
        for folder in folders {
            let path = folder.path(percentEncoded: false)
            var entry = Folder(path: path)
            entry.error = scanErrors[path]
            byPath[path] = entry
        }
        var chunkTotals = (image: 0, imageFiles: 0, document: 0, documentFiles: 0)
        for file in files {
            guard let record = file.record, record.error == nil else { continue }
            if file.isImage {
                chunkTotals.image += record.chunks
                chunkTotals.imageFiles += 1
            } else {
                chunkTotals.document += record.chunks
                chunkTotals.documentFiles += 1
            }
        }
        let imageChunks = chunkTotals.imageFiles >= 5 ? Double(chunkTotals.image) / Double(chunkTotals.imageFiles)
            : FileIndexCost.defaultImageChunks
        let documentChunks = chunkTotals.documentFiles >= 5
            ? Double(chunkTotals.document) / Double(chunkTotals.documentFiles) : FileIndexCost.defaultDocumentChunks
        let chunkBytes = FileIndexCost.bytesPerChunk(dimensions: dimensions)

        for file in files {
            guard let folder = FileScanner.folder(of: file.path, in: folders)?.path(percentEncoded: false),
                  var entry = byPath[folder] else { continue }
            if file.isImage { entry.images += 1 } else { entry.documents += 1 }
            entry.bytes += FileIndexCost.bytesPerFile
            if let record = file.record {
                entry.indexed += 1
                if record.error != nil { entry.failed += 1 }
                entry.chunks += record.chunks
                entry.bytes += record.chunks * chunkBytes
                entry.estimatedBytes += FileIndexCost.bytesPerFile + record.chunks * chunkBytes
            } else {
                let chunks = file.isImage ? imageChunks : documentChunks
                entry.pending += 1
                entry.estimatedBytes += FileIndexCost.bytesPerFile + Int(chunks * Double(chunkBytes))
                entry.pendingSeconds += FileIndexCost.seconds(isImage: file.isImage, chunks: chunks)
            }
            byPath[folder] = entry
        }
        return FileIndexSummary(folders: folders.compactMap { byPath[$0.path(percentEncoded: false)] })
    }

    /// What indexing `folder` would take, from a scan of its file names (no content is read).
    public static func estimate(folder: URL, dimensions: Int = 768) -> Folder {
        let scanner = FileScanner(folders: [folder])
        let scan = scanner.scan()
        let files = scan.items.map { FileState(path: SearchEngine.filePath($0), isImage: FileScanner.isImage(path: SearchEngine.filePath($0)), record: nil) }
        return make(folders: scanner.folders, files: files, dimensions: dimensions, scanErrors: scan.failedFolders).folders.first
            ?? Folder(path: folder.path(percentEncoded: false))
    }
}

/// Storage and time costs of file search, measured indexing ~/Downloads (92 images, 220 PDFs:
/// 2,388 chunks, +5.0 MB of database, 2.5 min) on an M3 Pro.
public enum FileIndexCost {
    /// A float16 vector plus its row (file hash, sequence, kind, hubness), on B-tree pages that run
    /// about 3/4 full: ~2.1 KB at 768 dimensions.
    public static func bytesPerChunk(dimensions: Int) -> Int { (dimensions * 2 + 64) * 4 / 3 }
    /// The file's item row (compressed JSON) and its index record.
    public static let bytesPerFile = 400
    /// The picture plus recognized text in about 7 of 10 images.
    public static let defaultImageChunks = 1.7
    /// ~800-character chunks of the first five pages (PDFs with text averaged 11.6).
    public static let defaultDocumentChunks = 11.0

    static func seconds(isImage: Bool, chunks: Double) -> Double {
        isImage ? 0.6 : 0.1 + chunks * 0.04
    }
}
