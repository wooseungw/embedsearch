import Testing
@testable import EmbedCore

@Test func queryPromptFormat() {
    #expect(EmbeddingPrompt.format(.query("블루투스")) == "task: search result | query: 블루투스")
    #expect(EmbeddingPrompt.format(.document(title: nil, text: "x")) == "title: none | text: x")
}
