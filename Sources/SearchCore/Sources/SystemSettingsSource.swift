import Foundation

/// System Settings panes and their deep-linkable anchors, parsed from the ExtensionKit
/// `.searchTerms` files that System Settings' own search uses (undocumented format, parsed defensively).
///
/// Layout observed on macOS 26.6 (`/System/Library/ExtensionKit/Extensions/*.appex`):
/// - `Contents/Info.plist` → `EXAppExtensionAttributes.EXExtensionPointIdentifier == "com.apple.Settings.extension.ui"`,
///   `…SettingsExtensionAttributes.searchTermsFileName` (+ `legacyBundleIdentifier`).
/// - `Contents/Resources/<lang>.lproj/<searchTermsFileName>.searchTerms` → plist
///   `{ <anchor>: { localizableStrings: [{ title, index: "comma, separated, words" }, …] } }`.
/// - `Contents/Resources/InfoPlist.loctable` → localized pane names (`ko`, `en` or only `en_GB`).
///
/// Deep links: `x-apple.systempreferences:<extension CFBundleIdentifier>[?<anchor>]`. Verified on
/// macOS 26.6.2 by opening links and reading the System Settings window title: the extension id
/// (e.g. `com.apple.BluetoothSettings`, `com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`,
/// `com.apple.Screen-Time-Settings.extension?path=downtime`) and the legacy id
/// (`com.apple.preference.security?Privacy_AllFiles`) both work; an unknown anchor falls back to the
/// pane root; an unknown id opens an empty window.
///
/// One item per (anchor, title) pair — an anchor may carry several titles (e.g. Displays'
/// `ambienceSection` = "Display Brightness" + "True Tone") that share the same link. Ids:
/// `setting:<extID>#<anchor>` for an anchor's first title, `setting:<extID>#<anchor>~<n>` for the n-th
/// further title, and `setting:<extID>#root` for the pane itself.
public struct SystemSettingsSource: ItemSource {
    public let name = "systemSettings"
    public var extensionsDirectory: URL
    /// Icon shown for every settings item (contract: System Settings.app's icon).
    public var iconPath: String

    public init(extensionsDirectory: URL = URL(filePath: "/System/Library/ExtensionKit/Extensions"),
                iconPath: String = "/System/Applications/System Settings.app") {
        self.extensionsDirectory = extensionsDirectory
        self.iconPath = iconPath
    }

