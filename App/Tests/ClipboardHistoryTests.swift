import AppKit
import SearchCore
import Testing

@Suite("ClipboardQueue: FIFO with reuse moving to the end")
struct ClipboardQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func dropsTheOldestPastCapacity() {
        var queue = ClipboardQueue(capacity: 3)
        for (i, text) in ["a", "b", "c", "d"].enumerated() { queue.add(text, at: t0 + Double(i)) }
        #expect(queue.entries.map(\.text) == ["b", "c", "d"])
        #expect(queue.newestFirst.map(\.text) == ["d", "c", "b"])
    }

    @Test func copyingAgainMovesToTheEndWithoutADuplicate() {
        var queue = ClipboardQueue(capacity: 3)
        queue.add("a", at: t0)
        queue.add("b", at: t0 + 1)
        let firstID = queue.entries[0].id
        queue.add("a", at: t0 + 2)
        #expect(queue.entries.map(\.text) == ["b", "a"])
        #expect(queue.entries[1].id == firstID)
        #expect(queue.entries[1].copiedAt == t0 + 2)
        // Moved to the end, "a" is no longer the next to go.
        queue.add("c", at: t0 + 3)
        queue.add("d", at: t0 + 4)
        #expect(queue.entries.map(\.text) == ["a", "c", "d"])
    }

    @Test func usingAnEntryMovesItToTheEnd() {
        var queue = ClipboardQueue(capacity: 3)
        for (i, text) in ["a", "b", "c"].enumerated() { queue.add(text, at: t0 + Double(i)) }
        let a = queue.entries[0]
        #expect(queue.use(id: a.id, at: t0 + 9)?.text == "a")
        #expect(queue.entries.map(\.text) == ["b", "c", "a"])
        queue.add("d", at: t0 + 10)
        #expect(queue.entries.map(\.text) == ["c", "a", "d"])
        #expect(queue.use(id: 999, at: t0) == nil)
        queue.remove(id: a.id)
        #expect(queue.entries.map(\.text) == ["c", "d"])
        queue.removeAll()
        #expect(queue.entries.isEmpty)
    }

    @Test func rowsAreWorkedOutOnceAndMatchedByBytes() {
        var queue = ClipboardQueue(capacity: 3)
        queue.add("\n  \n  First   line here\nsecond\nthird", at: t0)
        #expect(queue.entries[0].title == "First line here")
        #expect(queue.entries[0].lineCount == 5)
        let bytes = queue.entries[0].normalized
        #expect(ClipboardQueue.contains(bytes, Array("line here".utf8)))
        #expect(!ClipboardQueue.contains(bytes, Array("lines".utf8)))
        #expect(ClipboardQueue.contains(bytes, []))
        #expect(!ClipboardQueue.contains([], Array("a".utf8)))
    }
}

