import Foundation
import Testing
@testable import SearchCore

@Suite("System Settings source")
struct SystemSettingsSourceTests {
    /// Mirrors the macOS 26 layout: Info.plist + InfoPlist.loctable + en/ko `.searchTerms`.
    func makeFixture() throws -> TempDir {
        let dir = try TempDir()
        let appex = "Ext/Sharing.appex/Contents"
        try dir.writePlist([
            "CFBundleIdentifier": "com.apple.Sharing-Settings.extension",
            "CFBundleDisplayName": "SharingExtension",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": "com.apple.Settings.extension.ui",
                "SettingsExtensionAttributes": ["searchTermsFileName": "Sharing", "legacyBundleIdentifier": "com.apple.preferences.sharing"],
            ],
        ], to: "\(appex)/Info.plist")
        try dir.writePlist([
            "ko": ["CFBundleDisplayName": "공유"],
            "en_GB": ["CFBundleDisplayName": "Sharing"],
        ], to: "\(appex)/Resources/InfoPlist.loctable")
        try dir.writePlist([
            "Services_ScreenSharing": ["localizableStrings": [["title": "Screen Sharing", "index": "vnc, remote, screen"]]],
            "AirDrop_Handoff": ["localizableStrings": [["title": "AirDrop", "index": "share"], ["title": "Allow Handoff", "index": "continuity"]]],
            "Advanced Ethernet": ["localizableStrings": [["title": "Ethernet speed", "index": ""]]],
            "Empty": ["localizableStrings": []],
            "Garbage": "not a dict",
        ], to: "\(appex)/Resources/en.lproj/Sharing.searchTerms")
        try dir.writePlist([
            "Services_ScreenSharing": ["localizableStrings": [["title": "화면 공유", "index": "원격, 화면"]]],
            "AirDrop_Handoff": ["localizableStrings": [["title": "AirDrop, 에어드롭", "index": "공유"], ["title": "Handoff\u{00A0}허용", "index": "연속성"]]],
        ], to: "\(appex)/Resources/ko.lproj/Sharing.searchTerms")
        // A non-settings extension must be ignored.
        try dir.writePlist(["CFBundleIdentifier": "com.example.widget",
                            "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.widgetkit-extension"]],
                           to: "Ext/Widget.appex/Contents/Info.plist")
        return dir
    }

    @Test func parsesPanesAnchorsAndDeepLinks() async throws {
        let dir = try makeFixture()
        let items = try await SystemSettingsSource(extensionsDirectory: dir.url.appending(path: "Ext")).loadItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(items.count == 5)   // root + screen sharing + 2 AirDrop titles + ethernet

        let root = try #require(byID["setting:com.apple.Sharing-Settings.extension#root"])
        #expect(root.title == "공유")
        #expect(root.subtitle == "Sharing · 시스템 설정")
        #expect(root.action == .openURL("x-apple.systempreferences:com.apple.Sharing-Settings.extension"))

        let screen = try #require(byID["setting:com.apple.Sharing-Settings.extension#Services_ScreenSharing"])
        #expect(screen.kind == .systemSetting)
        #expect(screen.title == "화면 공유")
        #expect(screen.subtitle == "공유 › Screen Sharing")
        #expect(screen.action == .openURL("x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_ScreenSharing"))
        #expect(screen.keywords.contains("Screen Sharing") && screen.keywords.contains("vnc") && screen.keywords.contains("원격"))
        #expect(screen.embeddingText.contains("시스템 설정") && screen.embeddingText.contains("Screen Sharing"))

        // Korean alias after a comma becomes a keyword; the second title gets a ~1 id and the same link.
        let airdrop = try #require(byID["setting:com.apple.Sharing-Settings.extension#AirDrop_Handoff"])
        #expect(airdrop.title == "AirDrop")
        #expect(airdrop.keywords.contains("에어드롭"))
        let handoff = try #require(byID["setting:com.apple.Sharing-Settings.extension#AirDrop_Handoff~1"])
        #expect(handoff.title == "Handoff 허용")      // NBSP cleaned
        #expect(handoff.action == airdrop.action)

        // English-only anchor; spaces percent-encoded in the link.
        let ethernet = try #require(byID["setting:com.apple.Sharing-Settings.extension#Advanced Ethernet"])
        #expect(ethernet.title == "Ethernet speed")
        #expect(ethernet.action == .openURL("x-apple.systempreferences:com.apple.Sharing-Settings.extension?Advanced%20Ethernet"))
    }

    @Test func codeNamesAreNotDisplayNames() {
        #expect(SystemSettingsSource.looksLikeCodeName("PowerPreferences"))
        #expect(SystemSettingsSource.looksLikeCodeName("HeadphoneSettingsExtension"))
        #expect(SystemSettingsSource.looksLikeCodeName("WiFiSettings"))
        #expect(!SystemSettingsSource.looksLikeCodeName("Bluetooth"))
        #expect(!SystemSettingsSource.looksLikeCodeName("Touch ID & Password"))
        #expect(!SystemSettingsSource.looksLikeCodeName("배터리"))
    }

    @Test(.enabled(if: liveSystem)) func liveSystemSettings() async throws {
        let items = try await SystemSettingsSource().loadItems()
        #expect(items.count > 300)
        #expect(Set(items.map(\.id)).count == items.count)
        let ids = Set(items.map(\.id))
        #expect(ids.contains("setting:com.apple.settings.PrivacySecurity.extension#Privacy_AllFiles"))
        #expect(ids.contains("setting:com.apple.BluetoothSettings#root"))
        let fda = items.first { $0.id == "setting:com.apple.settings.PrivacySecurity.extension#Privacy_AllFiles" }
        #expect(fda?.action == .openURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"))
        #expect(items.allSatisfy { !$0.title.isEmpty && !$0.embeddingText.isEmpty })
    }
}

