import Foundation
import SearchCore

/// Development stand-in for SearchCore's `SearchEngine`: in-memory lexical matching (prefix, substring,
/// 초성) plus a hand-written concept table that imitates semantic hits, with simulated latency and
/// engine states (loading model → indexing → ready / degraded). Swap it out in `AppServices`.
actor MockSearchService: SearchService {
    struct Options: Sendable {
        /// Multiplies the simulated startup durations (1 ≈ 2 s loading + 1 s indexing).
        var startupScale: Double = 1
        /// Fail model loading and stay in `.degraded` (lexical only).
        var degraded = false
        var fullSearchLatency: ClosedRange<Double> = 0.12...0.25

        static let `default` = Options()
    }

    private let items: [SearchItem]
    private let itemsByID: [String: SearchItem]
    private let options: Options
    private var state: EngineState = .idle
    private var continuations: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var simulation: Task<Void, Never>?
    private var selectionCounts: [String: Int] = [:]
    private var queryMemory: [String: String] = [:]

    init(items: [SearchItem] = MockCatalog.items, options: Options = .default) {
        self.items = items
        self.itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.options = options
    }

    // MARK: SearchService

    func instantSearch(_ query: String, limit: Int) async -> [SearchResult] {
        Array(rank(query, semantic: false).prefix(limit))
    }

    func fullSearch(_ query: String, limit: Int) async throws -> [SearchResult] {
        try await Task.sleep(for: .seconds(Double.random(in: options.fullSearchLatency)))
        let semanticAvailable: Bool
        if case .ready = state { semanticAvailable = true } else { semanticAvailable = false }
        return Array(rank(query, semantic: semanticAvailable).prefix(limit))
    }

    func recordSelection(itemID: String, query: String) async {
        selectionCounts[itemID, default: 0] += 1
        queryMemory[Self.normalize(query)] = itemID
    }

    func refresh() async {
        simulation?.cancel()
        simulation = Task { await self.runIndexing() }
    }

    func stateUpdates() async -> AsyncStream<EngineState> {
        startSimulationIfNeeded()
        let (stream, continuation) = AsyncStream<EngineState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(state)
        return stream
    }

    // MARK: Simulated startup

    private func startSimulationIfNeeded() {
        guard simulation == nil else { return }
        simulation = Task { await self.runStartup() }
    }

    private func runStartup() async {
        let scale = options.startupScale
        for step in 0...20 {
            if options.degraded && step == 8 {
                setState(.degraded(reason: "모델을 불러오지 못했습니다 (mock)"))
                return
            }
            setState(.loadingModel(progress: Double(step) / 20))
            try? await Task.sleep(for: .seconds(0.1 * scale))
        }
        await runIndexing()
    }

    private func runIndexing() async {
        let total = items.count
        for done in stride(from: 0, through: total, by: 3) {
            if Task.isCancelled { return }
            setState(.indexing(done: done, total: total))
            try? await Task.sleep(for: .seconds(0.05 * options.startupScale))
        }
        setState(options.degraded ? .degraded(reason: "모델을 불러오지 못했습니다 (mock)") : .ready(itemCount: total))
    }

    private func setState(_ newState: EngineState) {
        state = newState
        for continuation in continuations.values { continuation.yield(newState) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    // MARK: Ranking

    private func rank(_ query: String, semantic: Bool) -> [SearchResult] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }

        var lexical: [String: Double] = [:]
        for item in items {
            if let score = Self.lexicalScore(q, item) { lexical[item.id] = score }
        }
        var cosines: [String: Double] = [:]
        if semantic {
            for concept in Self.concepts where concept.terms.contains(where: { q.contains($0) || ($0.hasPrefix(q) && q.count >= 2) }) {
                for (offset, id) in concept.ids.enumerated() {
                    cosines[id] = max(cosines[id] ?? 0, 0.62 - Double(offset) * 0.04)
                }
            }
        }
        let rememberedID = queryMemory[q]

        let ids = Set(lexical.keys).union(cosines.keys)
        let lexicalRanks = Self.ranks(lexical)
        let semanticRanks = Self.ranks(cosines)
        var results: [SearchResult] = []
        for id in ids {
            guard let item = itemsByID[id] else { continue }
            var signals = Set<MatchSignal>()
            if lexical[id] != nil { signals.insert(.lexical) }
            if cosines[id] != nil { signals.insert(.semantic) }
            let uses = selectionCounts[id] ?? 0
            let frecency = uses > 0 ? min(Double(uses) * 0.02, 0.1) : 0
            if uses > 0 { signals.insert(.frecency) }
            let memory = rememberedID == id ? 0.2 : 0
            if memory > 0 { signals.insert(.memory) }

            var score = frecency + memory
            if let rank = lexicalRanks[id] { score += 1 / Double(60 + rank) + (lexical[id] ?? 0) * 0.01 }
            if let rank = semanticRanks[id] { score += 1 / Double(60 + rank) }
            let breakdown = ScoreBreakdown(
                lexicalRank: lexicalRanks[id], lexicalScore: lexical[id], semanticRank: semanticRanks[id],
                cosine: cosines[id], frecencyBoost: frecency, final: score)
            results.append(SearchResult(item: item, score: score, signals: signals, breakdown: breakdown))
        }
        return results.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.title < $1.item.title }
    }

    private static func ranks(_ scores: [String: Double]) -> [String: Int] {
        let ordered = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.key, $0 + 1) })
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lexicalScore(_ q: String, _ item: SearchItem) -> Double? {
        let fields = [item.title] + (item.subtitle.map { [$0] } ?? []) + item.keywords
        let initialsQuery = q.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
        var best: Double?
        for (index, raw) in fields.enumerated() {
            let field = normalize(raw)
            let score: Double
            if field == q {
                score = 1
            } else if field.hasPrefix(q) {
                score = 0.9
            } else if field.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                score = 0.8
            } else if field.contains(q) {
                score = 0.65
            } else if initialsQuery, initials(of: field).hasPrefix(q) {
                score = 0.6
            } else {
                continue
            }
            let weighted = index == 0 ? score : score * 0.95
            best = max(best ?? 0, weighted)
        }
        return best
    }

    /// 초성 string of the Hangul syllables in `text` (spaces dropped), e.g. "계산기" → "ㄱㅅㄱ".
    static func initials(of text: String) -> String {
        let choseong: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ",
                                     "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
        var out = ""
        for scalar in text.unicodeScalars where scalar != " " {
            if (0xAC00...0xD7A3).contains(scalar.value) {
                out.append(choseong[Int((scalar.value - 0xAC00) / 588)])
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Imitation of semantic hits: query fragments → related item ids (best first).
    private static let concepts: [(terms: [String], ids: [String])] = [
        (["어둡", "밤에", "눈부", "눈이 아", "dark"],
         ["cmd:toggle-dark-mode", "setting:com.apple.Appearance-Settings.extension#root", "cmd:display-sleep"]),
        (["소리", "음량", "볼륨", "시끄", "조용", "volume", "loud"],
         ["setting:com.apple.Sound-Settings.extension#root", "cmd:toggle-mute", "cmd:volume-down", "cmd:volume-up"]),
        (["인터넷", "웹", "web", "browse"], ["app:com.apple.Safari", "setting:com.apple.wifi-settings-extension#root"]),
        (["계산", "수학", "더하기", "math"], ["app:com.apple.calculator"]),
        (["일정", "약속", "회의", "schedule", "meeting"],
         ["app:com.apple.iCal", "app:com.apple.reminders", "shortcut:오늘 일정 요약"]),
        (["이어폰", "에어팟", "헤드폰", "무선", "airpods", "headphone"],
         ["setting:com.apple.BluetoothSettings#root", "setting:com.apple.Sound-Settings.extension#root"]),
        (["자리 비", "잠그", "보안", "lock", "away"],
         ["cmd:lock-screen", "cmd:sleep", "setting:com.apple.settings.PrivacySecurity.extension#Privacy_AllFiles"]),
        (["느려", "느림", "멈춤", "버벅", "cpu", "메모리", "slow"], ["app:com.apple.ActivityMonitor"]),
        (["캡처", "화면 찍", "screenshot", "capture"], ["cmd:screenshot", "app:com.apple.Screenshot"]),
        (["끄기", "퇴근", "shut"], ["cmd:shut-down", "cmd:sleep", "cmd:display-sleep"]),
        (["재부팅", "다시 켜", "reboot"], ["cmd:restart"]),
        (["정리", "용량", "clean"], ["cmd:empty-trash"]),
        (["권한", "접근", "permission", "privacy"],
         ["setting:com.apple.settings.PrivacySecurity.extension#Privacy_AllFiles"]),
        (["충전", "전원", "battery"], ["setting:com.apple.Battery-Settings.extension#root"]),
        (["글자", "입력", "한영", "typing"], ["setting:com.apple.Keyboard-Settings.extension#root"]),
        (["노래", "music", "song"], ["app:com.apple.Music"]),
        (["이미지", "photo", "picture"], ["app:com.apple.Photos", "app:com.apple.Preview"]),
        (["길 찾", "위치", "navigation"], ["app:com.apple.Maps"]),
        (["집중", "방해", "focus"], ["shortcut:집중 모드 켜기", "setting:com.apple.Notifications-Settings.extension#root"]),
        (["받은 파일", "download"], ["cmd:open-downloads"]),
        (["숨김", "hidden", "dotfile"], ["cmd:toggle-hidden-files"]),
        (["코딩", "개발", "명령줄", "shell"], ["app:com.apple.Terminal"]),
    ]
}
