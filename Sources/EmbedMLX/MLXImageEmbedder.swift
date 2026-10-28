import CoreGraphics
import CoreImage
import EmbedCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// EmbeddingGemma 2's vision tower (MLXVLM): images into the vector space of `MLXTextEmbedder` with
/// the same configuration, so a text query finds pictures by what they show.
///
/// Loads its own copy of the text weights plus the vision encoder at the checkpoint's precision
/// (bf16, ~0.85 GB); audio is never loaded. Text embeds with the same weights in bf16 (cosine
/// within ~1e-4 of `MLXTextEmbedder`'s float32), so indexing a folder needs only this model. Inputs
/// run one at a time, which bounds activations.
public final class MLXImageEmbedder: ImageEmbedder {
    public let info: EmbeddingModelInfo
    private let model: EmbeddingGemma2Embedding
    private let dimensions: Int

    private init(info: EmbeddingModelInfo, model: EmbeddingGemma2Embedding, dimensions: Int) {
        self.info = info
        self.model = model
        self.dimensions = dimensions
    }

    /// Uses the Hugging Face cache (downloading only what is missing) or a local directory.
    public static func load(_ configuration: MLXEmbedderConfiguration = .default) async throws -> MLXImageEmbedder {
        if let cacheLimit = configuration.visionCacheLimit { Memory.cacheLimit = cacheLimit }
        let directory: URL
        if configuration.modelID.hasPrefix("/") || configuration.modelID.hasPrefix("~") {
            directory = URL(filePath: (configuration.modelID as NSString).expandingTildeInPath)
        } else {
            directory = try await MLXTextEmbedder.hub.download(
                id: configuration.modelID, revision: nil, matching: ["*.safetensors", "*.json", "*.jinja"],
                useLatest: false, progressHandler: { _ in })
        }
        let model = try await MLXTextEmbedder.withLoadRandomState {
            try await EmbeddingGemma2Embedding(
                modelDirectory: directory, tokenizerLoader: #huggingFaceTokenizerLoader(), loadVision: true, loadAudio: false)
        }
        guard await model.supportedModalities.contains(.image) else {
            throw MLXEmbedderError.unsupportedModel("\(configuration.modelID) has no vision encoder")
        }
        // Same revision rule as `MLXTextEmbedder`: a Hub snapshot directory is named by its commit.
        let resolved = directory.resolvingSymlinksInPath()
        let revision = resolved.deletingLastPathComponent().lastPathComponent == "snapshots" ? resolved.lastPathComponent : nil
        let info = EmbeddingModelInfo(modelID: configuration.modelID, revision: revision, dimensions: configuration.dimensions)
        return MLXImageEmbedder(info: info, model: model, dimensions: configuration.dimensions)
    }

    /// Formatted with `EmbeddingPrompt` exactly like `MLXTextEmbedder` (a prompt that starts with
    /// `task:` or `title:` passes through the actor unchanged).
    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(inputs.count)
        for input in inputs {
            let v = try await model.embed(.init(text: EmbeddingPrompt.format(input)), task: .none, dimensions: dimensions)
            guard v.allSatisfy(\.isFinite) else { throw MLXEmbedderError.nonFiniteEmbedding(index: out.count) }
            out.append(v)
        }
        return out
    }

    public func embed(images: [ImageInput]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(images.count)
        for image in images {
            let v = try await model.embed(.init([.image(.ciImage(CIImage(cgImage: image)))]), task: .document,
                                          dimensions: dimensions)
            guard v.allSatisfy(\.isFinite) else { throw MLXEmbedderError.nonFiniteEmbedding(index: out.count) }
            out.append(v)
        }
        return out
    }
}
