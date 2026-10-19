import AppKit

/// Finder icons for `IconHint.filePath`, cached per path.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}
