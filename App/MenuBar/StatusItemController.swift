import AppKit

/// Menu bar item: 열기, 설정…, 검색 폴더…, 다시 색인, 로그인 시 실행, 종료.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var open: () -> Void
        var settings: () -> Void
        var folders: () -> Void
        var reindex: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: Actions
    private let launchAtLogin: LaunchAtLogin
    private let settings: AppSettings

    init(actions: Actions, launchAtLogin: LaunchAtLogin, settings: AppSettings) {
        self.actions = actions
        self.launchAtLogin = launchAtLogin
        self.settings = settings
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "EmbedSearch")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLogin.refresh()
        menu.removeAllItems()
        menu.addItem(item("열기 (\(settings.hotKey.displayString))", #selector(openPanel)))
        menu.addItem(item("설정…", #selector(openSettings), key: ","))
        menu.addItem(item("검색 폴더…", #selector(openFolders)))
        menu.addItem(.separator())
        menu.addItem(item("다시 색인", #selector(reindex)))
        let login = item(launchAtLogin.status == .requiresApproval ? "로그인 시 실행 (승인 필요)" : "로그인 시 실행",
                         #selector(toggleLaunchAtLogin))
        login.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("EmbedSearch 종료", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPanel() {
        // Let the menu finish closing so the panel can become key.
        DispatchQueue.main.async { self.actions.open() }
    }

    @objc private func openSettings() { actions.settings() }
    @objc private func openFolders() { actions.folders() }
    @objc private func reindex() { actions.reindex() }

    @objc private func toggleLaunchAtLogin() {
        let enable = !launchAtLogin.isEnabled
        launchAtLogin.setEnabled(enable)
        if enable && launchAtLogin.status == .requiresApproval {
            launchAtLogin.openSystemSettings()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
