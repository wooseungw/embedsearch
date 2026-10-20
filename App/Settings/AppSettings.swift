import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var hotKey: KeyCombo {
        didSet { save(hotKey, forKey: Keys.hotKey) }
    }
    var panelStyle: PanelStyle {
        didSet { defaults.set(panelStyle.rawValue, forKey: Keys.panelStyle) }
    }
    var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: Keys.panelWidth) }
    }
    /// Folders whose images and PDFs are searchable (paths).
    var searchFolders: [String] {
        didSet { defaults.set(searchFolders, forKey: Keys.searchFolders) }
    }
    /// Keep the last copied texts (in memory only, `ClipboardHistory`).
    var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: Keys.clipboardHistoryEnabled) }
    }
    /// Opens the panel on the clipboard history.
    var clipboardHotKey: KeyCombo {
        didSet { save(clipboardHotKey, forKey: Keys.clipboardHotKey) }
    }
    /// The first-launch introduction was shown (or the app was set up before it existed).
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hotKey = "hotKey"
        static let panelStyle = "panelStyle"
        static let panelWidth = "panelWidth"
        static let searchFolders = "searchFolders"
        static let clipboardHistoryEnabled = "clipboardHistoryEnabled"
        static let clipboardHotKey = "clipboardHotKey"
        static let onboardingCompleted = "onboardingCompleted"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.hotKey),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            hotKey = combo
        } else {
            hotKey = .default
        }
        panelStyle = defaults.string(forKey: Keys.panelStyle).flatMap(PanelStyle.init(rawValue:)) ?? .notch
        let width = defaults.double(forKey: Keys.panelWidth)
        panelWidth = width > 0
            ? min(max(width, PanelLayout.panelWidthRange.lowerBound), PanelLayout.panelWidthRange.upperBound)
            : PanelLayout.defaultPanelWidth
        searchFolders = defaults.stringArray(forKey: Keys.searchFolders) ?? []
        clipboardHistoryEnabled = defaults.object(forKey: Keys.clipboardHistoryEnabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.clipboardHotKey),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            clipboardHotKey = combo
        } else {
            clipboardHotKey = .clipboardDefault
        }
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
    }

    private func save(_ combo: KeyCombo, forKey key: String) {
        if let data = try? JSONEncoder().encode(combo) { defaults.set(data, forKey: key) }
    }
}
