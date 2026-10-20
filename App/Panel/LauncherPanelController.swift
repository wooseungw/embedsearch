import AppKit
import Carbon.HIToolbox
import SearchCore
import SwiftUI
import os

/// Shows/hides the launcher panel on the screen under the cursor, owns the AppKit search field and
/// its IME-aware field editor, routes keys to `QueryController`, runs opened results, and shows the
/// selected file's preview below the panel.
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    let query: QueryController

    var onOpenSettings: (() -> Void)?
    /// Called on every `show()`, before the panel appears (e.g. to get the model loading).
    var onShow: (() -> Void)?
    private(set) var isShown = false

    private let settings: AppSettings
    private let actions: ActionRunner
    private let clipboard: ClipboardHistory?
    private let panel = LauncherPanel()
    private let searchField = NSTextField()
    private let fieldEditor = LauncherFieldEditor()
    private let preview = FilePreviewController()
    /// Each opening of the preview starts its own selection observation; older ones stop.
    private var previewGeneration = 0
    private var previewUpdate: Task<Void, Never>?
    private var noticeGeneration = 0
    private var previousApp: NSRunningApplication?
    private var currentScreen: NSScreen?
    private var transitionGeneration = 0
    private var resizeGeneration = 0
    private let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "panel")

    init(query: QueryController, settings: AppSettings, actions: ActionRunner, clipboard: ClipboardHistory? = nil) {
        self.query = query
        self.settings = settings
        self.actions = actions
        self.clipboard = clipboard
        super.init()
        configureSearchField()
        configureFieldEditor()
        configurePanel()
        query.onOpen = { [weak self] result, text in self?.open(result, query: text) }
        query.onLayoutChange = { [weak self] in self?.updateWindowFrame() }
    }

    // MARK: Show / hide

    func toggle() {
        isShown ? hide(restoreFocus: true) : show()
    }

    /// The clipboard hotkey: opens the panel on the clipboard history, switches an open panel to
    /// it, or closes the panel when it already shows it.
    func toggleClipboard() {
        guard isShown else {
            show(mode: .clipboard)
            return
        }
        if query.mode == .clipboard {
            hide(restoreFocus: true)
        } else {
            switchMode(to: .clipboard, keepingText: true)
        }
    }

    func show(initialQuery: String? = nil, mode: QueryController.Mode = .search) {
        // The clipboard mode needs no model.
        if mode == .search { onShow?() }
        transitionGeneration += 1
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        let screen = ActiveScreen.current
        currentScreen = screen
        model.style = settings.panelStyle
        model.hotKeyHint = settings.hotKey.displayString
        let maxWidth = screen.frame.width - 2 * (PanelLayout.earRadius + PanelLayout.shadowMargin) - 24
        model.panelWidth = min(CGFloat(settings.panelWidth), maxWidth)
        model.notchSize = Self.notchRect(on: screen).size
        if !isShown {
            model.isExpanded = false
        }
        isShown = true
        logger.info("show on \(screen.localizedName, privacy: .public) style \(self.model.style.rawValue, privacy: .public)")
        resizeGeneration += 1
        panel.setFrame(targetFrame(on: screen), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)

        if query.mode != mode {
            closePreview()
            fieldEditor.replaceAll(with: "")
            query.setMode(mode)
        }
        model.clipboardProblem = clipboard?.problem
        updatePlaceholder()
        if let initialQuery, !initialQuery.isEmpty {
            fieldEditor.replaceAll(with: initialQuery)
        }

        // Let the collapsed (notch-sized) state reach the screen, then spring open.
        let generation = transitionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            withAnimation(LauncherView.openSpring) { self.model.isExpanded = true }
        }
    }

    /// `restoreFocus`: give focus back to the app that was active before (Esc, hotkey). Not when
    /// the user clicked another app (it already has focus) or opened a result (it activates).
    func hide(restoreFocus: Bool) {
        guard isShown else { return }
        logger.info("hide (restoreFocus: \(restoreFocus))")
        isShown = false
        closePreview()
        noticeGeneration += 1
        model.notice = nil
        transitionGeneration += 1
        let generation = transitionGeneration
        panel.makeFirstResponder(nil)
        withAnimation(LauncherView.closeSpring) {
            model.isExpanded = false
        } completion: { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            self.panel.orderOut(nil)
            // Editing already ended (first responder cleared), so the text lives in the field again.
            self.searchField.stringValue = ""
            self.query.reset()
            self.model.commandHeld = false
        }
        if restoreFocus, NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    // MARK: Geometry

    /// The real notch, or a virtual one centered at the top edge when the screen has none.
    static func notchRect(on screen: NSScreen) -> CGRect {
        PanelLayout.notchRect(screenFrame: screen.frame,
                              leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
                              rightAreaWidth: screen.auxiliaryTopRightArea?.width,
                              topInset: screen.safeAreaInsets.top)
            ?? PanelLayout.virtualNotchRect(screenFrame: screen.frame,
                                            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func targetFrame(on screen: NSScreen) -> CGRect {
        let rows = query.displayedRowCount, headers = query.displayedHeaderCount
        switch model.style {
        case .notch:
            return PanelLayout.notchWindowFrame(notch: Self.notchRect(on: screen), screenFrame: screen.frame,
                                                panelWidth: model.panelWidth, rows: rows, headers: headers)
        case .classic:
            return PanelLayout.classicWindowFrame(visibleFrame: screen.visibleFrame, panelWidth: model.panelWidth,
                                                  rows: rows, headers: headers)
        }
    }

    /// The window hugs the panel so transparent space never blocks clicks to apps below:
    /// grow at once (before the shape animates into the space), shrink after the shape has animated.
    private func updateWindowFrame() {
        guard isShown, let screen = currentScreen else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        let target = targetFrame(on: screen)
        if target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
            preview.move(to: previewFrame(on: screen))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isShown, generation == self.resizeGeneration,
                  let screen = self.currentScreen else { return }
            self.panel.setFrame(self.targetFrame(on: screen), display: true)
            self.preview.move(to: self.previewFrame(on: screen))
        }
    }

    /// Under the panel's shape, as wide as it, down to the bottom of the visible frame.
    private func previewFrame(on screen: NSScreen) -> CGRect {
        let launcher = targetFrame(on: screen)
        // Both styles leave `shadowMargin` of transparent window below the shape.
        let top = launcher.minY + PanelLayout.shadowMargin - 10
        let height = max(240, top - (screen.visibleFrame.minY + 16))
        let width = model.panelWidth
        return CGRect(x: launcher.midX - width / 2, y: top - height, width: width, height: height)
    }

    // MARK: Opening results

    private func open(_ result: SearchResult, query text: String) {
        // The "클립보드 기록" command switches the panel instead of closing it.
        if case .builtinCommand("clipboard-history") = result.item.action, query.clipboardService != nil {
            query.recordSelection(result, query: text)
            switchMode(to: .clipboard, keepingText: false)
            return
        }
        hide(restoreFocus: false)
        let actions = actions
        let query = query
        let previousApp = previousApp
        Task { @MainActor in
            if result.item.requiresConfirmation {
                // Let the panel finish collapsing before the modal alert takes over the run loop.
                try? await Task.sleep(for: .milliseconds(300))
            }
            if await actions.run(result.item) {
                query.recordSelection(result, query: text)
            } else if NSApp.isActive, let previousApp, !previousApp.isTerminated {
                previousApp.activate()
            }
        }
    }

    /// ⇥ and the search row's mode button: between search and the clipboard history.
    private func toggleMode() {
        switchMode(to: query.mode == .clipboard ? .search : .clipboard, keepingText: true)
    }

    /// Switches the open panel's mode. `keepingText`: what is typed searches the other side too
    /// (⇥, the mode button, the clipboard hotkey); the "클립보드 기록" command clears its own words.
    private func switchMode(to mode: QueryController.Mode, keepingText: Bool) {
        guard mode != query.mode, mode == .search || query.clipboardService != nil else { return }
        closePreview()
        if !keepingText { fieldEditor.replaceAll(with: "") }
        query.setMode(mode)
        model.clipboardProblem = clipboard?.problem
        updatePlaceholder()
        // A click on the mode button must not take typing away from the field.
        if isShown, panel.firstResponder !== fieldEditor {
            panel.makeFirstResponder(searchField)
            fieldEditor.setSelectedRange(NSRange(location: (fieldEditor.string as NSString).length, length: 0))
        }
    }

    /// ⌃X: removes the selected clipboard entry from the history.
    private func removeSelectedClip() -> Bool {
        guard let clipboard, let result = query.selectedResult, result.item.kind == .clipboard else { return false }
        clipboard.remove(itemID: result.id)
        query.dropResult(id: result.id)
        return true
    }

    /// ⌘↵: the selected file (or app) in Finder. Counts as choosing it, like opening.
    private func revealSelected() {
        guard let result = query.selectedResult, result.item.filePath != nil else {
            NSSound.beep()
            return
        }
        let text = query.text
        hide(restoreFocus: false)
        let actions = actions
        let query = query
        Task { @MainActor in
            if await actions.reveal(result.item) { query.recordSelection(result, query: text) }
        }
    }

    /// ⌘C with no text selected in the field: the selected file's (or app's) path. The panel stays.
    private func copySelectedPath() -> Bool {
        guard fieldEditor.selectedRange().length == 0, let result = query.selectedResult,
              actions.copyPath(result.item) else { return false }
        showNotice("경로를 복사했습니다")
        return true
    }

    private func showNotice(_ text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        model.notice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, generation == self.noticeGeneration else { return }
            self.model.notice = nil
        }
    }

    // MARK: Preview

    /// ⌘Y: opens the preview for the selected file, or closes it. With the preview open but out of
    /// sight (an app or a setting selected) it opens again for the selection, or beeps.
    private func togglePreview() {
        if model.isPreviewing {
            let shown = preview.isVisible
            closePreview()
            if shown { return }
        }
        guard let result = query.selectedResult,
              FilePreviewController.target(for: result, query: query.resultsQuery) != nil else {
            NSSound.beep()
            return
        }
        model.isPreviewing = true
        previewGeneration += 1
        updatePreview()
        observeSelectionForPreview(generation: previewGeneration)
    }

    private func closePreview() {
        guard model.isPreviewing else { return }
        model.isPreviewing = false
        previewGeneration += 1
        previewUpdate?.cancel()
        previewUpdate = nil
        preview.hide()
    }

    /// While the preview is open it follows the selected result (arrows, new results as you type).
    private func observeSelectionForPreview(generation: Int) {
        withObservationTracking {
            _ = query.selectedResult
            _ = query.resultsQuery
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.model.isPreviewing, generation == self.previewGeneration else { return }
                self.schedulePreviewUpdate()
                self.observeSelectionForPreview(generation: generation)
            }
        }
    }

    /// One load per burst of changes (typing, a held arrow key).
    private func schedulePreviewUpdate() {
        previewUpdate?.cancel()
        previewUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            self?.updatePreview()
        }
    }

    /// Shows the selected result's file; a result without one leaves the panel hidden until the
    /// selection comes back to a file.
    private func updatePreview() {
        guard model.isPreviewing, isShown, let screen = currentScreen else { return }
        guard let result = query.selectedResult,
              let target = FilePreviewController.target(for: result, query: query.resultsQuery) else {
            preview.hide()
            return
        }
        preview.show(target, frame: previewFrame(on: screen))
    }

    // MARK: Keys

    private func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            query.moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            query.moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let outcome = query.enterPressed()
            logger.info("enter → \(String(describing: outcome), privacy: .public)")
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // No other key views: focus stays in the field, and ⇥ switches the mode.
            toggleMode()
        default:
            return false
        }
        return true
    }

    /// Esc: closes the preview, else clears the text, else closes the panel. A preview out of sight
    /// is closed on the way, without taking the key press.
    private func handleEscape() {
        if model.isPreviewing {
            let shown = preview.isVisible
            closePreview()
            if shown { return }
        }
        if fieldEditor.string.isEmpty && query.text.isEmpty {
            hide(restoreFocus: true)
        } else {
            fieldEditor.replaceAll(with: "")
        }
    }

    /// The footer's settings button and ⌘,: the panel goes, Settings comes forward.
    private func openSettings() {
        hide(restoreFocus: false)
        onOpenSettings?()
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if let index = digits.firstIndex(of: Int(event.keyCode)) {
            if !fieldEditor.hasMarkedText() { query.openResult(at: index) }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_Comma:
            openSettings()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !fieldEditor.hasMarkedText() { revealSelected() }
            return true
        case kVK_ANSI_Y:
            if !fieldEditor.hasMarkedText() { togglePreview() }
            return true
        case kVK_ANSI_C:
            return !fieldEditor.hasMarkedText() && copySelectedPath()
        default:
            return false
        }
    }

    // MARK: Setup

    private func configurePanel() {
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        panel.onCommandKeyChange = { [weak self] held in self?.model.commandHeld = held }
        panel.onCancel = { [weak self] in self?.handleEscape() }

        let root = LauncherView(model: model, query: query, searchField: searchField,
                                onBackgroundClick: { [weak self] in self?.hide(restoreFocus: false) },
                                onOpenSettings: { [weak self] in self?.openSettings() },
                                onToggleMode: { [weak self] in self?.toggleMode() })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [] // the controller owns the frame
        panel.contentView = hosting
    }

    private func configureSearchField() {
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.textColor = .white
        searchField.usesSingleLineMode = true
        searchField.lineBreakMode = .byClipping
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let text = query.mode == .clipboard ? "클립보드 기록 검색 — 최근 복사한 텍스트" : "앱, 설정, 명령 검색 — 하고 싶은 일을 입력하세요"
        guard searchField.placeholderAttributedString?.string != text else { return }
        searchField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.32),
                         .font: NSFont.systemFont(ofSize: 20, weight: .regular)])
    }

    private func configureFieldEditor() {
        fieldEditor.isFieldEditor = true
        fieldEditor.isRichText = false
        fieldEditor.allowsUndo = true
        fieldEditor.insertionPointColor = .white
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isContinuousSpellCheckingEnabled = false
        fieldEditor.onInputChange = { [weak self] text, composing in
            self?.query.inputChanged(text: text, composing: composing)
        }
        fieldEditor.onCommand = { [weak self] selector in self?.handleCommand(selector) ?? false }
        fieldEditor.onComposingReturn = { [weak self] in
            guard let self else { return }
            self.logger.info("composing enter → commit + search \(self.query.text, privacy: .private)")
            self.query.composingEnterCommitted()
        }
        fieldEditor.onControlNavigation = { [weak self] delta in self?.query.moveSelection(by: delta) }
        fieldEditor.onControlX = { [weak self] in self?.removeSelectedClip() ?? false }
    }

    // MARK: NSWindowDelegate

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as AnyObject?) === searchField ? fieldEditor : nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicked another app or a modal took over: close without stealing focus back.
        logger.info("panel resigned key")
        if isShown { hide(restoreFocus: false) }
    }
}
