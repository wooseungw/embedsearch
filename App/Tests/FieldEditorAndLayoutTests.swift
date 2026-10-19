import AppKit
import Carbon.HIToolbox
import SearchCore
import Testing

@MainActor
@Suite("LauncherFieldEditor: Hangul composition reporting and key routing")
struct LauncherFieldEditorTests {
    private let noReplacement = NSRange(location: NSNotFound, length: 0)

    private func mark(_ editor: LauncherFieldEditor, _ text: String) {
        editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: noReplacement)
    }

    /// Replays what the 2-Set Korean IME sends for typing "한글": marked ㅎ→하→한, commit 한 + mark ㄱ,
    /// marked 그→글, commit 글.
    @Test func hangulTypingReportsCompositionAndCommitsWithoutDroppingJamo() async throws {
        let editor = LauncherFieldEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        var events: [String] = []
        editor.onInputChange = { text, composing in events.append("\(text)|\(composing)") }

        mark(editor, "ㅎ")
        mark(editor, "하")
        mark(editor, "한")
        editor.insertText("한", replacementRange: noReplacement)
        mark(editor, "ㄱ")
        mark(editor, "그")
        mark(editor, "글")
        editor.insertText("글", replacementRange: noReplacement)

        #expect(editor.string == "한글")
        #expect(!editor.hasMarkedText())
        #expect(events.contains("ㅎ|true"))
        #expect(events.contains("한ㄱ|true"))
        #expect(events.last == "한글|false")
        let committed = events.filter { $0.hasSuffix("|false") }.map { $0.dropLast(6) }
        #expect(Set(committed) == ["한", "한글"], "only syllable commits are reported as non-composing")
    }

    @Test func controllerOnlySearchesCommittedHangul() async throws {
        let service = FakeSearchService()
        let controller = QueryController(service: service, debounce: .seconds(30))
        let editor = LauncherFieldEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        editor.onInputChange = { text, composing in controller.inputChanged(text: text, composing: composing) }

        mark(editor, "ㄱ")
        mark(editor, "계")
        editor.insertText("계", replacementRange: noReplacement)
        mark(editor, "ㅅ")
        mark(editor, "사")
        mark(editor, "산")
        editor.insertText("산", replacementRange: noReplacement)
        try await waitUntil { controller.resultsQuery == "계산" }

        #expect(await service.instantCalls == ["계", "계산"])
        #expect(controller.text == "계산")
    }

    @Test func returnWhileComposingIsSwallowedAndReportedAsCommit() {
        let editor = LauncherFieldEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        var commands: [Selector] = []
        var composingReturns = 0
        editor.onCommand = { selector in commands.append(selector); return true }
        editor.onComposingReturn = { composingReturns += 1 }

        mark(editor, "한")
        editor.keyDown(with: Self.key(kVK_Return, characters: "\r"))
        #expect(composingReturns == 1)
        #expect(!commands.contains(#selector(NSResponder.insertNewline(_:))))
    }

    @Test func returnWithoutCompositionReachesTheCommandHandler() {
        let editor = LauncherFieldEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        var commands: [Selector] = []
        var composingReturns = 0
        editor.onCommand = { selector in commands.append(selector); return true }
        editor.onComposingReturn = { composingReturns += 1 }

        editor.insertText("한", replacementRange: noReplacement)
        editor.keyDown(with: Self.key(kVK_Return, characters: "\r"))
        #expect(composingReturns == 0)
        #expect(commands.contains(#selector(NSResponder.insertNewline(_:))))
    }

    @Test func controlNAndPMoveSelectionByPhysicalKey() {
        let editor = LauncherFieldEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        var moves: [Int] = []
        editor.onControlNavigation = { moves.append($0) }
        // Characters as the Korean layout would report them (ㅜ / ㅔ); the key code decides.
        editor.keyDown(with: Self.key(kVK_ANSI_N, characters: "\u{0e}", ignoring: "ㅜ", flags: .control))
        editor.keyDown(with: Self.key(kVK_ANSI_P, characters: "\u{10}", ignoring: "ㅔ", flags: .control))
        #expect(moves == [1, -1])
    }

    static func key(_ code: Int, characters: String, ignoring: String? = nil,
                    flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                         isARepeat: false, keyCode: UInt16(code))!
    }
}

