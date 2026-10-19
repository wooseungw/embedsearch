import Foundation
import Testing
@testable import EmbedCore

// Prompt strings are trained tokens of EmbeddingGemma 2. They must also match
// tools/parity/make_reference.py, which the MLX parity check compares against.
@Suite struct EmbeddingPromptTests {
    @Test(arguments: [
        ("블루투스", "task: search result | query: 블루투스"),
        ("wifi settings", "task: search result | query: wifi settings"),
        ("Safari 열기", "task: search result | query: Safari 열기"),
        ("", "task: search result | query: "),
        ("  spaced  ", "task: search result | query:   spaced  "),
    ])
    func queryPrefixStaysEnglishAndTextIsVerbatim(text: String, expected: String) {
        #expect(EmbeddingPrompt.format(.query(text)) == expected)
    }

    @Test func documentWithTitle() {
        #expect(
            EmbeddingPrompt.format(.document(title: "계산기", text: "Calculator 계산기 앱"))
                == "title: 계산기 | text: Calculator 계산기 앱")
    }

    @Test(arguments: [nil, "", "   ", "\n\t "] as [String?])
    func missingOrBlankTitleBecomesNone(title: String?) {
        #expect(EmbeddingPrompt.format(.document(title: title, text: "x")) == "title: none | text: x")
    }

    @Test func titleIsTrimmedButInnerSpacesKept() {
        #expect(
            EmbeddingPrompt.format(.document(title: "  System Settings \n", text: "t"))
                == "title: System Settings | text: t")
    }

    @Test func documentTextIsNotTrimmed() {
        #expect(
            EmbeddingPrompt.format(.document(title: nil, text: "line 1\nline 2\n"))
                == "title: none | text: line 1\nline 2\n")
    }

    @Test func queryAndDocumentOfSameTextDiffer() {
        #expect(EmbeddingPrompt.format(.query("a")) != EmbeddingPrompt.format(.document(title: nil, text: "a")))
    }

    @Test func versionIsPartOfCacheKey() {
        let info = EmbeddingModelInfo(modelID: "mlx-community/embeddinggemma-2-bf16", revision: "abc123", dimensions: 256)
        #expect(info.promptVersion == EmbeddingPrompt.version)
        #expect(info.cacheKey == "mlx-community/embeddinggemma-2-bf16@abc123#d256#p\(EmbeddingPrompt.version)")
    }

    @Test func cacheKeyDefaultsRevisionToMainAndSeparatesSpaces() {
        let base = EmbeddingModelInfo(modelID: "m", revision: nil, dimensions: 768)
        #expect(base.cacheKey == "m@main#d768#p\(EmbeddingPrompt.version)")
        #expect(base.cacheKey != EmbeddingModelInfo(modelID: "m", revision: nil, dimensions: 256).cacheKey)
        #expect(base.cacheKey != EmbeddingModelInfo(modelID: "m", revision: "r2", dimensions: 768).cacheKey)
        #expect(
            base.cacheKey
                != EmbeddingModelInfo(modelID: "m", revision: nil, dimensions: 768, promptVersion: "other").cacheKey)
    }

    @Test func modelInfoRoundTripsThroughJSON() throws {
        let info = EmbeddingModelInfo(modelID: "m", revision: "r", dimensions: 512)
        let decoded = try JSONDecoder().decode(EmbeddingModelInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
        #expect(decoded.cacheKey == info.cacheKey)
    }
}
