import AppKit
import Carbon.HIToolbox
import SearchCore
import SwiftUI
import os

/// Shows/hides the launcher panel on the screen under the cursor, owns the AppKit search field and
/// its IME-aware field editor, routes keys to `QueryController`, and runs opened results.
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
    private let panel = LauncherPanel()
    private let searchField = NSTextField()
    private let fieldEditor = LauncherFieldEditor()
    private var previousApp: NSRunningApplication?
    private var currentScreen: NSScreen?
    private var transitionGeneration = 0
    private var resizeGeneration = 0
    private let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "panel")

    init(query: QueryController, settings: AppSettings, actions: ActionRunner) {
        self.query = query
        self.settings = settings
        self.actions = actions
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

    func show(initialQuery: String? = nil) {
        onShow?()
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
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isShown, generation == self.resizeGeneration,
                  let screen = self.currentScreen else { return }
            self.panel.setFrame(self.targetFrame(on: screen), display: true)
        }
    }

    // MARK: Opening results

    private func open(_ result: SearchResult, query text: String) {
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
            break // no other key views; keep focus in the field
        default:
            return false
        }
        return true
    }

    private func handleEscape() {
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
        if Int(event.keyCode) == kVK_ANSI_Comma {
            openSettings()
            return true
        }
        return false
    }

    // MARK: Setup

    private func configurePanel() {
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        panel.onCommandKeyChange = { [weak self] held in self?.model.commandHeld = held }
        panel.onCancel = { [weak self] in self?.handleEscape() }

        let root = LauncherView(model: model, query: query, searchField: searchField,
                                onBackgroundClick: { [weak self] in self?.hide(restoreFocus: false) },
                                onOpenSettings: { [weak self] in self?.openSettings() })
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
        searchField.placeholderAttributedString = NSAttributedString(
            string: "앱, 설정, 명령 검색 — 하고 싶은 일을 입력하세요",
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