@Suite("PanelLayout geometry")
struct PanelLayoutTests {
    /// Built-in 14" display: 1512×982 pt, auxiliaryTopLeftArea maxX 663, auxiliaryTopRightArea minX 848.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func notchRectFromAuxiliaryAreas() {
        let notch = PanelLayout.notchRect(screenFrame: screen, leftAreaWidth: 663, rightAreaWidth: 1512 - 848,
                                          topInset: 32)
        #expect(notch == CGRect(x: 663, y: 950, width: 185, height: 32))
        #expect(PanelLayout.notchRect(screenFrame: screen, leftAreaWidth: nil, rightAreaWidth: nil, topInset: 0) == nil)
    }

    @Test func notchWindowIsFlushWithTopAndCenteredOnNotch() {
        let notch = CGRect(x: 663, y: 950, width: 185, height: 32)
        let frame = PanelLayout.notchWindowFrame(notch: notch, screenFrame: screen, panelWidth: 720, rows: 8)
        #expect(frame.maxY == screen.maxY)
        #expect(abs(frame.midX - notch.midX) < 0.001)
        #expect(frame.width == 720 + 2 * PanelLayout.earRadius + 2 * PanelLayout.shadowMargin)
        #expect(frame.height == PanelLayout.contentHeight(topInset: 32, rows: 8) + PanelLayout.shadowMargin)
    }

    @Test func virtualNotchOnScreensWithoutOne() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let notch = PanelLayout.virtualNotchRect(screenFrame: external, menuBarHeight: 25)
        #expect(notch.midX == external.midX)
        #expect(notch.maxY == external.maxY)
        #expect(notch.height == 25)
    }

    @Test func classicPanelTopAt18Percent() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let frame = PanelLayout.classicWindowFrame(visibleFrame: visible, panelWidth: 720, rows: 3)
        let panelTop = frame.maxY - PanelLayout.shadowMargin
        #expect(abs(panelTop - (950 - 950 * 0.18)) < 0.001)
        #expect(abs(frame.midX - visible.midX) < 0.001)
    }

    @Test func listCapsAtEightVisibleRows() {
        #expect(PanelLayout.listHeight(rows: 0) == 0)
        #expect(PanelLayout.listHeight(rows: 20) == PanelLayout.listHeight(rows: 8))
        #expect(PanelLayout.listHeight(rows: 3, headers: 1)
            == 3 * PanelLayout.rowHeight + PanelLayout.sectionHeaderHeight + 2 * PanelLayout.listVerticalPadding)
        #expect(PanelLayout.listHeight(rows: 8, headers: 1) == PanelLayout.listHeight(rows: 8))
        #expect(PanelLayout.contentHeight(topInset: 0, rows: 0)
                == PanelLayout.searchRowHeight + PanelLayout.separatorHeight + PanelLayout.footerHeight)
    }
}

@Suite("MockSearchService")
struct MockSearchServiceTests {
    @Test func choseongAndPrefixMatching() async {
        #expect(MockSearchService.initials(of: "계산기") == "ㄱㅅㄱ")
        let mock = MockSearchService()
        let byInitials = await mock.instantSearch("ㄱㅅㄱ", limit: 10)
        #expect(byInitials.first?.id == "app:com.apple.calculator")
        let byPrefix = await mock.instantSearch("saf", limit: 10)
        #expect(byPrefix.first?.id == "app:com.apple.Safari")
    }

    @Test func semanticHitsAfterReadyCarryOnlySemanticSignal() async throws {
        var options = MockSearchService.Options()
        options.startupScale = 0.01
        options.fullSearchLatency = 0.001...0.002
        let mock = MockSearchService(options: options)
        for await state in await mock.stateUpdates() {
            if case .ready = state { break }
        }
        let results = try await mock.fullSearch("에어팟 연결", limit: 10)
        let bluetooth = try #require(results.first { $0.id == "setting:com.apple.BluetoothSettings#root" })
        #expect(bluetooth.signals.contains(.lexical) || bluetooth.signals.contains(.semantic))
        let quiet = try await mock.fullSearch("너무 시끄러워", limit: 10)
        #expect(quiet.contains { $0.id == "cmd:toggle-mute" && DisplayText.isSemanticOnly($0.signals) })
    }
}