    public func loadItems() async throws -> [SearchItem] {
        let fm = FileManager.default
        let appexes = (try? fm.contentsOfDirectory(at: extensionsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "appex" }
            .sorted { $0.path < $1.path } ?? []
        // Panes are independent (plist reads + text processing): build them in parallel, then merge
        // in path order so ids and order match a sequential scan.
        let iconPath = self.iconPath
        var perPane = [[SearchItem]](repeating: [], count: appexes.count)
        perPane.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: appexes.count) { i in
                out[i] = Self.readPane(appexes[i]).map { Self.items(for: $0, iconPath: iconPath) } ?? []
            }
        }
        var items: [SearchItem] = []
        var seen = Set<String>()
        for item in perPane.joined() where seen.insert(item.id).inserted {
            items.append(item)
        }
        return items
    }

    // MARK: Parsing

    struct Pane: Sendable {
        let extensionID: String
        let koName: String
        let enName: String
        let anchors: [Anchor]
    }

    struct Anchor: Sendable {
        let name: String
        /// Parallel en/ko entries (matched by position; ko may be missing).
        let entries: [(en: Entry?, ko: Entry?)]
    }

    struct Entry: Sendable {
        let title: String
        let keywords: [String]
    }

    static func readPane(_ appex: URL) -> Pane? {
        guard let info = ApplicationSource.readPlist(appex.appending(path: "Contents/Info.plist")),
              let attrs = info["EXAppExtensionAttributes"] as? [String: Any],
              attrs["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
              let extensionID = info["CFBundleIdentifier"] as? String
        else { return nil }
        let settingsAttrs = attrs["SettingsExtensionAttributes"] as? [String: Any]
        let resources = appex.appending(path: "Contents/Resources")

        let loctable = ApplicationSource.readPlist(resources.appending(path: "InfoPlist.loctable"))
        func paneName(_ langs: [String]) -> String? {
            for lang in langs {
                guard let table = loctable?[lang] as? [String: Any] else { continue }
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let v = table[key] as? String, !looksLikeCodeName(v) { return ItemText.clean(v) }
                }
            }
            return nil
        }
        let override = paneNameOverrides[extensionID]
        let plistName = (info["CFBundleDisplayName"] as? String).flatMap { looksLikeCodeName($0) ? nil : ItemText.clean($0) }
        guard let enName = override?.en ?? paneName(["en", "en_GB", "en_AU", "Base"]) ?? plistName else { return nil }
        let koName = override?.ko ?? paneName(["ko"]) ?? enName

        var anchors: [Anchor] = []
        if let file = settingsAttrs?["searchTermsFileName"] as? String, !file.isEmpty {
            let en = readSearchTerms(resources.appending(path: "en.lproj/\(file).searchTerms"))
            let ko = readSearchTerms(resources.appending(path: "ko.lproj/\(file).searchTerms"))
            for name in en.keys.sorted() {
                let enEntries = en[name] ?? []
                let koEntries = ko[name] ?? []
                let count = max(enEntries.count, koEntries.count)
                guard count > 0 else { continue }
                let pairs = (0..<count).map { i in
                    (en: i < enEntries.count ? enEntries[i] : nil, ko: i < koEntries.count ? koEntries[i] : nil)
                }
                anchors.append(Anchor(name: name, entries: pairs))
            }
        }
        return Pane(extensionID: extensionID, koName: koName, enName: enName, anchors: anchors)
    }

    /// Parses one `.searchTerms` plist; anything unexpected is skipped rather than failing the pane.
    static func readSearchTerms(_ url: URL) -> [String: [Entry]] {
        guard let root = ApplicationSource.readPlist(url) else { return [:] }
        var out: [String: [Entry]] = [:]
        for (anchor, value) in root {
            guard let dict = value as? [String: Any], let strings = dict["localizableStrings"] as? [Any] else { continue }
            let entries: [Entry] = strings.compactMap { raw in
                guard let e = raw as? [String: Any], let title = e["title"] as? String else { return nil }
                let cleaned = ItemText.clean(title)
                guard !cleaned.isEmpty else { return nil }
                return Entry(title: cleaned, keywords: ItemText.splitList(e["index"] as? String))
            }
            if !entries.isEmpty { out[anchor] = entries }
        }
        return out
    }

    /// "PowerPreferences", "HeadphoneSettingsExtension" — internal names some panes ship instead of a
    /// localized display name.
    static func looksLikeCodeName(_ s: String) -> Bool {
        guard !s.contains(" "), !Hangul.containsHangul(s) else { return false }
        if s.hasSuffix("Extension") || s.hasSuffix("Settings") || s.hasSuffix("Preferences") { return true }
        let humps = s.unicodeScalars.dropFirst().filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return humps >= 2 && s.count > 10
    }

    /// Panes whose bundles carry no usable display name.
    static let paneNameOverrides: [String: (ko: String, en: String)] = [
        "com.apple.Battery-Settings.extension": ("배터리", "Battery"),
        "com.apple.HeadphoneSettings": ("헤드폰", "Headphones"),
    ]

    // MARK: Items

    static func items(for pane: Pane, iconPath: String) -> [SearchItem] {
        let base = "x-apple.systempreferences:\(pane.extensionID)"
        let paneLabel = pane.koName == pane.enName ? pane.koName : "\(pane.koName) (\(pane.enName))"
        var items: [SearchItem] = []

        let allAnchorTitles = pane.anchors.flatMap { $0.entries.compactMap { $0.ko?.title ?? $0.en?.title } }
        let rootSubtitle = pane.koName == pane.enName ? "시스템 설정" : "\(pane.enName) · 시스템 설정"
        items.append(SearchItem(
            id: "setting:\(pane.extensionID)#root",
            kind: .systemSetting,
            title: pane.koName,
            subtitle: rootSubtitle,
            keywords: ItemText.uniqueKeywords([pane.koName, pane.enName]),
            embeddingTitle: paneLabel,
            embeddingText: (["시스템 설정 (System Settings) › \(paneLabel)"] + (allAnchorTitles.isEmpty ? [] : [allAnchorTitles.prefix(12).joined(separator: ", ")]))
                .joined(separator: " · "),
            action: .openURL(base),
            icon: .filePath(iconPath)
        ))

        for anchor in pane.anchors {
            let link = "\(base)?\(anchor.name.addingPercentEncoding(withAllowedCharacters: anchorAllowed) ?? anchor.name)"
            for (i, entry) in anchor.entries.enumerated() {
                // Korean titles sometimes carry aliases after a comma: "AirDrop, 에어드롭", "FileVault, 파일볼트".
                let koParts = ItemText.splitList(entry.ko?.title)
                let enTitle = entry.en?.title
                guard let title = koParts.first ?? enTitle else { continue }
                let titleLabel = enTitle.map { TextNormalizer.normalize($0) == TextNormalizer.normalize(title) ? title : "\(title) (\($0))" } ?? title
                let enKeywords = entry.en?.keywords ?? []
                let koKeywords = entry.ko?.keywords ?? []
                let keywords = ItemText.uniqueKeywords(
                    koParts.map(Optional.some) + [enTitle, pane.koName, pane.enName]
                    + koKeywords.map(Optional.some) + enKeywords.map(Optional.some))
                let indexWords = ItemText.uniqueKeywords((koKeywords + enKeywords).map(Optional.some))
                var card = ["시스템 설정 (System Settings) › \(paneLabel) › \(titleLabel)"]
                if koParts.count > 1 { card.append(koParts.dropFirst().joined(separator: ", ")) }
                if !indexWords.isEmpty { card.append(indexWords.prefix(24).joined(separator: ", ")) }
                items.append(SearchItem(
                    id: "setting:\(pane.extensionID)#\(anchor.name)" + (i == 0 ? "" : "~\(i)"),
                    kind: .systemSetting,
                    title: title,
                    subtitle: enTitle.map { "\(pane.koName) › \($0)" } ?? pane.koName,
                    keywords: keywords,
                    embeddingTitle: titleLabel,
                    embeddingText: card.joined(separator: " · "),
                    action: .openURL(link),
                    icon: .filePath(iconPath)
                ))
            }
        }
        return items
    }

    /// Characters kept verbatim in the anchor query component (spaces become %20).
    private static let anchorAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: " &#")
        return s
    }()
}
