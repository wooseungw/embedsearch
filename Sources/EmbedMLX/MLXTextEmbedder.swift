import EmbedCore
import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import Tokenizers

// Owner: embedding track. Implements `TextEmbedder` with MLXEmbedders (EmbeddingGemma 2).

public struct MLXEmbedderConfiguration: Sendable {
    /// Hugging Face repo id, or an absolute path (`/…` or `~/…`) to a local model directory.
    public var modelID: String
    /// 768, or 512/256/128 for Matryoshka truncation + re-normalization.
    public var dimensions: Int
    /// Tokens per input including `<bos>`/`<eos>`; longer inputs lose their tail (hard cap 8192).
    public var maxTokens: Int
    /// Maximum inputs per forward pass.
    public var batchSize: Int
    /// Activation precision (additive to the DESIGN.md contract). Never float16.
    public var precision: MLXEmbedderPrecision
    /// Cap on MLX's buffer cache in bytes, applied at load (`Memory.cacheLimit` is process-wide);
    /// nil leaves MLX's setting alone. MLX's own default is the whole memory limit, and padded
    /// batches of varying shapes rarely reuse freed buffers, so without a cap indexing grew past
    /// 12 GB. Indexing 934 items on an M3 Pro peaked at 3.2 GB with 256 MB (3.4 GB with 512 MB,
    /// 3.0 GB with 0) at unchanged throughput and query latency.
    public var cacheLimit: Int?

    public init(
        modelID: String = EmbedderRegistry.embeddinggemma2.name,
        dimensions: Int = 768,
        maxTokens: Int = 2048,
        batchSize: Int = 32,
        precision: MLXEmbedderPrecision = .float32,
        cacheLimit: Int? = 256 * 1024 * 1024
    ) {
        self.modelID = modelID
        self.dimensions = dimensions
        self.maxTokens = maxTokens
        self.batchSize = batchSize
        self.precision = precision
        self.cacheLimit = cacheLimit
    }

    public static let `default` = MLXEmbedderConfiguration()
}

public enum MLXEmbedderPrecision: String, Sendable, CaseIterable {
    /// Transformer layers upcast to float32 at load; the token-embedding table stays as stored.
    /// Matches the fp32 reference to ≥ 0.99999 cosine and batched == one-by-one to ~1e-12.
    /// Costs ~260 MB more memory and ~3 ms more per short query than `.bfloat16`.
    case float32
    /// Checkpoint dtype (bfloat16 activations). Reference cosine ≥ 0.9998, but batched and
    /// one-by-one vectors of the same text differ by up to ~2e-4 (bf16 rounding noise).
    case bfloat16
}

public enum MLXEmbedderError: Error, LocalizedError {
    case invalidConfiguration(String)
    case unsupportedModel(String)
    case nonFiniteEmbedding(index: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): "Invalid embedder configuration: \(message)"
        case .unsupportedModel(let message): "Unsupported embedding model: \(message)"
        case .nonFiniteEmbedding(let index): "Model produced a NaN/Inf embedding for input #\(index)"
        }
    }
}

/// EmbeddingGemma 2 on MLX (Metal), text encoder only.
///
/// Inputs are prompt-formatted with `EmbeddingPrompt.format`, tokenized as `<bos> text <eos>`
/// (the text is cut to fit `maxTokens`), sorted by length and run in padded batches with an
/// attention mask. Output is float32, L2-normalized, Matryoshka-truncated to `dimensions`.
///
/// Thread safety: every forward pass runs inside `EmbedderModelContainer`'s serial executor.
/// Concurrent `embed` calls interleave per batch, so a query is not stuck behind a whole
/// indexing job.
public final class MLXTextEmbedder: TextEmbedder {
    public let info: EmbeddingModelInfo
    public let configuration: MLXEmbedderConfiguration

    /// Upper bound on padded tokens (batch × longest input) per forward pass. A pass holds
    /// ~100–150 KB of activations per padded token (per-layer inputs, MLP, attention), so this
    /// bounds the transient peak to ~0.5 GB; larger batches were not faster on an M3 Pro.
    /// `batchSize` still caps the item count.
    static let maxTokensPerPass = 4_096
    static let hardMaxTokens = EmbeddingGemma2Configuration.contextLength

    private let container: EmbedderModelContainer
    private let tokenizer: any MLXLMCommon.Tokenizer
    private let leadingTokens: [Int]
    private let trailingTokens: [Int]
    private let padTokenID: Int

    private init(
        configuration: MLXEmbedderConfiguration, info: EmbeddingModelInfo,
        container: EmbedderModelContainer, tokenizer: any MLXLMCommon.Tokenizer,
        leadingTokens: [Int], trailingTokens: [Int], padTokenID: Int
    ) {
        self.configuration = configuration
        self.info = info
        self.container = container
        self.tokenizer = tokenizer
        self.leadingTokens = leadingTokens
        self.trailingTokens = trailingTokens
        self.padTokenID = padTokenID
    }

