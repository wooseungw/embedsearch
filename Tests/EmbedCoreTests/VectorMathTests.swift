import Testing
@testable import EmbedCore

@Suite struct VectorMathTests {
    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    @Test func normalizedHasUnitLengthAndKeepsDirection() {
        let v: [Float] = [3, 4]
        let n = VectorMath.normalized(v)
        #expect(abs(n[0] - 0.6) < 1e-7 && abs(n[1] - 0.8) < 1e-7)
        #expect(abs(norm(VectorMath.normalized([1, -2, 3, -4, 5])) - 1) < 1e-6)
    }

    @Test func normalizedLeavesZeroVectorUnchanged() {
        #expect(VectorMath.normalized([0, 0, 0]) == [0, 0, 0])
        #expect(VectorMath.normalized([]) == [])
    }

    @Test func normalizingTwiceIsStable() {
        let once = VectorMath.normalized([0.1, 0.7, -0.2, 0.05])
        let twice = VectorMath.normalized(once)
        for (a, b) in zip(once, twice) { #expect(abs(a - b) < 1e-7) }
    }

    @Test func truncationKeepsPrefixAndRenormalizes() {
        // A unit vector whose 2-d prefix has length 5/13 — truncation must not leave it there.
        let v = VectorMath.normalized([3, 4, 12])
        let t = VectorMath.truncated(v, to: 2)
        #expect(t.count == 2)
        #expect(abs(t[0] - 0.6) < 1e-6 && abs(t[1] - 0.8) < 1e-6)
        #expect(abs(norm(t) - 1) < 1e-6)
    }

    @Test(arguments: [512, 256, 128])
    func matryoshkaDimensionsOfA768Vector(dimensions: Int) {
        let v = VectorMath.normalized((0 ..< 768).map { Float(($0 * 37) % 101) - 50 })
        let t = VectorMath.truncated(v, to: dimensions)
        #expect(t.count == dimensions)
        #expect(abs(norm(t) - 1) < 1e-5)
        // Same direction as the raw prefix.
        let prefix = Array(v.prefix(dimensions))
        #expect(abs(VectorMath.dot(t, prefix) - norm(prefix)) < 1e-5)
    }

    @Test func truncationToFullOrLargerSizeIsIdentity() {
        let v: [Float] = [0.6, 0.8]
        #expect(VectorMath.truncated(v, to: 2) == v)
        #expect(VectorMath.truncated(v, to: 768) == v)
    }

    @Test func dotProduct() {
        #expect(VectorMath.dot([1, 2, 3], [4, -5, 6]) == 12)
        let u = VectorMath.normalized([0.3, -0.1, 0.9])
        #expect(abs(VectorMath.dot(u, u) - 1) < 1e-6)
        #expect(VectorMath.dot([1, 0], [0, 1]) == 0)
    }

    @Test func cosineOrderingSurvivesTruncation() {
        // Re-normalized truncated vectors are directly comparable by dot product.
        let q = VectorMath.truncated(VectorMath.normalized([1, 0.9, 0.1, 0.3]), to: 2)
        let near = VectorMath.truncated(VectorMath.normalized([1, 1, -0.5, 0.2]), to: 2)
        let far = VectorMath.truncated(VectorMath.normalized([-1, 0.2, 0.9, 0.1]), to: 2)
        #expect(VectorMath.dot(q, near) > VectorMath.dot(q, far))
        #expect(VectorMath.dot(q, near) <= 1.000001)
    }
}
