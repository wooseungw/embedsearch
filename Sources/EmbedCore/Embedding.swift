import Foundation

// MARK: - Contract shared by EmbedMLX (implementation), SearchCore (consumer), App and CLI.

/// One text to embed. The embedder applies the EmbeddingGemma prompt prefix itself.
public enum EmbeddingInput: Sendable, Hashable {
    /// A user search query → `task: search result | query: {text}`
    case query(String)
    /// A document/item card → `title: {title ?? "none"} | text: {text}`
    case document(title: String?, text: String)
}

/// Identifies the vector space. Vectors with different `cacheKey`s must never be compared.
public struct EmbeddingModelInfo: Sendable, Hashable, Codable {
    public let modelID: String
    public let revision: String?
    /// Output dimensions after Matryoshka truncation + re-normalization (768, 512, 256 or 128).
    public let dimensions: Int
    /// Bump when `EmbeddingPrompt` formatting changes.
    public let promptVersion: String

    public init(modelID: String, revision: String?, dimensions: Int, promptVersion: String = EmbeddingPrompt.version) {
        self.modelID = modelID
        self.revision = revision
        self.dimensions = dimensions
        self.promptVersion = promptVersion
    }

    public var cacheKey: String { "\(modelID)@\(revision ?? "main")#d\(dimensions)#p\(promptVersion)" }
}

public protocol TextEmbedder: Sendable {
    var info: EmbeddingModelInfo { get }
    /// Returns one L2-normalized vector of `info.dimensions` floats per input, in input order.
    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]]
}

public enum EmbeddingPrompt {
    public static let version = "eg2-1"

    public static func format(_ input: EmbeddingInput) -> String {
        switch input {
        case .query(let text):
            return "task: search result | query: \(text)"
        case .document(let title, let text):
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "title: \(t?.isEmpty == false ? t! : "none") | text: \(text)"
        }
    }
}