    /// Downloads (or reuses the Hugging Face cache) and loads the text encoder.
    /// Vision and audio weights are never read. `progress` receives download fractions in 0...1
    /// and a final 1.0 once the model is loaded.
    public static func load(
        _ configuration: MLXEmbedderConfiguration = .default,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MLXTextEmbedder {
        guard [768, 512, 256, 128].contains(configuration.dimensions) else {
            throw MLXEmbedderError.invalidConfiguration(
                "dimensions must be 768, 512, 256 or 128 (got \(configuration.dimensions))")
        }
        guard (8 ... hardMaxTokens).contains(configuration.maxTokens) else {
            throw MLXEmbedderError.invalidConfiguration(
                "maxTokens must be in 8...\(hardMaxTokens) (got \(configuration.maxTokens))")
        }
        guard configuration.batchSize >= 1 else {
            throw MLXEmbedderError.invalidConfiguration("batchSize must be >= 1")
        }
        if let cacheLimit = configuration.cacheLimit { Memory.cacheLimit = cacheLimit }

        var modelConfiguration: ModelConfiguration
        if configuration.modelID.hasPrefix("/") || configuration.modelID.hasPrefix("~") {
            let path = (configuration.modelID as NSString).expandingTildeInPath
            modelConfiguration = ModelConfiguration(directory: URL(filePath: path))
        } else {
            modelConfiguration = ModelConfiguration(id: configuration.modelID)
        }
        modelConfiguration.excludedComponents = [.vision, .audio]

        let container = try await withLoadRandomState {
            try await EmbedderModelFactory.shared.loadContainer(
                from: hub,
                using: #huggingFaceTokenizerLoader(),
                configuration: modelConfiguration,
                progressHandler: { progress($0.fractionCompleted) })
        }

        let embeddingDim: Int? = await container.perform { context in
            (context.model as? EmbeddingGemma2)?.config.embeddingDim
        }
        guard let embeddingDim else {
            throw MLXEmbedderError.unsupportedModel(
                "\(configuration.modelID) is not an EmbeddingGemma 2 checkpoint")
        }
        guard configuration.dimensions <= embeddingDim else {
            throw MLXEmbedderError.invalidConfiguration(
                "dimensions \(configuration.dimensions) > model output \(embeddingDim)")
        }
        if configuration.precision == .float32 {
            // bf16 activations make batched and one-by-one vectors differ by ~1e-4; float32
            // layers remove that and match the reference. The embedding table (half of the
            // weights) is only gathered from, so it stays bf16; the stream turns float32 at
            // the first layer.
            await container.update { context in
                let upcast = context.model.parameters().flattened().compactMap {
                    key, value -> (String, MLXArray)? in
                    guard value.dtype == .bfloat16, !key.contains("embed_tokens") else { return nil }
                    return (key, value.asType(.float32))
                }
                context.model.update(parameters: ModuleParameters.unflattened(upcast))
                MLX.eval(context.model)
            }
            // Drop the replaced bf16 buffers instead of keeping them in MLX's cache.
            Memory.clearCache()
        }

        // Learn the special-token template (`<bos> … <eos>` for Gemma) from the tokenizer so
        // truncation can keep it intact, exactly like Hugging Face `truncation=True`.
        let tokenizer = await container.tokenizer
        let probe = "a"
        let body = tokenizer.encode(text: probe, addSpecialTokens: false)
        let full = tokenizer.encode(text: probe, addSpecialTokens: true)
        guard !body.isEmpty, let start = Self.firstIndex(of: body, in: full) else {
            throw MLXEmbedderError.unsupportedModel("cannot derive the tokenizer's special tokens")
        }
        let leading = Array(full[..<start])
        let trailing = Array(full[(start + body.count)...])
        let padTokenID = tokenizer.convertTokenToId("<pad>") ?? 0

        // Hub snapshots live in `…/snapshots/<commit>`; that commit pins the vector space.
        let directory = try await container.modelDirectory.resolvingSymlinksInPath()
        let revision =
            directory.deletingLastPathComponent().lastPathComponent == "snapshots"
            ? directory.lastPathComponent : nil

        let info = EmbeddingModelInfo(
            modelID: configuration.modelID, revision: revision,
            dimensions: configuration.dimensions)
        progress(1)
        return MLXTextEmbedder(
            configuration: configuration, info: info, container: container,
            tokenizer: tokenizer, leadingTokens: leading, trailingTokens: trailing,
            padTokenID: padTokenID)
    }

    /// One Hub client for every load (text and vision). `#hubDownloader()` makes a `HubClient`,
    /// whose URLSession is never invalidated: one per load kept ~0.2 MB of networking objects
    /// (sessions, paths, certificates) for the life of the process.
    static let hub: any Downloader = #hubDownloader()

    /// Runs a model load with a random key of its own. Module initializers draw placeholder weights
    /// (replaced by the checkpoint's) from MLX's global key, which splits lazily: the modules a
    /// load builds on the calling task chained 483 never-evaluated splits onto it, kept for the
    /// life of the process (~1.7 MB per load). This key and its chain go away with the load.
    static func withLoadRandomState<R>(_ body: () async throws -> R) async rethrows -> R {
        try await withRandomState(MLXRandom.RandomState(), body: body)
    }

    /// Returns MLX's cached buffers to the system. Freed weights first land in that cache, so call
    /// this after the last reference to an embedder was dropped (see `OnDemandEmbedder`).
    ///
    /// Also reseeds MLX's global key, dropping the chain of splits behind it: the vision tower is
    /// built at the first image on a GCD thread, out of `withLoadRandomState`'s reach, and drew 114
    /// splits from that key per load. Nothing here uses MLX's random numbers otherwise.
    public static func releaseCachedMemory() {
        MLXRandom.globalState.seed(DispatchTime.now().uptimeNanoseconds)
        Memory.clearCache()
    }

    /// Runs one tiny forward pass so Metal pipelines are compiled before the first real query.
    public func warmUp() async throws {
        _ = try await embed([.query("warm up")])
    }

    /// Token ids exactly as fed to the model (prompt-formatted, special tokens, truncated).
    public func tokenize(_ input: EmbeddingInput) -> [Int] {
        let body = tokenizer.encode(text: EmbeddingPrompt.format(input), addSpecialTokens: false)
        let budget = configuration.maxTokens - leadingTokens.count - trailingTokens.count
        return leadingTokens + body.prefix(budget) + trailingTokens
    }

    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        if inputs.isEmpty { return [] }
        let tokenized = inputs.map(tokenize)

        // Longest first: similar lengths share a batch (little padding) and the largest pass
        // runs first, so memory problems surface immediately.
        let order = tokenized.indices.sorted { tokenized[$0].count > tokenized[$1].count }
        var results = [[Float]](repeating: [], count: inputs.count)
        var cursor = 0
        while cursor < order.count {
            let longest = tokenized[order[cursor]].count
            let fit = max(1, Self.maxTokensPerPass / longest)
            let end = min(order.count, cursor + min(configuration.batchSize, fit))
            let batch = Array(order[cursor ..< end])
            let vectors = try await forward(batch.map { tokenized[$0] })
            for (slot, index) in batch.enumerated() {
                guard vectors[slot].allSatisfy(\.isFinite) else {
                    throw MLXEmbedderError.nonFiniteEmbedding(index: index)
                }
                results[index] = VectorMath.truncated(vectors[slot], to: configuration.dimensions)
            }
            cursor = end
        }
        return results
    }