@MainActor
@Suite("ClipboardHistory: what is recorded and how it is found")
struct ClipboardHistoryTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("embedsearch-test-\(UUID().uuidString)"))
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard, extra: [NSPasteboard.PasteboardType] = []) {
        pasteboard.declareTypes([.string] + extra, owner: nil)
        pasteboard.setString(text, forType: .string)
        for type in extra { pasteboard.setData(Data(), forType: type) }
    }

    @Test func recordsTextChangesButNotSecretsFilesOrBlanks() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        copy("already there", to: pasteboard)
        let history = ClipboardHistory(pasteboard: pasteboard)
        history.setEnabled(true)
        defer { history.setEnabled(false) }
        #expect(history.queue.entries.map(\.text) == ["already there"])

        copy("hello world", to: pasteboard)
        history.poll()
        history.poll() // no change since: nothing added
        copy("hunter2", to: pasteboard, extra: [.init("org.nspasteboard.ConcealedType")])
        history.poll()
        copy("report.pdf", to: pasteboard, extra: [.fileURL])
        history.poll()
        copy("   \n\t", to: pasteboard)
        history.poll()
        copy(String(repeating: "x", count: ClipboardHistory.maxCharacters + 1), to: pasteboard)
        history.poll()
        #expect(history.queue.entries.map(\.text) == ["already there", "hello world"])

        // Turned off, it forgets and stops looking.
        history.setEnabled(false)
        #expect(history.count == 0)
        copy("after", to: pasteboard)
        history.poll()
        #expect(history.count == 0)
    }

    @Test func findsEntriesByTheirWordsNewestFirst() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: pasteboard)
        let now = Date()
        history.record("회의는 목요일 3시로 옮겼습니다", at: now - 7200)
        history.record("https://arxiv.org/abs/2406.01234", at: now - 120)
        history.record("ssh dev@build-server", at: now - 5)
        history.record("다음 회의 안건\n1. 예산\n2. 일정", at: now)

        #expect(history.results(matching: "", limit: 10, now: now).map(\.item.title)
                == ["다음 회의 안건", "ssh dev@build-server", "https://arxiv.org/abs/2406.01234", "회의는 목요일 3시로 옮겼습니다"])
        // A particle on the query word, every word required, case and punctuation ignored.
        #expect(history.results(matching: "회의는", limit: 10, now: now).count == 2)
        #expect(history.results(matching: "회의 목요일", limit: 10, now: now).map(\.item.title) == ["회의는 목요일 3시로 옮겼습니다"])
        #expect(history.results(matching: "ARXIV.org", limit: 10, now: now).count == 1)
        #expect(history.results(matching: "build", limit: 1, now: now).first?.item.action == .copyText("ssh dev@build-server"))
        #expect(history.results(matching: "x", limit: 10, minimumQueryLength: 2, now: now).isEmpty)

        let first = history.results(matching: "", limit: 1, now: now)[0]
        #expect(first.item.kind == .clipboard)
        #expect(first.item.subtitle == "방금 · 3줄")
        #expect(history.results(matching: "회의는", limit: 10, now: now).last?.item.subtitle == "2시간 전")
    }

    @Test func choosingAnEntryMakesItTheNewest() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: pasteboard)
        history.record("one")
        history.record("two")
        let one = history.results(matching: "one", limit: 1)[0]
        history.use(itemID: one.id)
        #expect(history.results(matching: "", limit: 10).map(\.item.title) == ["one", "two"])
        history.remove(itemID: one.id)
        #expect(history.results(matching: "", limit: 10).map(\.item.title) == ["two"])
    }

    @Test func normalSearchListsMatchingEntriesAfterTheTopResultsAndKeepsThemOutOfTheIndex() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: pasteboard)
        for i in 1...5 { history.record("meeting note \(i)") }
        let base = FakeSearchService(fullDelay: .zero)
        let merged = MergedSearchService(base: base, history: history)

        // The full search has 4 results: the newest 3 matching entries come after the first 3.
        let found = try await merged.fullSearch("meeting", limit: 10)
        #expect(found.map(\.item.title) == ["meeting-semantic", "meeting-1", "meeting-2",
                                             "meeting note 5", "meeting note 4", "meeting note 3", "meeting-3"])
        #expect(found.allSatisfy { $0.section == .main })
        #expect(await merged.instantSearch("m", limit: 10).count == 3)

        let clip = found[3]
        await merged.recordSelection(itemID: clip.id, query: "meeting")
        await merged.recordSelection(itemID: "meeting-1", query: "meeting")
        #expect(await base.selections == ["meeting-1|meeting"])
    }
}

@Suite("MergedSearchService.merge")
struct MergeTests {
    private func result(_ id: String, _ section: ResultSection = .main) -> SearchResult {
        let item = SearchItem(id: id, kind: section == .settings ? .systemSetting : .application, title: id, subtitle: nil,
                              keywords: [], embeddingTitle: nil, embeddingText: "", action: .openURL("x"), icon: .systemSymbol("x"))
        return SearchResult(item: item, score: 0, signals: [.lexical], breakdown: ScoreBreakdown(), section: section)
    }

    @Test func clipsGoAfterTheFirstThreeMainResultsAndBeforeTrailingSettings() {
        let clips = [result("c1"), result("c2")]
        let many = ["a", "b", "c", "d", "e"].map { result($0) } + [result("s", .settings)]
        #expect(MergedSearchService.merge(many, clips).map(\.id) == ["a", "b", "c", "c1", "c2", "d", "e", "s"])
        let few = [result("a"), result("s", .settings)]
        #expect(MergedSearchService.merge(few, clips).map(\.id) == ["a", "c1", "c2", "s"])
        #expect(MergedSearchService.merge([], clips).map(\.id) == ["c1", "c2"])
        #expect(MergedSearchService.merge(many, []).map(\.id) == many.map(\.id))
    }
}

@MainActor
@Suite("QueryController: clipboard mode")
struct QueryControllerClipboardTests {
    private func makeHistory(_ texts: [String] = []) -> ClipboardHistory {
        let history = ClipboardHistory(pasteboard: NSPasteboard(name: NSPasteboard.Name("embedsearch-test-\(UUID().uuidString)")))
        for text in texts { history.record(text) }
        return history
    }

