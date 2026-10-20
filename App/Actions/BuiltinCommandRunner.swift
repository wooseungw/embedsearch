import AppKit
import Carbon.HIToolbox

/// Executes `ItemAction.builtinCommand(id:)` for every id listed in docs/DESIGN.md.
/// Confirmation for destructive ids happens in `ActionRunner` before this is called.
@MainActor
struct BuiltinCommandRunner {
    enum CommandError: Error, CustomStringConvertible {
        case unknown(String)
        var description: String {
            switch self {
            case .unknown(let id): return "알 수 없는 명령: \(id)"
            }
        }
    }

    static let supportedIDs: Set<String> = [
        "lock-screen", "sleep", "display-sleep", "screen-saver", "restart", "shut-down", "log-out",
        "empty-trash", "toggle-dark-mode", "toggle-mute", "volume-up", "volume-down", "screenshot",
        "toggle-hidden-files", "open-downloads", "open-desktop", "open-documents", "open-home",
        "eject-all", "restart-finder", "restart-dock", "clipboard-history",
    ]

    func run(_ id: String) async throws {
        switch id {
        case "lock-screen":
            try await lockScreen()
        case "sleep":
            try await Shell.run("/usr/bin/pmset", ["sleepnow"])
        case "display-sleep":
            try await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        case "screen-saver":
            try await openApplication("/System/Library/CoreServices/ScreenSaverEngine.app")
        case "restart":
            try sendToLoginWindow(AEEventID(kAERestart))
        case "shut-down":
            try sendToLoginWindow(AEEventID(kAEShutDown))
        case "log-out":
            try sendToLoginWindow(AEEventID(kAEReallyLogOut))
        case "empty-trash":
            try await Shell.osascript(#"tell application "Finder" to empty trash"#)
        case "toggle-dark-mode":
            try await Shell.osascript(
                #"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#)
        case "toggle-mute":
            try await Shell.osascript("set volume output muted (not (output muted of (get volume settings)))")
        case "volume-up":
            try await Shell.osascript("set volume output volume ((output volume of (get volume settings)) + 6.25)")
        case "volume-down":
            try await Shell.osascript("set volume output volume ((output volume of (get volume settings)) - 6.25)")
        case "screenshot":
            try await openApplication("/System/Applications/Utilities/Screenshot.app")
        case "toggle-hidden-files":
            try await toggleHiddenFiles()
        case "open-downloads":
            openDirectory(.downloadsDirectory)
        case "open-desktop":
            openDirectory(.desktopDirectory)
        case "open-documents":
            openDirectory(.documentDirectory)
        case "open-home":
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        case "eject-all":
            try await ejectAll()
        case "restart-finder":
            try await Shell.run("/usr/bin/killall", ["Finder"])
        case "restart-dock":
            try await Shell.run("/usr/bin/killall", ["Dock"])
        case "clipboard-history":
            break // the panel switches to its clipboard mode before an action would run (`LauncherPanelController.open`)
        default:
            throw CommandError.unknown(id)
        }
    }

    // MARK: Implementations

    /// `SACLockScreenImmediate` (login.framework) is what launchers use for "Lock Screen";
    /// fall back to sleeping the display, which locks when a password is required after sleep.
    private func lockScreen() async throws {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunction = @convention(c) () -> Int32
            let lock = unsafeBitCast(symbol, to: LockFunction.self)
            if lock() == 0 { return }
        }
        try await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Apple QA1134: restart / shut down / log out via Apple events to loginwindow.
    /// The "really" variants skip loginwindow's own dialog because the launcher already confirmed.
    private func sendToLoginWindow(_ eventID: AEEventID) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        try event.sendEvent(options: [.noReply], timeout: TimeInterval(kAEDefaultTimeout))
    }

    private func openApplication(_ path: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    private func openDirectory(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleHiddenFiles() async throws {
        let current = (try? await Shell.run("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = ["1", "true", "yes"].contains(current ?? "")
        try await Shell.run("/usr/bin/defaults",
                            ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shown ? "false" : "true"])
        try await Shell.run("/usr/bin/killall", ["Finder"])
    }

    private func ejectAll() async throws {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        let ejectable = volumes.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
        }
        try await Task.detached {
            for url in ejectable {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            }
        }.value
    }
}
