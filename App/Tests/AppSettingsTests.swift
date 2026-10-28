import Foundation
import Testing

@Suite("History settings")
@MainActor
struct AppSettingsTests {
    @Test func historyPolicyPersistsAcrossSettingsInstances() throws {
        let name = "embedsearch-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.searchHistoryEnabled)
        #expect(settings.searchHistoryRetentionDays == 30)
        settings.searchHistoryEnabled = false
        settings.searchHistoryRetentionDays = 7
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.searchHistoryEnabled)
        #expect(reopened.searchHistoryRetentionDays == 7)
    }
}
