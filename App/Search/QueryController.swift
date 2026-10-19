import Foundation
import Observation
import SearchCore

/// Owns the query → results pipeline described in docs/DESIGN.md:
/// - every *committed* text change (never while Hangul is composing) runs `instantSearch` at once and
///   schedules `fullSearch` after a debounce, cancelling the previous scheduled/in-flight full search;
/// - Enter on stale results (no finished full search for exactly the current text) runs `fullSearch`
///   now and does not open; Enter on fresh results opens the selection;
/// - the Enter that commits an IME composition only commits + searches.
@MainActor
@Observable
final class QueryController {
    enum EnterOutcome: Equatable {
        case ignored
        case searching
        case opened(itemID: String)
    }

    /// Committed text: what searches run on. Excludes in-progress marked text.
    private(set) var text = ""
    private(set) var isComposing = false
    private(set) var results: [SearchResult] = []
    /// The query `results` belong to.
    private(set) var resultsQuery = ""
    /// `results` came from a finished `fullSearch` (or its fallback) for `resultsQuery`.
    private(set) var resultsAreFinal = false
    private(set) var selectedIndex = 0
    private(set) var isFullSearchRunning = false
    private(set) var engineState: EngineState = .idle
    private(set) var lastSearchError: String?

    /// Visible results are not the finished hybrid results for the current text.
    var isStale: Bool { !text.isEmpty && !(resultsAreFinal && resultsQuery == text) }

    var selectedResult: SearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Rows the list shows: results, or one placeholder row ("검색 중…"/"결과 없음") for a non-empty query.
    var displayedRowCount: Int {
        if !results.isEmpty { return results.count }
        return text.isEmpty ? 0 : 1
    }

    /// Index of the first result of the trailing settings section (settings that matched only
    /// loosely, listed after the files), if the results have one.
    var settingsSectionStart: Int? {
        guard let index = results.firstIndex(where: { $0.section == .settings }), index > 0 else { return nil }
        return index
    }

    /// Section titles the list shows above the rows.
    var displayedHeaderCount: Int { settingsSectionStart == nil ? 0 : 1 }

    /// Called when the user opens a result (Enter on fresh results, ⌘1–9, click).
    @ObservationIgnored var onOpen: ((SearchResult, _ query: String) -> Void)?
    /// Called after anything that changes the panel's height (row count).
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    let service: any SearchService
    private let debounce: Duration
    private let limit: Int
    @ObservationIgnored private var instantTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    /// Query of the full search that is past its debounce and waiting on the service.
    @ObservationIgnored private var inFlightFullQuery: String?
    @ObservationIgnored private var fullSearchGeneration = 0
    @ObservationIgnored private var selectionTouched = false
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var reportedLayout = (rows: 0, headers: 0)

    init(service: any SearchService, debounce: Duration = .milliseconds(200), limit: Int = 50) {
        self.service = service
        self.debounce = debounce
        self.limit = limit
    }

    // MARK: - Engine state

    func startObservingEngine() {
        guard engineTask == nil else { return }
        let service = service
        engineTask = Task { [weak self] in
            for await state in await service.stateUpdates() {
                self?.engineState = state
            }
        }
    }

    func refreshIndex() {
        let service = service
        Task { await service.refresh() }
    }

    // MARK: - Input

    /// Every text or marked-text change of the search field. `text` includes marked text while composing.
    func inputChanged(text newText: String, composing: Bool) {
        isComposing = composing
        guard !composing, newText != text else { return }
        text = newText
        selectionTouched = false
        cancelFullSearch()
        instantTask?.cancel()

        if newText.isEmpty {
            instantTask = nil
            setResults([], query: "", final: false)
        } else {
            runInstantSearch(newText)
            scheduleFullSearch(newText)
        }
        reportLayoutIfNeeded()
    }

    /// Enter that committed an IME composition: the commit already updated `text`; search, never open.
    func composingEnterCommitted() {
        guard !isComposing, !text.isEmpty else { return }
        if !(resultsAreFinal && resultsQuery == text) {
            runFullSearchNow(text)
        }
    }

