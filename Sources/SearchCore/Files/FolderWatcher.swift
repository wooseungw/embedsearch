import CoreServices
import Foundation

/// Watches folders (recursively) with FSEvents and calls `onChange` once changes settle (FSEvents
/// coalesces events over `latency`). Only events that can change what `FileScanner` lists count: an
/// image or PDF, or a subfolder created, renamed or removed — not hidden items or the inside of
/// packages (a Photos library, an app), which the scanner skips, nor `.DS_Store` or partial
/// downloads. A watched folder that goes away shows up at the next scan.
///
/// Creating one can block until the user answers the privacy prompt for a protected folder
/// (Downloads, Documents, Desktop), so never create it on the main thread.
public final class FolderWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    /// Watched folders as FSEvents reports them (real paths, no trailing slash).
    private let roots: Set<String>
    private let queue = DispatchQueue(label: "com.seungwoo.embedsearch.folder-watcher")
    private var stream: FSEventStreamRef?

    /// Starts watching; nil when no stream could be created (e.g. no folders).
    public init?(folders: [URL], latency: TimeInterval = 3, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        roots = Set(folders.map { url in
            let path = FileScanner.realPath(url.path(percentEncoded: false)) ?? url.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        })
        let paths = folders.map { $0.path(percentEncoded: false) } as CFArray
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        // No kFSEventStreamCreateFlagWatchRoot: it opens each folder at creation.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard !folders.isEmpty,
              let stream = FSEventStreamCreate(nil, Self.callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    /// Stops the stream and waits out a callback already running, so none runs after this
    /// returns (the callback holds an unretained pointer to the watcher). Not from `onChange`.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        for i in 0..<min(count, paths.count) where FolderWatcher.matters(path: paths[i], flags: flags[i], roots: watcher.roots) {
            watcher.onChange()
            return
        }
    }

    /// Package extensions whose contents the scanner does not enter.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "photolibrary",
        "musiclibrary", "tvlibrary", "aplibrary", "migratedphotolibrary", "download", "xcodeproj", "xcworkspace",
        "pages", "numbers", "key", "rtfd", "lproj", "pkg", "mpkg", "sparsebundle", "fcpbundle", "logicx", "band",
    ]

    static func matters(path: String, flags: FSEventStreamEventFlags, roots: Set<String> = []) -> Bool {
        let has = { (flag: Int) in flags & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagRootChanged) || has(kFSEventStreamEventFlagMustScanSubDirs) { return true }
        // What the scanner skips: hidden items and anything inside a package.
        let root = roots.first { path.hasPrefix($0 + "/") }
        let relative = root.map { path.dropFirst($0.count) } ?? Substring(path)
        for component in relative.split(separator: "/") {
            if component.hasPrefix(".") { return false }
            if let dot = component.lastIndex(of: "."),
               packageExtensions.contains(component[component.index(after: dot)...].lowercased()) { return false }
        }
        if has(kFSEventStreamEventFlagItemIsDir) {
            // A watched folder's own events (its creation, its attributes) change nothing in it;
            // a subfolder matters when it appears, moves or goes.
            guard !roots.contains(path) else { return false }
            return has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
                || has(kFSEventStreamEventFlagItemRenamed)
        }
        return FileScanner.isIndexable(URL(filePath: path))
    }
}