    @Test func clipboardModeListsEverythingAndOpensWithoutWaiting() async throws {
        let history = makeHistory(["first copy", "second copy"])
        let base = FakeSearchService()
        let controller = QueryController(service: base, clipboardService: ClipboardSearchService(history: history),
                                         debounce: .milliseconds(100))
        var opened: [String] = []
        controller.onOpen = { result, _ in opened.append(result.item.title) }

        controller.setMode(.clipboard)
        try await waitUntil { controller.results.count == 2 }
        #expect(controller.results.map(\.item.title) == ["second copy", "first copy"])
        // Nothing typed: Enter takes the selection.
        #expect(controller.enterPressed() == .opened(itemID: controller.results[0].id))

        // Typed: the instant results are final, so Enter opens without a second search.
        controller.inputChanged(text: "first", composing: false)
        try await waitUntil { controller.resultsQuery == "first" }
        #expect(controller.resultsAreFinal && !controller.isStale)
        #expect(controller.results.map(\.item.title) == ["first copy"])
        controller.enterPressed()
        #expect(opened == ["second copy", "first copy"])
        // Past the normal debounce: nothing typed in clipboard mode reached the index.
        try await Task.sleep(for: .milliseconds(250))
        #expect(await base.instantCalls.isEmpty)
        #expect(await base.fullCalls.isEmpty)

        // Hiding the panel goes back to the normal search.
        controller.reset()
        #expect(controller.mode == .search)
        #expect(controller.results.isEmpty && controller.displayedRowCount == 0)
    }

    @Test func switchingModesSearchesWhatIsTyped() async throws {
        let history = makeHistory(["first copy", "second copy"])
        let base = FakeSearchService(fullDelay: .milliseconds(5))
        let controller = QueryController(service: base, clipboardService: ClipboardSearchService(history: history),
                                         debounce: .milliseconds(10))
        controller.inputChanged(text: "first", composing: false)
        try await waitUntil { controller.resultsAreFinal && controller.resultsQuery == "first" }
        #expect(controller.results.first?.id == "first-semantic")

        // ⇥: the same text, in the clipboard history.
        controller.setMode(.clipboard)
        try await waitUntil { controller.results.first?.item.kind == .clipboard }
        #expect(controller.results.map(\.item.title) == ["first copy"])
        #expect(controller.resultsAreFinal && !controller.isStale)

        // ⇥ again: back to the search, run for that text.
        controller.setMode(.search)
        try await waitUntil { controller.resultsAreFinal && controller.mode == .search }
        #expect(controller.results.first?.id == "first-semantic")
        #expect(await base.fullCalls == ["first", "first"])
    }

    @Test func deletingAnEntryKeepsTheSelectionInPlace() async throws {
        let history = makeHistory(["a", "b", "c", "d"])
        let controller = QueryController(service: FakeSearchService(), clipboardService: ClipboardSearchService(history: history))
        controller.setMode(.clipboard)
        try await waitUntil { controller.results.count == 4 }
        controller.moveSelection(by: 2)
        #expect(controller.selectedResult?.item.title == "b")
        // What ⌃X does: the entry leaves the history and the row leaves the list.
        let id = try #require(controller.selectedResult?.id)
        history.remove(itemID: id)
        controller.dropResult(id: id)
        #expect(controller.results.map(\.item.title) == ["d", "c", "a"])
        #expect(controller.selectedResult?.item.title == "a")
        let next = try #require(controller.selectedResult?.id)
        history.remove(itemID: next)
        controller.dropResult(id: next)
        #expect(controller.selectedResult?.item.title == "c")
    }

    @Test func aFullSearchUnderWayDoesNotLandInClipboardMode() async throws {
        let history = makeHistory(["query text", "other"])
        let base = FakeSearchService(fullDelay: .milliseconds(150))
        let controller = QueryController(service: base, clipboardService: ClipboardSearchService(history: history),
                                         debounce: .milliseconds(10))
        controller.inputChanged(text: "query", composing: false)
        try await waitUntil { controller.isFullSearchRunning }
        controller.setMode(.clipboard)
        try await Task.sleep(for: .milliseconds(250))
        #expect(controller.mode == .clipboard)
        #expect(controller.results.map(\.item.title) == ["query text"])
    }

    @Test func anEmptyHistoryShowsAPlaceholderRow() async throws {
        let history = makeHistory()
        let controller = QueryController(service: FakeSearchService(), clipboardService: ClipboardSearchService(history: history))
        controller.setMode(.clipboard)
        try await waitUntil { controller.resultsAreFinal }
        #expect(controller.results.isEmpty)
        #expect(controller.displayedRowCount == 1)
    }
}
