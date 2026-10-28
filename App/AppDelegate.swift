import AppKit
import SearchCore
import os

@main
@MainActor
enum EmbedSearchMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Launch arguments (for testing): `--show` open the panel at launch, `--query <text>` prefill it,
/// `--onboarding` show the first-launch introduction,
/// `--no-hotkey` skip global hotkey registration, `--dry-run-actions` log instead of executing,
/// `--settings [folders|clipboard|engine|updates]` open Settings at launch, `--mock` the mock search service instead of the engine (and no updates), `--mock-slow` / `--mock-degraded` mock
/// engine states, `-modelIdleSeconds <n>` release the embedding model after n idle seconds.
/// URL scheme: `embedsearch://toggle`, `embedsearch://show[?q=…]`, `embedsearch://clipboard`, `embedsearch://hide`,
/// `embedsearch://settings`, `embedsearch://settings/folders`, `embedsearch://welcome`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let launchAtLogin = LaunchAtLogin()
    private let actions = ActionRunner()
    private let clipboard = ClipboardHistory()
    private let updater = Updater(enabled: !CommandLine.arguments.contains(where: { $0.hasPrefix("--mock") }))
    private let arguments = CommandLine.arguments
    private let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "app")
    private var query: QueryController!
    private var panel: LauncherPanelController!
    private var hotKeys: HotKeyController!
    private var clipboardHotKeys: HotKeyController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var onboarding: OnboardingWindowController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // With LSUIElement the app still steals focus at launch unless it starts out prohibited.
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()

        // A new install has no index yet (opening the store creates it): it gets the introduction.
        let isNewInstall = !FileManager.default.fileExists(atPath: IndexStore.defaultURL.path(percentEncoded: false))
        let search = AppServices.makeSearchService(arguments: arguments, folders: settings.searchFolders)
        query = QueryController(service: MergedSearchService(base: search, history: clipboard),
                                clipboardService: ClipboardSearchService(history: clipboard))
        query.startObservingEngine()
        actions.dryRun = arguments.contains("--dry-run-actions")
        clipboard.setEnabled(settings.clipboardHistoryEnabled)

        panel = LauncherPanelController(query: query, settings: settings, actions: actions, clipboard: clipboard)
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onShow = { AppServices.panelWillShow() }

        hotKeys = HotKeyController(settings: settings) { [weak self] in self?.panel.toggle() }
        hotKeys.onOpenSettings = { [weak self] in self?.openSettings() }
        clipboardHotKeys = HotKeyController(settings: settings, slot: .clipboard) { [weak self] in self?.panel.toggleClipboard() }
        clipboardHotKeys.onOpenSettings = { [weak self] in self?.openSettings(tab: .clipboard) }

        settingsWindow = SettingsWindowController { [unowned self] navigation in
            SettingsView(settings: self.settings, navigation: navigation, hotKeys: self.hotKeys,
                         clipboardHotKeys: self.clipboardHotKeys, clipboard: self.clipboard,
                         launchAtLogin: self.launchAtLogin, updater: self.updater, query: self.query,
                         onPreview: { [weak self] in self?.panel.show() })
        }
        onboarding = OnboardingWindowController(makeView: { [unowned self] finish in
            OnboardingView(settings: self.settings, launchAtLogin: self.launchAtLogin, query: self.query,
                           onRetryModel: { AppServices.runtime?.prepare() }, onFinish: finish)
        }, onClose: { [weak self] openPanel in
            self?.settings.onboardingCompleted = true
            if openPanel { self?.panel.show() }
        })
        statusItem = StatusItemController(
            actions: .init(open: { [weak self] in self?.panel.show() },
                           settings: { [weak self] in self?.openSettings() },
                           folders: { [weak self] in self?.openSettings(tab: .folders) },
                           onboarding: { [weak self] in self?.onboarding.show() },
                           checkForUpdates: { [weak self] in self?.updater.checkForUpdates() },
                           canCheckForUpdates: { [weak self] in self?.updater.canCheckForUpdates ?? false },
                           reindex: { [weak self] in self?.reindex() }),
            launchAtLogin: launchAtLogin, settings: settings)

        if arguments.contains("--no-hotkey") {
            logger.notice("global hotkey disabled by --no-hotkey")
        } else {
            if !hotKeys.registerFromSettings(interactive: true) {
                logger.error("hotkey registration failed: \(self.hotKeys.statusText, privacy: .public)")
            }
            // Not interactive: a taken clipboard hotkey shows in Settings, without an alert at launch.
            if settings.clipboardHistoryEnabled, !clipboardHotKeys.registerFromSettings(interactive: false) {
                logger.error("clipboard hotkey registration failed: \(self.clipboardHotKeys.statusText, privacy: .public)")
            }
        }

        if !settings.onboardingCompleted {
            if isNewInstall, !arguments.contains(where: { $0.hasPrefix("--mock") }) {
                DispatchQueue.main.async { [weak self] in self?.onboarding.show() }
            } else {
                // Set up before the introduction existed: nothing to introduce.
                settings.onboardingCompleted = true
            }
        }
        if arguments.contains("--onboarding") {
            DispatchQueue.main.async { [weak self] in self?.onboarding.show() }
        }
        if arguments.contains("--show") {
            let initial = argumentValue("--query")
            DispatchQueue.main.async { [weak self] in self?.panel.show(initialQuery: initial) }
        }
        if arguments.contains("--settings") {
            let tab: SettingsTab? = switch argumentValue("--settings") {
            case "folders": .folders
            case "engine": .engine
            case "clipboard": .clipboard
            case "updates": .updates
            default: nil
            }
            DispatchQueue.main.async { [weak self] in self?.openSettings(tab: tab) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "embedsearch" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            switch url.host {
            case "toggle": panel.toggle()
            case "show": panel.show(initialQuery: q)
            case "clipboard": panel.show(mode: .clipboard)
            case "hide": panel.hide(restoreFocus: true)
            case "settings": openSettings(tab: url.path == "/folders" ? .folders : nil)
            case "welcome": onboarding.show()
            default: logger.error("unknown URL \(url.absoluteString, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.unregister()
        clipboardHotKeys?.unregister()
    }

    private func openSettings(tab: SettingsTab? = nil) {
        settingsWindow.show(tab: tab)
    }

    private func reindex() {
        guard let runtime = AppServices.runtime else { query.refreshIndex(); return }
        Task {
            do { try await runtime.reindexFiles() }
            catch {
                logger.error("reindex failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private func argumentValue(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Minimal main menu so ⌘Q/⌘W and editing shortcuts work while the Settings window is active.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "EmbedSearch 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
