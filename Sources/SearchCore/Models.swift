import Foundation

// MARK: - Contract shared by SearchCore (implementation) and the App (UI). Change only with care:
// the App target and the CLI compile against these types.

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case application
    case systemSetting
    case command
    case shortcut
    /// An image or PDF in a folder the user chose; found by name and by content (see `FileScanner`).
    case file
    /// Text copied in any app. The App keeps the last few in memory only: never indexed, embedded
    /// or stored by SearchCore.
    case clipboard
    // Later phases: browserHistory
}

public enum ItemAction: Codable, Hashable, Sendable {
    /// Open an .app bundle at this path.
    case openApplication(path: String)
    /// Open a URL, e.g. `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
    case openURL(String)
    /// Run a Shortcuts.app shortcut by name (`shortcuts run <name>`).
    case runShortcut(name: String)
    /// Built-in command executed by the App's command runner (ids defined in `BuiltinCommands`).
    case builtinCommand(id: String)
    /// Open a document with its default app.
    case openFile(path: String)
    /// Put this text on the pasteboard.
    case copyText(String)
}

public enum IconHint: Codable, Hashable, Sendable {
    /// Use the Finder icon of this path (apps, System Settings.app for settings panes).
    case filePath(String)
    /// SF Symbol name.
    case systemSymbol(String)
}

public struct SearchItem: Identifiable, Hashable, Codable, Sendable {
    /// Stable across launches, e.g. `app:com.apple.calculator`,
    /// `setting:com.apple.Bluetooth-Settings.extension#Bluetooth`, `cmd:lock-screen`, `shortcut:<name>`,
    /// `file:<absolute path>`.
    public let id: String
    public let kind: ItemKind
    /// Primary display string (Korean localized name when available).
    public let title: String
    /// Secondary display string (English name, pane name, path...).
    public let subtitle: String?
    /// All names/aliases (ko + en) used by lexical matching.
    public let keywords: [String]
    /// EmbeddingGemma `title:` slot.
    public let embeddingTitle: String?
    /// EmbeddingGemma `text:` slot — the bilingual text card for this item. A `.file` item's content
    /// is embedded from the file itself; its `embeddingText` is the file's size and modification
    /// time, so its content hash changes whenever the file does.
    public let embeddingText: String
    public let action: ItemAction
    public let icon: IconHint
    /// Destructive/disruptive actions (shut down, empty trash...) must be confirmed by the UI.
    public let requiresConfirmation: Bool

    public init(
        id: String, kind: ItemKind, title: String, subtitle: String?, keywords: [String],
        embeddingTitle: String?, embeddingText: String, action: ItemAction, icon: IconHint,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.embeddingTitle = embeddingTitle
        self.embeddingText = embeddingText
        self.action = action
        self.icon = icon
        self.requiresConfirmation = requiresConfirmation
    }

    /// Hash of everything that feeds the embedding; used as the embedding-cache key.
    public var embeddingContent: String { "\(embeddingTitle ?? "")\u{1F}\(embeddingText)" }
}

public enum MatchSignal: String, Codable, Sendable {
    case lexical, semantic, frecency, memory
}

public struct ScoreBreakdown: Codable, Sendable, Hashable {
    public var lexicalRank: Int?
    public var lexicalScore: Double?
    public var semanticRank: Int?
    public var cosine: Double?
    /// Files: rank in the keyword (file text) list, and the share of the query its best chunk covers.
    public var keywordRank: Int?
    public var keywordCoverage: Double?
    public var frecencyBoost: Double
    public var final: Double
    /// Files: the PDF page (1-based) the matching text starts on — the keyword match's chunk when
    /// there is one (it has the query's words), else the content match's. Nil when only the name
    /// matched, for images, and when the content match was the document as a whole (its card:
    /// title, headings, abstract).
    public var page: Int?

    public init(lexicalRank: Int? = nil, lexicalScore: Double? = nil, semanticRank: Int? = nil,
                cosine: Double? = nil, keywordRank: Int? = nil, keywordCoverage: Double? = nil,
                frecencyBoost: Double = 0, final: Double = 0, page: Int? = nil) {
        self.lexicalRank = lexicalRank
        self.lexicalScore = lexicalScore
        self.semanticRank = semanticRank
        self.cosine = cosine
        self.keywordRank = keywordRank
        self.keywordCoverage = keywordCoverage
        self.frecencyBoost = frecencyBoost
        self.final = final
        self.page = page
    }
}

/// Where a result is listed: in the main ranking, or in the trailing settings section that loosely
/// matching settings move to when there are files (see `ResultSections`).
public enum ResultSection: String, Sendable, Hashable {
    case main
    case settings
}

public struct SearchResult: Identifiable, Sendable, Hashable {
    public var id: String { item.id }
    public let item: SearchItem
    public let score: Double
    public let signals: Set<MatchSignal>
    public let breakdown: ScoreBreakdown
    public let section: ResultSection

    public init(item: SearchItem, score: Double, signals: Set<MatchSignal>, breakdown: ScoreBreakdown,
                section: ResultSection = .main) {
        self.item = item
        self.score = score
        self.signals = signals
        self.breakdown = breakdown
        self.section = section
    }
}

public enum EngineState: Sendable, Equatable {
    case idle
    case loadingModel(progress: Double)
    case indexing(done: Int, total: Int)
    case ready(itemCount: Int)
    /// Lexical search still works; semantic search is unavailable.
    case degraded(reason: String)
}

/// What the App talks to. `SearchEngine` (SearchCore) is the real implementation;
/// the App may use a mock conforming to this during UI development.
public protocol SearchService: Sendable {
    /// Fast path on every committed keystroke: lexical + frecency only, no model call. Must return in a few ms.
    func instantSearch(_ query: String, limit: Int) async -> [SearchResult]
    /// Hybrid (lexical + semantic + frecency) search; runs after debounce or on Enter.
    func fullSearch(_ query: String, limit: Int) async throws -> [SearchResult]
    /// Called when the user opens a result, to update frecency and query→item memory.
    func recordSelection(itemID: String, query: String) async
    /// Rescan sources and embed new/changed items (uses the embedding cache).
    func refresh() async
    /// Emits state changes for the UI footer.
    func stateUpdates() async -> AsyncStream<EngineState>
}
