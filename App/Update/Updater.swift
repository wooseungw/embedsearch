import AppKit
import Observation
import Sparkle

/// App updates with Sparkle (feed URL and public key in project.yml). Checks the latest GitHub release
/// once a day, downloads a newer version silently and installs it when the app quits; while a
/// downloaded update waits, Sparkle asks every 7 days. `checkForUpdates()` checks now, or offers a
/// downloaded update to install and relaunch.
@MainActor
@Observable
final class Updater: NSObject {
    /// Background checks and silent downloads together: Settings has one switch for both.
    private(set) var isAutomatic = false
    /// False while Sparkle's own session runs (a check or a silent download), when a check does nothing.
    private(set) var canCheckForUpdates = false
    let version: String
    /// Off for `--mock` runs: installing an update relaunches the app without its arguments.
    let isEnabled: Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var showingModalAlert = false
    /// Sparkle windows already moved to the screen in use: each moves once, then stays where the user puts it.
    @ObservationIgnored private let placed = NSHashTable<NSWindow>.weakObjects()

    init(enabled: Bool) {
        let info = Bundle.main.infoDictionary ?? [:]
        version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        isEnabled = enabled
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: self)
        // Sparkle changes these on the main thread. The two settings also change from its update
        // alert (its "automatically download" box).
        let refresh: @Sendable (SPUUpdater, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial], changeHandler: refresh),
            updater.observe(\.automaticallyChecksForUpdates, changeHandler: refresh),
            updater.observe(\.automaticallyDownloadsUpdates, changeHandler: refresh),
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    private var updater: SPUUpdater { controller.updater }

    private func refresh() {
        isAutomatic = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        canCheckForUpdates = isEnabled && updater.canCheckForUpdates
    }

    func setAutomatic(_ automatic: Bool) {
        updater.automaticallyChecksForUpdates = automatic
        updater.automaticallyDownloadsUpdates = automatic
        isAutomatic = automatic
    }

    func checkForUpdates() {
        guard isEnabled else { return }
        controller.checkForUpdates(nil)
    }

    // Sparkle centers its windows on the main display; like every other window of the app they go to
    // the screen in use (`ActiveScreen`).

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if isSparkle(window) {
            place(window)
        } else if showingModalAlert, window.windowController == nil {
            // The alert, which has no window controller. Only the first one: when it closes, the
            // window that becomes key next is the app's own.
            showingModalAlert = false
            place(window)
        }
    }

    private func place(_ window: NSWindow) {
        guard !placed.contains(window) else { return }
        placed.add(window)
        let screen = ActiveScreen.current
        if window.screen != screen {
            window.setFrameOrigin(ActiveScreen.origin(for: window.frame.size, on: screen))
        }
    }

    private func isSparkle(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController else { return false }
        return Bundle(for: type(of: controller)) == Bundle(for: SPUStandardUpdaterController.self)
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    /// Scheduled reminders are handled in `standardUserDriverWillHandleShowingUpdate`; without this a
    /// dockless app gets a warning in the log.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        // A scheduled reminder opens without becoming key, behind the active app's windows: bring it
        // forward on the screen in use once it is up, still without taking focus. Not while the user
        // works in a window of this app, where Sparkle puts it behind on purpose.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows where window.isVisible && self.isSparkle(window) {
                self.place(window)
                if !(NSApp.isActive && NSApp.keyWindow != nil) { window.orderFrontRegardless() }
            }
        }
    }

    func standardUserDriverWillShowModalAlert() { showingModalAlert = true }
    func standardUserDriverDidShowModalAlert() { showingModalAlert = false }
}