    /// One padded forward pass. Returns full-size (unit-length) float32 vectors.
    private func forward(_ batch: [[Int]]) async throws -> [[Float]] {
        let length = batch.map(\.count).max() ?? 0
        let padded = batch.contains { $0.count != length }
        var ids = [Int32]()
        var mask = [Int32]()
        ids.reserveCapacity(batch.count * length)
        if padded { mask.reserveCapacity(batch.count * length) }
        for row in batch {
            let padding = length - row.count
            for token in row { ids.append(Int32(token)) }
            ids.append(contentsOf: repeatElement(Int32(padTokenID), count: padding))
            // Only a padded batch passes a mask.
            if padded {
                mask.append(contentsOf: repeatElement(1, count: row.count))
                mask.append(contentsOf: repeatElement(0, count: padding))
            }
        }
        let rows = batch.count
        return try await container.perform { [ids, mask] context in
            let inputIds = MLXArray(ids, [rows, length])
            // Without padding a mask changes nothing; omitting it keeps attention on its fast path.
            let attentionMask = padded ? MLXArray(mask, [rows, length]) : nil
            let output = context.model(
                inputIds, positionIds: nil, tokenTypeIds: nil, attentionMask: attentionMask)
            let pooled = context.pooling(output, mask: attentionMask, normalize: true)
                .asType(.float32)
            try checkedEval(pooled)
            let flat = pooled.asArray(Float.self)
            let width = pooled.dim(-1)
            return (0 ..< rows).map { Array(flat[($0 * width) ..< (($0 + 1) * width)]) }
        }
    }

    private static func firstIndex(of needle: [Int], in haystack: [Int]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        return (0 ... haystack.count - needle.count).first {
            Array(haystack[$0 ..< $0 + needle.count]) == needle
        }
    }
}
