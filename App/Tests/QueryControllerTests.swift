import Foundation
import SearchCore
import Testing

/// Records every call; canned results; configurable full-search latency/failure.
actor FakeSearchService: SearchService {
    struct Failure: Error {}

    private(set) var instantCalls: [String] = []
    private(set) var fullCalls: [String] = []
    private(set) var selections: [String] = []
    private var fullDelay: Duration
    private var failFull = false

    init(fullDelay: Duration = .milliseconds(20)) {
        self.fullDelay = fullDelay
    }

    func setFailFull(_ value: Bool) { failFull = value }

    func instantSearch(_ query: String, limit: Int) async -> [SearchResult] {
        instantCalls.append(query)
        return Self.results(for: query, semantic: false)
    }

    func fullSearch(_ query: String, limit: Int) async throws -> [SearchResult] {
        fullCalls.append(query)
        try await Task.sleep(for: fullDelay)
        if failFull { throw Failure() }
        return Self.results(for: query, semantic: true)
    }

    func recordSelection(itemID: String, query: String) async {
        selections.append("\(itemID)|\(query)")
    }

    func refresh() async {}

    func stateUpdates() async -> AsyncStream<EngineState> {
        AsyncStream { $0.yield(.ready(itemCount: 3)) }
    }

    static func results(for query: String, semantic: Bool) -> [SearchResult] {
        var ids = ["\(query)-1", "\(query)-2", "\(query)-3"]
        if semantic { ids.insert("\(query)-semantic", at: 0) }
        var results = ids.map { id in
            let item = SearchItem(id: id, kind: .application, title: id, subtitle: nil, keywords: [id],
                                  embeddingTitle: id, embeddingText: id, action: .openURL("https://example.com"),
                                  icon: .systemSymbol("app"))
            return SearchResult(item: item, score: 1, signals: id.hasSuffix("semantic") ? [.semantic] : [.lexical],
                                breakdown: ScoreBreakdown())
        }
        // "sections": the full search moves a loosely matching setting below the rest.
        if query == "sections", semantic {
            let item = SearchItem(id: "loose-setting", kind: .systemSetting, title: "loose", subtitle: nil, keywords: [],
                                  embeddingTitle: nil, embeddingText: "", action: .openURL("https://example.com"),
                                  icon: .systemSymbol("gear"))
            results.append(SearchResult(item: item, score: 0, signals: [.semantic], breakdown: ScoreBreakdown(), section: .settings))
        }
        return results
    }
}

/// Polls `condition` on the main actor until true or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "condition not met before timeout")
}

@MainActor
@Suite("QueryController: instant/debounced search, Enter, IME gating")
struct QueryControllerTests {
    final class OpenLog {
        var opened: [(id: String, query: String)] = []
    }

    func makeController(service: FakeSearchService, debounce: Duration = .milliseconds(80))
        -> (QueryController, OpenLog) {
        let controller = QueryController(service: service, debounce: debounce)
        let log = OpenLog()
        controller.onOpen = { result, query in log.opened.append((result.id, query)) }
        return (controller, log)
    }

