import Foundation

/// Lists the images and PDFs under the folders the user chose, as `.file` items. Only names and
/// metadata are read here; content is read when a file is indexed (`FileContentExtractor`).
public struct FileScanner: Sendable {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
    public static let documentExtensions: Set<String> = ["pdf"]

    public struct Result: Sendable {
        public var items: [SearchItem] = []
        /// Folders that could not be listed (missing, or no permission) → reason. Includes
        /// subfolders, whose previously indexed files must not be taken for deleted.
        public var failedFolders: [String: String] = [:]
    }

    public let folders: [URL]
    /// Files per folder beyond this are left out, bounding scan time and index size.
    public var maxFilesPerFolder = 50_000

    public init(folders: [URL]) {
        self.folders = Self.normalized(folders)
    }

    /// Standardized, deduplicated folders; a folder inside another listed one is dropped.
    public static func normalized(_ folders: [URL]) -> [URL] {
        let paths = Set(folders.map { $0.standardizedFileURL.path(percentEncoded: false) })
        return paths.sorted()
            .filter { path in !paths.contains { $0 != path && path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public func scan() -> Result {
        var result = Result()
        var seen = Set<String>()
        for folder in folders {
            let folderPath = folder.path(percentEncoded: false)
            do {
                // Throws when the folder is missing or unreadable, which the enumerator would not report.
                _ = try FileManager.default.contentsOfDirectory(atPath: folderPath)
            } catch {
                result.failedFolders[folderPath] = error.localizedDescription
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            // The enumerator reports real paths (e.g. /private/var for /var); files are listed under
            // the folder as given, so they match it.
            let given = Self.directoryPrefix(folder)
            let real = Self.realPath(folderPath).map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? given
            let unreadable = UnreadablePaths()
            defer {
                for (path, reason) in unreadable.paths {
                    let listed = real != given && path.hasPrefix(real) ? given + path.dropFirst(real.count) : path
                    result.failedFolders[listed] = reason
                }
            }
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    unreadable.paths.append((url.path(percentEncoded: false), error.localizedDescription))
                    return true
                })
            else { continue }
            var count = 0
            for case var url as URL in walker {
                guard Self.isIndexable(url),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                let path = url.path(percentEncoded: false)
                if real != given, path.hasPrefix(real) { url = URL(filePath: given + path.dropFirst(real.count)) }
                let item = Self.item(for: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
                guard seen.insert(item.id).inserted else { continue }
                result.items.append(item)
                count += 1
                if count >= maxFilesPerFolder { break }
            }
        }
        return result
    }

    public static func isIndexable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || documentExtensions.contains(ext)
    }

    public static func isImage(path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The `.file` item for `url`. File names are often stored decomposed (NFD), so display and
    /// lexical text are composed; the path stays as stored, for opening the file.
    public static func item(for url: URL, size: Int, modified: Date) -> SearchItem {
        let path = url.path(percentEncoded: false)
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let stem = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        return SearchItem(
            id: "file:\(path)", kind: .file, title: name,
            subtitle: abbreviated(url.deletingLastPathComponent().path(percentEncoded: false)),
            keywords: stem == name ? [] : [stem],
            embeddingTitle: stem,
            embeddingText: "\(size) \(Int64((modified.timeIntervalSince1970 * 1000).rounded()))"
                + (isImage(path: path) ? "" : " \(FileContentExtractor.pdfReadingVersion)"),
            action: .openFile(path: path), icon: .filePath(path))
    }

    /// The listed folder that contains `path` (the longest one), if any.
    public static func folder(of path: String, in folders: [URL]) -> URL? {
        folders.filter { path.hasPrefix(Self.directoryPrefix($0)) }
            .max { $0.path(percentEncoded: false).count < $1.path(percentEncoded: false).count }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func directoryPrefix(_ folder: URL) -> String {
        let p = folder.path(percentEncoded: false)
        return p.hasSuffix("/") ? p : p + "/"
    }

    /// `~/…` for paths in the home folder, without a trailing slash.
    static func abbreviated(_ path: String) -> String {
        var p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let homePrefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        if p == homePrefix { p = "~" } else if p.hasPrefix(homePrefix + "/") { p = "~" + p.dropFirst(homePrefix.count) }
        return p.precomposedStringWithCanonicalMapping
    }
}

/// Paths the enumerator could not read (its error handler is an escaping closure).
private final class UnreadablePaths {
    var paths: [(String, String)] = []
}
