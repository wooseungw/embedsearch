import CoreGraphics
import Foundation

/// A decoded image to embed.
public typealias ImageInput = CGImage

/// Embeds images into the same vector space as the `TextEmbedder` with the same `info`
/// (EmbeddingGemma 2's vision tower), so a text query finds pictures by what they show. It embeds
/// text too, with the model it already holds, so indexing files needs one model in memory.
public protocol ImageEmbedder: TextEmbedder {
    /// One L2-normalized vector of `info.dimensions` floats per image, in input order.
    func embed(images: [ImageInput]) async throws -> [[Float]]
}