    @Test func trailingSettingsGetASectionTitle() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service, debounce: .milliseconds(20))
        var layoutChanges = 0
        controller.onLayoutChange = { layoutChanges += 1 }
        controller.inputChanged(text: "sections", composing: false)
        try await waitUntil { controller.resultsAreFinal }
        #expect(controller.results.count == 5)
        #expect(controller.settingsSectionStart == 4)
        #expect(controller.displayedHeaderCount == 1)
        #expect(layoutChanges >= 2)
        controller.inputChanged(text: "other", composing: false)
        try await waitUntil { controller.resultsAreFinal && controller.resultsQuery == "other" }
        #expect(controller.settingsSectionStart == nil)
        #expect(controller.displayedHeaderCount == 0)
    }

    @Test func committedTextRunsInstantImmediatelyThenFullAfterDebounce() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service, debounce: .milliseconds(150))

        controller.inputChanged(text: "계산", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        #expect(await service.instantCalls == ["계산"])
        #expect(await service.fullCalls.isEmpty, "full search must wait for the debounce")
        #expect(controller.isStale)

        try await waitUntil { controller.resultsAreFinal }
        #expect(await service.fullCalls == ["계산"])
        #expect(!controller.isStale)
        #expect(controller.results.first?.id == "계산-semantic")
    }

    @Test func rapidTypingCancelsEarlierFullSearches() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service)

        controller.inputChanged(text: "s", composing: false)
        controller.inputChanged(text: "sa", composing: false)
        controller.inputChanged(text: "saf", composing: false)
        try await waitUntil { controller.resultsAreFinal }
        try await Task.sleep(for: .milliseconds(150))

        #expect(await service.fullCalls == ["saf"])
        #expect(controller.resultsQuery == "saf")
    }

    @Test func compositionNeverTriggersSearch() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service)

        controller.inputChanged(text: "ㅎ", composing: true)
        controller.inputChanged(text: "하", composing: true)
        controller.inputChanged(text: "한", composing: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.isComposing)
        #expect(controller.text.isEmpty)
        #expect(await service.instantCalls.isEmpty)
        #expect(await service.fullCalls.isEmpty)

        controller.inputChanged(text: "한", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        #expect(await service.instantCalls == ["한"])
    }

    @Test func enterOnStaleResultsRunsFullSearchAndDoesNotOpen() async throws {
        let service = FakeSearchService()
        let (controller, log) = makeController(service: service, debounce: .seconds(30))

        controller.inputChanged(text: "메모", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        #expect(controller.isStale)

        #expect(controller.enterPressed() == .searching)
        #expect(log.opened.isEmpty)
        try await waitUntil { controller.resultsAreFinal }
        #expect(await service.fullCalls == ["메모"], "Enter must not wait for the 30 s debounce")

        #expect(controller.enterPressed() == .opened(itemID: "메모-semantic"))
        #expect(log.opened.map(\.id) == ["메모-semantic"])
        #expect(log.opened.map(\.query) == ["메모"])
    }

    @Test func enterOnFreshResultsOpensTheSelection() async throws {
        let service = FakeSearchService()
        let (controller, log) = makeController(service: service)

        controller.inputChanged(text: "app", composing: false)
        try await waitUntil { controller.resultsAreFinal }
        controller.moveSelection(by: 1)
        #expect(controller.enterPressed() == .opened(itemID: "app-1"))
        #expect(log.opened.map(\.id) == ["app-1"])
    }

    @Test func repeatedEnterWhileFullSearchInFlightDoesNotDuplicate() async throws {
        let service = FakeSearchService(fullDelay: .milliseconds(250))
        let (controller, log) = makeController(service: service, debounce: .seconds(30))

        controller.inputChanged(text: "q", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        #expect(controller.enterPressed() == .searching)
        #expect(controller.enterPressed() == .searching)
        #expect(controller.isFullSearchRunning)
        try await waitUntil { controller.resultsAreFinal }
        #expect(await service.fullCalls == ["q"])
        #expect(log.opened.isEmpty)
    }

    @Test func compositionCommittingEnterOnlySearches() async throws {
        let service = FakeSearchService()
        let (controller, log) = makeController(service: service, debounce: .seconds(30))

        controller.inputChanged(text: "한", composing: true)
        // The IME commits on Return: the field reports committed text, then the editor reports the Return.
        controller.inputChanged(text: "한", composing: false)
        controller.composingEnterCommitted()

        try await waitUntil { controller.resultsAreFinal }
        #expect(await service.fullCalls == ["한"])
        #expect(log.opened.isEmpty, "the Return that commits Hangul must never open a result")
    }

    @Test func failedFullSearchFallsBackToLexicalSoEnterCanOpen() async throws {
        let service = FakeSearchService()
        await service.setFailFull(true)
        let (controller, log) = makeController(service: service)

        controller.inputChanged(text: "x", composing: false)
        try await waitUntil { controller.resultsAreFinal }
        #expect(controller.lastSearchError != nil)
        #expect(controller.enterPressed() == .opened(itemID: "x-1"))
        #expect(log.opened.count == 1)
    }

    @Test func commandNumberOpensVisibleRowEvenWhenStale() async throws {
        let service = FakeSearchService()
        let (controller, log) = makeController(service: service, debounce: .seconds(30))

        controller.inputChanged(text: "z", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        #expect(controller.openResult(at: 2))
        #expect(log.opened.map(\.id) == ["z-3"])
        #expect(!controller.openResult(at: 7))
    }

    @Test func selectionClampsAndResetsForNewQuery() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service, debounce: .seconds(30))

        controller.inputChanged(text: "a", composing: false)
        try await waitUntil { !controller.results.isEmpty }
        controller.moveSelection(by: -1)
        #expect(controller.selectedIndex == 0)
        controller.moveSelection(by: 10)
        #expect(controller.selectedIndex == controller.results.count - 1)

        controller.inputChanged(text: "ab", composing: false)
        try await waitUntil { controller.resultsQuery == "ab" }
        #expect(controller.selectedIndex == 0)
    }

    @Test func clearingTextClearsResultsAndCancelsSearch() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service)
        var layoutChanges = 0
        controller.onLayoutChange = { layoutChanges += 1 }

        controller.inputChanged(text: "a", composing: false)
        controller.inputChanged(text: "", composing: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.results.isEmpty)
        #expect(controller.displayedRowCount == 0)
        #expect(await service.fullCalls.isEmpty)
        #expect(controller.enterPressed() == .ignored)
        #expect(layoutChanges >= 2) // placeholder row appeared, then went away
    }

    @Test func recordSelectionReachesTheService() async throws {
        let service = FakeSearchService()
        let (controller, _) = makeController(service: service)
        controller.inputChanged(text: "a", composing: false)
        try await waitUntil { controller.resultsAreFinal }
        controller.recordSelection(controller.results[0], query: "a")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.selections == ["a-semantic|a"])
    }
}

@Suite("Display strings")
struct DisplayTextTests {
    @Test func engineStateStrings() {
        #expect(DisplayText.engineState(.loadingModel(progress: 0.37)) == "모델 불러오는 중 37%")
        #expect(DisplayText.engineState(.indexing(done: 120, total: 900)) == "색인 중 120/900")
        #expect(DisplayText.engineState(.ready(itemCount: 812)) == "준비됨 · 812개")
        #expect(DisplayText.engineState(.degraded(reason: "x")) == "의미 검색 사용 불가 – 키워드 검색만")
    }

    @Test func semanticChipOnlyWithoutLexical() {
        #expect(DisplayText.isSemanticOnly([.semantic]))
        #expect(DisplayText.isSemanticOnly([.semantic, .frecency]))
        #expect(!DisplayText.isSemanticOnly([.semantic, .lexical]))
        #expect(!DisplayText.isSemanticOnly([.lexical]))
    }
}
