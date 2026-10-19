import CoreServices
import Foundation

/// Installed applications with Korean + English names.
///
/// Names come from (in order of trust) the bundle's `InfoPlist.loctable` / `<lang>.lproj/InfoPlist.strings`,
/// Spotlight metadata (`kMDItemDisplayName` is localized to the system language, `kMDItemAlternateNames`
/// holds the English file name and extra aliases such as "browser" / "사파리"), then Info.plist and the
/// file name. Apps are read straight from disk (no `Bundle` objects, which are cached for the process
/// lifetime) and in parallel.
public struct ApplicationSource: ItemSource {
    public let name = "applications"
    /// Scanned one level deep (`/Applications/TeX/TeXShop.app` is found).
    public var directories: [URL]
    /// Individual app bundles or folders of them (scanned flat) outside the usual directories.
    public var extraLocations: [URL]
    public var useSpotlight: Bool

    public static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) } + [home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    public static var defaultExtraLocations: [URL] {
        ["/System/Library/CoreServices/Finder.app", "/System/Library/CoreServices/Applications"]
            .map { URL(filePath: $0) }
    }

    public init(directories: [URL] = ApplicationSource.defaultDirectories,
                extraLocations: [URL] = ApplicationSource.defaultExtraLocations,
                useSpotlight: Bool = true) {
        self.directories = directories
        self.extraLocations = extraLocations
        self.useSpotlight = useSpotlight
    }

    public func loadItems() async throws -> [SearchItem] {
        let candidates = discover()
        let useSpotlight = self.useSpotlight
        var results = [SearchItem?](repeating: nil, count: candidates.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                out[i] = Self.makeItem(candidates[i], useSpotlight: useSpotlight)
            }
        }
        var seen = Set<String>()
        return results.compactMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    struct Candidate: Sendable {
        let url: URL
        /// Found inside a sub-folder of an app directory (helpers live there; filtered harder).
        let nested: Bool
    }

    func discover() -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        var seenPaths = Set<String>()
        func add(_ url: URL, nested: Bool) {
            let path = url.standardizedFileURL.path
            if seenPaths.insert(path).inserted { out.append(Candidate(url: url, nested: nested)) }
        }
        func children(_ dir: URL) -> [URL] {
            // Not `.skipsHiddenFiles`: it also drops /Applications/Safari.app (a symlink into the
            // Safari cryptex that carries the hidden flag). Dot-files are skipped by name instead.
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .map { dir.appending(path: $0) }
        }
        func isPlainDirectory(_ url: URL) -> Bool {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
        let directoryPaths = Set(directories.map(\.standardizedFileURL.path))
        for dir in directories {
            for child in children(dir) {
                if child.pathExtension == "app" {
                    add(child, nested: false)
                } else if isPlainDirectory(child), !directoryPaths.contains(child.standardizedFileURL.path) {
                    for grandchild in children(child) where grandchild.pathExtension == "app" {
                        add(grandchild, nested: true)
                    }
                }
            }
        }
        for extra in extraLocations {
            if extra.pathExtension == "app" {
                if fm.fileExists(atPath: extra.path) { add(extra, nested: false) }
            } else {
                for child in children(extra) where child.pathExtension == "app" { add(child, nested: false) }
            }
        }
        return out
    }

    // MARK: Item construction

    struct AppInfo {
        var bundleID: String?
        var korean: String?
        var english: String?
        var displayName: String?
        var aliases: [String] = []
        var categoryType: String?
        var storeCategory: String?
        var backgroundOnly = false
        var agent = false
    }

    static func makeItem(_ candidate: Candidate, useSpotlight: Bool) -> SearchItem? {
        let url = candidate.url
        guard let info = readInfo(url, useSpotlight: useSpotlight) else { return nil }
        if candidate.nested && (info.backgroundOnly || info.agent) { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        let title = ItemText.clean(info.korean ?? info.displayName ?? info.english ?? fileName)
        let english = info.english.map(ItemText.clean)
        let subtitle = english.flatMap { TextNormalizer.normalize($0) == TextNormalizer.normalize(title) ? nil : $0 }
        let category = AppCategory.words(for: info.categoryType)
        let catalog = info.bundleID.flatMap(AppCatalog.entry(for:))

        let keywords = ItemText.uniqueKeywords(
            [title, english, info.displayName, fileName] + info.aliases.map(Optional.some)
            + (catalog?.aliases ?? []).map(Optional.some)
            + [category?.ko, category?.en, info.storeCategory])

        var card: [String] = [english.map { "\(title) (\($0))" } ?? title, "macOS 앱 (application)"]
        if let category { card.append("\(category.ko) (\(category.en))") }
        if let catalog { card.append(catalog.description) }
        let extraAliases = (info.aliases + (catalog?.aliases ?? [])).filter {
            let n = TextNormalizer.normalize($0)
            return n != TextNormalizer.normalize(title) && n != TextNormalizer.normalize(english ?? "") && n != TextNormalizer.normalize(fileName)
        }
        if !extraAliases.isEmpty { card.append(ItemText.uniqueKeywords(extraAliases).joined(separator: ", ")) }

        return SearchItem(
            id: "app:" + (info.bundleID ?? url.path),
            kind: .application,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            embeddingTitle: title,
            embeddingText: card.joined(separator: " · "),
            action: .openApplication(path: url.path),
            icon: .filePath(url.path)
        )
    }

    static func readInfo(_ url: URL, useSpotlight: Bool) -> AppInfo? {
        var info = AppInfo()
        // Regular bundle, or an iOS/iPadOS app wrapped for Apple silicon (`WrappedBundle/Info.plist`).
        var resources = url.appending(path: "Contents/Resources")
        var plist = readPlist(url.appending(path: "Contents/Info.plist"))
        if plist == nil, let wrapped = readPlist(url.appending(path: "WrappedBundle/Info.plist")) {
            plist = wrapped
            resources = url.appending(path: "WrappedBundle")
        }
        if let plist {
            info.bundleID = plist["CFBundleIdentifier"] as? String
            info.categoryType = plist["LSApplicationCategoryType"] as? String
            info.backgroundOnly = boolValue(plist["LSBackgroundOnly"])
            info.agent = boolValue(plist["LSUIElement"])
        }

        let loctable = readPlist(resources.appending(path: "InfoPlist.loctable"))
        func localized(_ langs: [String]) -> String? {
            for lang in langs {
                if let table = loctable?[lang] as? [String: Any], let name = bundleName(table) { return name }
                if let strings = readPlist(resources.appending(path: "\(lang).lproj/InfoPlist.strings")),
                   let name = bundleName(strings) { return name }
            }
            return nil
        }
        info.korean = localized(["ko", "ko_KR", "ko-KR", "Korean"])
        if let en = localized(["en", "en_US", "en-US", "English", "Base", "en_GB", "en_AU"]), !Hangul.containsHangul(en) {
            info.english = en
        }

        if useSpotlight, let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            // One metadata-server round trip for all four attributes.
            let names = [kMDItemCFBundleIdentifier, kMDItemDisplayName, "kMDItemAlternateNames" as CFString,
                         "kMDItemAppStoreCategory" as CFString] as CFArray
            let attributes = (MDItemCopyAttributes(md, names) as? [String: Any]) ?? [:]
            if info.bundleID == nil { info.bundleID = attributes[kMDItemCFBundleIdentifier as String] as? String }
            if let name = attributes[kMDItemDisplayName as String] as? String {
                info.displayName = stripApp(name)
            }
            if let alts = attributes["kMDItemAlternateNames"] as? [String] {
                info.aliases = alts.map(stripApp)
            }
            info.storeCategory = attributes["kMDItemAppStoreCategory"] as? String
        }
        if info.displayName == nil {
            info.displayName = stripApp(FileManager.default.displayName(atPath: url.path))
        }

        let fileName = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        if info.korean == nil {
            info.korean = [info.displayName, fileName].compactMap { $0 }.first(where: Hangul.containsHangul)
        }
        if info.english == nil {
            let plistName = plist.flatMap(bundleName)
            info.english = [fileName, plistName].compactMap { $0 }.first { !Hangul.containsHangul($0) && !$0.isEmpty }
        }
        return info
    }

    private static func bundleName(_ dict: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let v = dict[key] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return v.precomposedStringWithCanonicalMapping
            }
        }
        return nil
    }

    private static func stripApp(_ name: String) -> String {
        let n = name.precomposedStringWithCanonicalMapping
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    private static func boolValue(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        case let s as String: ["1", "true", "yes"].contains(s.lowercased())
        default: false
        }
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// `LSApplicationCategoryType` → Korean / English words.
enum AppCategory {
    static func words(for type: String?) -> (ko: String, en: String)? {
        guard let type, let last = type.split(separator: ".").last.map(String.init) else { return nil }
        if last.hasSuffix("-games") { return ("게임", "Games") }
        return table[last]
    }

    private static let table: [String: (ko: String, en: String)] = [
        "business": ("비즈니스", "Business"),
        "developer-tools": ("개발자 도구", "Developer Tools"),
        "education": ("교육", "Education"),
        "entertainment": ("엔터테인먼트", "Entertainment"),
        "finance": ("금융", "Finance"),
        "games": ("게임", "Games"),
        "graphics-design": ("그래픽 및 디자인", "Graphics & Design"),
        "healthcare-fitness": ("건강 및 피트니스", "Health & Fitness"),
        "lifestyle": ("라이프스타일", "Lifestyle"),
        "medical": ("의료", "Medical"),
        "music": ("음악", "Music"),
        "news": ("뉴스", "News"),
        "photography": ("사진", "Photography"),
        "productivity": ("생산성", "Productivity"),
        "reference": ("참고", "Reference"),
        "social-networking": ("소셜 네트워킹", "Social Networking"),
        "sports": ("스포츠", "Sports"),
        "travel": ("여행", "Travel"),
        "utilities": ("유틸리티", "Utilities"),
        "video": ("비디오", "Video"),
        "weather": ("날씨", "Weather"),
        "books": ("도서", "Books"),
    ]
}
