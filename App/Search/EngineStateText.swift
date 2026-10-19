import SearchCore

/// Korean UI strings for engine state and item kinds.
enum DisplayText {
    static func engineState(_ state: EngineState) -> String {
        switch state {
        case .idle:
            return "대기 중"
        case .loadingModel(let progress):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return "모델 불러오는 중 \(percent)%"
        case .indexing(let done, let total):
            return "색인 중 \(done)/\(total)"
        case .ready(let count):
            return "준비됨 · \(count)개"
        case .degraded:
            return "의미 검색 사용 불가 – 키워드 검색만"
        }
    }

    static func kindBadge(_ kind: ItemKind) -> String {
        switch kind {
        case .application: return "앱"
        case .systemSetting: return "설정"
        case .command: return "명령"
        case .shortcut: return "단축어"
        case .file: return "파일"
        }
    }

    /// Show the "의미" chip: found by the embedding but not by name matching.
    static func isSemanticOnly(_ signals: Set<MatchSignal>) -> Bool {
        signals.contains(.semantic) && !signals.contains(.lexical)
    }
}