    @discardableResult
    func enterPressed() -> EnterOutcome {
        guard !isComposing, !text.isEmpty else { return .ignored }
        if isStale {
            runFullSearchNow(text)
            return .searching
        }
        guard let result = selectedResult else { return .ignored }
        onOpen?(result, text)
        return .opened(itemID: result.id)
    }

    /// ⌘1–9 and clicks: open what is visible, stale or not.
    @discardableResult
    func openResult(at index: Int) -> Bool {
        guard !isComposing, results.indices.contains(index) else { return false }
        selectedIndex = index
        onOpen?(results[index], text)
        return true
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        selectionTouched = true
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        selectionTouched = true
    }

    func recordSelection(_ result: SearchResult, query: String) {
        let service = service
        let itemID = result.id
        Task { await service.recordSelection(itemID: itemID, query: query) }
    }

    /// Clears everything (panel hidden or Esc on a non-empty query).
    func reset() {
        instantTask?.cancel()
        instantTask = nil
        cancelFullSearch()
        isComposing = false
        text = ""
        lastSearchError = nil
        setResults([], query: "", final: false)
        reportLayoutIfNeeded()
    }

    // MARK: - Search tasks

    private func runInstantSearch(_ query: String) {
        let service = service
        let limit = limit
        instantTask = Task { [weak self] in
            let found = await service.instantSearch(query, limit: limit)
            guard let self, !Task.isCancelled, self.text == query else { return }
            // A finished full search for the same text wins over a late instant result.
            if self.resultsAreFinal && self.resultsQuery == query { return }
            self.setResults(found, query: query, final: false)
        }
    }

    private func scheduleFullSearch(_ query: String) {
        let debounce = debounce
        fullTask = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled, self.text == query else { return }
            let generation = self.beginFullSearch(query)
            await self.performFullSearch(query, generation: generation)
        }
    }

    private func runFullSearchNow(_ query: String) {
        if inFlightFullQuery == query { return } // already waiting on the service for exactly this text
        cancelFullSearch()
        let generation = beginFullSearch(query)
        fullTask = Task { [weak self] in
            await self?.performFullSearch(query, generation: generation)
        }
    }

    /// Marks a full search for `query` as in flight (synchronously, so a second Enter sees it).
    private func beginFullSearch(_ query: String) -> Int {
        fullSearchGeneration += 1
        inFlightFullQuery = query
        isFullSearchRunning = true
        return fullSearchGeneration
    }

    private func performFullSearch(_ query: String, generation: Int) async {
        defer {
            if fullSearchGeneration == generation {
                inFlightFullQuery = nil
                isFullSearchRunning = false
            }
        }

        let service = service
        let limit = limit
        let found: [SearchResult]
        do {
            found = try await service.fullSearch(query, limit: limit)
            if fullSearchGeneration == generation { lastSearchError = nil }
        } catch {
            guard !Task.isCancelled else { return }
            // Semantic path failed: fall back to lexical so Enter can still open something.
            found = await service.instantSearch(query, limit: limit)
            if fullSearchGeneration == generation { lastSearchError = String(describing: error) }
        }
        guard !Task.isCancelled, fullSearchGeneration == generation, text == query else { return }
        setResults(found, query: query, final: true)
    }

    private func cancelFullSearch() {
        fullTask?.cancel()
        fullTask = nil
        fullSearchGeneration += 1
        inFlightFullQuery = nil
        isFullSearchRunning = false
    }

    private func setResults(_ newResults: [SearchResult], query: String, final: Bool) {
        let keepID = selectionTouched ? selectedResult?.id : nil
        results = newResults
        resultsQuery = query
        resultsAreFinal = final
        if let keepID, let index = newResults.firstIndex(where: { $0.id == keepID }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
            selectionTouched = false
        }
        reportLayoutIfNeeded()
    }

    private func reportLayoutIfNeeded() {
        let layout = (rows: displayedRowCount, headers: displayedHeaderCount)
        guard layout != reportedLayout else { return }
        reportedLayout = layout
        onLayoutChange?()
    }
}
