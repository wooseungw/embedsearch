import EmbedCore
import Foundation
@testable import SearchCore

/// Deterministic stand-in for EmbeddingGemma: hashed character 1–3-grams of the normalized text,
/// L2-normalized. Texts sharing characters get high cosine, which is enough to exercise the pipeline.
final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    let info: EmbeddingModelInfo
    private let lock = NSLock()
    private var _calls = 0
    private var _embedded = 0
    var failing = false

    init(dimensions: Int = 64, modelID: String = "fake-ngram") {
        info = EmbeddingModelInfo(modelID: modelID, revision: "test", dimensions: dimensions)
    }

    var calls: Int { lock.withLock { _calls } }
    var embeddedCount: Int { lock.withLock { _embedded } }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        lock.withLock {
            _calls += 1
            _embedded += inputs.count
        }
        if failing { throw FakeError.boom }
        return inputs.map { input in
            switch input {
            case .query(let q): vector(q)
            case .document(let title, let text): vector((title ?? "") + " " + text)
            }
        }
    }

    func vector(_ text: String) -> [Float] {
        let chars = Array(TextNormalizer.compact(text).unicodeScalars.map(\.value))
        var v = [Float](repeating: 0, count: info.dimensions)
        for n in 1...3 where chars.count >= n {
            for i in 0...(chars.count - n) {
                var h: UInt64 = 1469598103934665603
                for c in chars[i..<(i + n)] { h = (h ^ UInt64(c)) &* 1099511628211 }
                v[Int(h % UInt64(info.dimensions))] += Float(n)
            }
        }
        return VectorMath.normalized(v)
    }

    enum FakeError: Error { case boom }
}

func makeItem(_ id: String, _ kind: ItemKind = .application, title: String, subtitle: String? = nil,
              keywords: [String] = [], text: String? = nil) -> SearchItem {
    SearchItem(id: id, kind: kind, title: title, subtitle: subtitle, keywords: keywords,
               embeddingTitle: title, embeddingText: text ?? ([title] + keywords).joined(separator: ", "),
               action: .builtinCommand(id: id), icon: .systemSymbol("star"))
}

/// Small bilingual corpus used across lexical / ranking / engine tests.
let fixtureItems: [SearchItem] = [
    makeItem("app:com.apple.calculator", title: "계산기", subtitle: "Calculator", keywords: ["계산기", "Calculator", "calc", "유틸리티", "Utilities"]),
    makeItem("app:com.apple.calendar", title: "캘린더", subtitle: "Calendar", keywords: ["캘린더", "Calendar", "달력", "일정"]),
    makeItem("app:com.apple.systempreferences", title: "시스템 설정", subtitle: "System Settings", keywords: ["System Settings", "Preferences", "환경설정"]),
    makeItem("app:com.apple.Notes", title: "메모", subtitle: "Notes", keywords: ["Notes", "노트", "memo"]),
    makeItem("app:com.apple.VoiceMemos", title: "음성 메모", subtitle: "Voice Memos", keywords: ["Voice Memos", "녹음"]),
    makeItem("app:com.microsoft.VSCode", title: "Visual Studio Code", keywords: ["vscode", "코드", "Code"]),
    makeItem("app:com.kakao.KakaoTalkMac", title: "카카오톡", subtitle: "KakaoTalk", keywords: ["KakaoTalk", "카톡"]),
    makeItem("app:com.apple.Safari", title: "Safari", keywords: ["사파리", "browser", "브라우저"]),
    makeItem("setting:com.apple.wifi-settings-extension#General_Main", .systemSetting, title: "Wi‑Fi 네트워크에 연결",
             subtitle: "Wi‑Fi › Joining a Wi‑Fi network", keywords: ["Joining a Wi‑Fi network", "Wi‑Fi", "무선", "네트워크", "설정"]),
    makeItem("setting:com.apple.Displays-Settings.extension#ambienceSection", .systemSetting, title: "디스플레이 밝기",
             subtitle: "디스플레이 › Display Brightness", keywords: ["Display Brightness", "디스플레이", "Displays", "밝기", "화면", "설정"]),
    makeItem("setting:com.apple.BluetoothSettings#Main", .systemSetting, title: "Bluetooth 기기",
             subtitle: "Bluetooth › Bluetooth devices", keywords: ["Bluetooth devices", "Bluetooth", "무선", "on", "off", "설정"]),
    makeItem("setting:com.apple.Keyboard-Settings.extension#Shortcuts", .systemSetting, title: "키보드 단축키",
             subtitle: "키보드 › Keyboard shortcuts", keywords: ["Keyboard shortcuts", "키보드", "Keyboard", "설정"]),
    makeItem("cmd:lock-screen", .command, title: "화면 잠금", subtitle: "Lock Screen", keywords: ["Lock Screen", "잠금", "lock"]),
    makeItem("cmd:empty-trash", .command, title: "휴지통 비우기", subtitle: "Empty Trash", keywords: ["Empty Trash", "휴지통", "trash"]),
    makeItem("shortcut:노래켜줘", .shortcut, title: "노래켜줘", subtitle: "단축어 · Shortcut", keywords: ["노래켜줘"]),
]

/// Temporary directory removed when the value is deinitialized.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "searchcore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func writePlist(_ object: Any, to relative: String) throws {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: file)
    }
}

let liveSystem = FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions")
