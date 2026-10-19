import Foundation

/// A producer of launcher items (apps, settings, commands...). `loadItems` is called on every
/// `SearchEngine.refresh()`, possibly concurrently with other sources; it must not execute anything
/// user-visible.
public protocol ItemSource: Sendable {
    var name: String { get }
    func loadItems() async throws -> [SearchItem]
}

/// Fixed list of items (tests, previews, synthetic benchmarks).
public struct StaticItemSource: ItemSource {
    public let name: String
    public let items: [SearchItem]

    public init(name: String = "static", items: [SearchItem]) {
        self.name = name
        self.items = items
    }

    public func loadItems() async throws -> [SearchItem] { items }
}

/// The default sources for this phase: apps, System Settings panes/anchors, commands + Shortcuts.
public enum DefaultSources {
    public static func all(includeShortcuts: Bool = true) -> [any ItemSource] {
        [ApplicationSource(), SystemSettingsSource(), CommandSource(includeShortcuts: includeShortcuts)]
    }
}

/// Helpers shared by sources for building keyword lists and text cards.
enum ItemText {
    /// Trims, collapses whitespace (incl. NBSP), drops empties and normalized duplicates; keeps order.
    static func uniqueKeywords(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for case let v? in values {
            let cleaned = clean(v)
            guard !cleaned.isEmpty else { continue }
            let key = TextNormalizer.normalize(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(cleaned)
        }
        return out
    }

    /// NFC, NBSP → space, whitespace collapsed and trimmed.
    static func clean(_ s: String) -> String {
        if let simple = cleanASCIIAndSyllables(s) { return simple }
        return s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `clean` for ASCII + Hangul-syllable text, byte by byte: such text is NFC, has no NBSP and no
    /// combining marks, and its whitespace characters are exactly the bytes 09–0D and 20.
    private static func cleanASCIIAndSyllables(_ s: String) -> String? {
        guard TextNormalizer.isASCIIOrSyllables(s) else { return nil }
        var s = s
        return s.withUTF8 { src in
            String(unsafeUninitializedCapacity: src.count) { dst in
                var o = 0
                var pendingSpace = false
                for b in src {
                    if b == 0x20 || (b >= 0x09 && b <= 0x0D) { pendingSpace = true; continue }
                    if pendingSpace && o > 0 { dst[o] = 0x20; o += 1 }
                    pendingSpace = false
                    dst[o] = b
                    o += 1
                }
                return o
            }
        }
    }

    static func splitList(_ s: String?) -> [String] {
        guard let s else { return [] }
        return s.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
    }
}
