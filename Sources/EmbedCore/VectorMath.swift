import Accelerate

public enum VectorMath {
    /// L2-normalizes in place semantics (returns a new array). Zero vectors are returned unchanged.
    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm)
    }

    /// Matryoshka truncation: keep the first `dimensions` values, then re-normalize (required for EmbeddingGemma).
    public static func truncated(_ v: [Float], to dimensions: Int) -> [Float] {
        guard dimensions < v.count else { return v }
        return normalized(Array(v.prefix(dimensions)))
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch \(a.count) vs \(b.count)")
        return vDSP.dot(a, b)
    }
}