@Suite("Application source")
struct ApplicationSourceTests {
    @Test func readsLocalizedNamesFromBundleFiles() async throws {
        let dir = try TempDir()
        try dir.writePlist(["CFBundleIdentifier": "com.example.calc", "CFBundleName": "Calc",
                            "LSApplicationCategoryType": "public.app-category.utilities"],
                           to: "Apps/Calculator.app/Contents/Info.plist")
        try dir.writePlist(["ko": ["CFBundleDisplayName": "계산기"], "en": ["CFBundleDisplayName": "Calculator"]],
                           to: "Apps/Calculator.app/Contents/Resources/InfoPlist.loctable")
        // Old-style strings file in ko.lproj.
        try FileManager.default.createDirectory(at: dir.url.appending(path: "Apps/Notes.app/Contents/Resources/ko.lproj"),
                                                withIntermediateDirectories: true)
        try dir.writePlist(["CFBundleIdentifier": "com.example.notes"], to: "Apps/Notes.app/Contents/Info.plist")
        try "\"CFBundleDisplayName\" = \"메모\";".write(to: dir.url.appending(path: "Apps/Notes.app/Contents/Resources/ko.lproj/InfoPlist.strings"),
                                                       atomically: true, encoding: .utf8)
        // Nested helper agent is skipped, nested regular app is kept, duplicates by bundle id collapse.
        try dir.writePlist(["CFBundleIdentifier": "com.example.helper", "LSUIElement": true], to: "Apps/Suite/Helper.app/Contents/Info.plist")
        try dir.writePlist(["CFBundleIdentifier": "com.example.editor"], to: "Apps/Suite/Editor.app/Contents/Info.plist")
        try dir.writePlist(["CFBundleIdentifier": "com.example.calc"], to: "Extra/Calculator Copy.app/Contents/Info.plist")

        let source = ApplicationSource(directories: [dir.url.appending(path: "Apps")],
                                       extraLocations: [dir.url.appending(path: "Extra")], useSpotlight: false)
        let items = try await source.loadItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["app:com.example.calc", "app:com.example.notes", "app:com.example.editor"])

        let calc = try #require(byID["app:com.example.calc"])
        #expect(calc.title == "계산기")
        #expect(calc.subtitle == "Calculator")
        #expect(calc.kind == .application)
        #expect(calc.keywords.contains("Calculator") && calc.keywords.contains("유틸리티") && calc.keywords.contains("Utilities"))
        #expect(calc.embeddingText.contains("계산기 (Calculator)"))
        #expect(calc.action == .openApplication(path: dir.url.appending(path: "Apps/Calculator.app").path))

        let notes = try #require(byID["app:com.example.notes"])
        #expect(notes.title == "메모")
        #expect(notes.subtitle == "Notes")
    }

    @Test(.enabled(if: liveSystem)) func liveApplicationsAreFastAndBilingual() async throws {
        let start = Date()
        let items = try await ApplicationSource().loadItems()
        let elapsed = Date().timeIntervalSince(start)
        #expect(items.count > 30)
        #expect(Set(items.map(\.id)).count == items.count)
        let calc = try #require(items.first { $0.id == "app:com.apple.calculator" })
        #expect(calc.keywords.contains("Calculator"))
        #expect(calc.keywords.contains("계산기"))
        #expect(items.contains { $0.id == "app:com.apple.finder" })
        #expect(elapsed < 3, "app scan took \(elapsed) s")
    }
}

@Suite("Command source")
struct CommandSourceTests {
    @Test func builtinIdsMatchDesign() {
        let design = ["lock-screen", "sleep", "display-sleep", "screen-saver", "restart", "shut-down", "log-out", "empty-trash",
                      "toggle-dark-mode", "toggle-mute", "volume-up", "volume-down", "screenshot", "toggle-hidden-files",
                      "open-downloads", "open-desktop", "open-documents", "open-home", "eject-all", "restart-finder", "restart-dock",
                      "clipboard-history"]
        #expect(BuiltinCommands.ids == design)
        let confirm = Set(BuiltinCommands.all.filter(\.requiresConfirmation).map(\.id))
        #expect(confirm == ["restart", "shut-down", "log-out", "empty-trash", "eject-all"])
    }

    @Test func itemsAndInjectedShortcuts() async throws {
        let source = CommandSource(listShortcuts: { _ in ["노래켜줘", "Day", "Day"] })
        let items = try await source.loadItems()
        #expect(items.filter { $0.kind == .command }.count == BuiltinCommands.all.count)
        let shortcuts = items.filter { $0.kind == .shortcut }
        #expect(shortcuts.map(\.id) == ["shortcut:노래켜줘", "shortcut:Day"])
        #expect(shortcuts[0].action == .runShortcut(name: "노래켜줘"))
        let trash = try #require(items.first { $0.id == "cmd:empty-trash" })
        #expect(trash.requiresConfirmation)
        #expect(trash.action == .builtinCommand(id: "empty-trash"))
        #expect(trash.icon == .systemSymbol("trash"))
        #expect(trash.title == "휴지통 비우기" && trash.subtitle == "Empty Trash")

        let none = try await CommandSource(includeShortcuts: false).loadItems()
        #expect(none.allSatisfy { $0.kind == .command })
    }

    @Test func shortcutListParsingAndProcessTimeout() async {
        #expect(CommandSource.parseShortcutList("A\n  B \n\nC\n") == ["A", "B", "C"])
        let slow = await CommandSource.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(slow == nil)
        let ok = await CommandSource.run("/bin/echo", ["hi"], timeout: 3)
        #expect(ok == "hi\n")
        let missing = await CommandSource.run("/nonexistent/tool", [], timeout: 1)
        #expect(missing == nil)
    }
}
