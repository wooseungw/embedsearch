import Accelerate
import Foundation

/// Exact (brute-force) inner-product index: one contiguous row-major Float matrix, Accelerate
/// matrix–vector product, partial top-k selection. Vectors are expected to be L2-normalized, so the
/// score is the cosine similarity. Removal swaps the last row into the hole (O(dim)).
public struct VectorIndex: Sendable {
    public let dimensions: Int
    private var matrix: [Float] = []
    private var rowIDs: [String] = []
    private var rowOf: [String: Int] = [:]

    public init(dimensions: Int) {
        precondition(dimensions > 0)
        self.dimensions = dimensions
    }

    /// Rows `ids[r]` ↔ `matrix[r·dimensions ..< (r+1)·dimensions]`, adopting `matrix` without a copy.
    /// A repeated id keeps its first row and takes the later vector, like `upsert`.
    init(dimensions: Int, ids: [String], matrix: [Float]) {
        precondition(dimensions > 0 && matrix.count == ids.count * dimensions, "matrix is not ids × dimensions")
        var rowOf: [String: Int] = [:]
        rowOf.reserveCapacity(ids.count)
        for (r, id) in ids.enumerated() {
            guard rowOf.updateValue(r, forKey: id) != nil else { continue }
            // Rare: build through upsert to keep its semantics.
            var index = VectorIndex(dimensions: dimensions)
            for (r, id) in ids.enumerated() { index.upsert(id: id, vector: Array(matrix[(r * dimensions)..<((r + 1) * dimensions)])) }
            self = index
            return
        }
        self.dimensions = dimensions
        self.matrix = matrix
        rowIDs = ids
        self.rowOf = rowOf
    }

    public var count: Int { rowIDs.count }
    public var ids: [String] { rowIDs }
    public func contains(_ id: String) -> Bool { rowOf[id] != nil }
    func row(of id: String) -> Int? { rowOf[id] }
    func id(atRow row: Int) -> String { rowIDs[row] }

    public func vector(for id: String) -> [Float]? {
        guard let r = rowOf[id] else { return nil }
        return Array(matrix[(r * dimensions)..<((r + 1) * dimensions)])
    }

    /// Adds the vector, or replaces it when `id` is already present.
    public mutating func upsert(id: String, vector: [Float]) {
        precondition(vector.count == dimensions, "dimension mismatch \(vector.count) vs \(dimensions)")
        if let r = rowOf[id] {
            matrix.replaceSubrange((r * dimensions)..<((r + 1) * dimensions), with: vector)
        } else {
            rowOf[id] = rowIDs.count
            rowIDs.append(id)
            matrix.append(contentsOf: vector)
        }
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let r = rowOf.removeValue(forKey: id) else { return false }
        let last = rowIDs.count - 1
        if r != last {
            let lastID = rowIDs[last]
            let d = dimensions
            matrix.withUnsafeMutableBufferPointer { m in
                (m.baseAddress! + r * d).update(from: m.baseAddress! + last * d, count: d)
            }
            rowIDs[r] = lastID
            rowOf[lastID] = r
        }
        rowIDs.removeLast()
        matrix.removeLast(dimensions)
        return true
    }

    /// Removes every row whose id satisfies `shouldRemove`, in one in-place pass that keeps the
    /// order of the remaining rows.
    public mutating func removeAll(where shouldRemove: (String) -> Bool) {
        let d = dimensions
        var kept = 0
        matrix.withUnsafeMutableBufferPointer { m in
            for r in rowIDs.indices where !shouldRemove(rowIDs[r]) {
                if kept != r {
                    (m.baseAddress! + kept * d).update(from: m.baseAddress! + r * d, count: d)
                    rowIDs[kept] = rowIDs[r]
                }
                kept += 1
            }
        }
        guard kept < rowIDs.count else { return }
        rowIDs.removeLast(rowIDs.count - kept)
        matrix.removeLast(matrix.count - kept * d)
        rowOf = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($1, $0) })
    }

    /// All scores (row order = `ids`).
    public func scores(for query: [Float]) -> [Float] {
        [Float](unsafeUninitializedCapacity: rowIDs.count) { out, n in
            computeScores(query, into: out)
            n = rowIDs.count
        }
    }

    /// Scores into a temporary buffer (no heap array per query).
    func withScores<R>(for query: [Float], _ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try withUnsafeTemporaryAllocation(of: Float.self, capacity: rowIDs.count) { out in
            computeScores(query, into: out)
            return try body(UnsafeBufferPointer(out))
        }
    }

    private func computeScores(_ query: [Float], into out: UnsafeMutableBufferPointer<Float>) {
        precondition(query.count == dimensions, "dimension mismatch \(query.count) vs \(dimensions)")
        let n = rowIDs.count
        guard n > 0 else { return }
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                // (n × d) · (d × 1) → (n × 1)
                vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1,
                          vDSP_Length(n), 1, vDSP_Length(dimensions))
            }
        }
    }

    /// Top-k ids by inner product, best first.
    public func search(_ query: [Float], k: Int) -> [(id: String, score: Float)] {
        guard k > 0, !rowIDs.isEmpty else { return [] }
        return withScores(for: query) { scores in Self.topK(scores, k: k).map { (rowIDs[$0], scores[$0]) } }
    }

    /// Indices of the k largest values, descending (ties by lower index). Min-heap of size k.
    static func topK(_ values: [Float], k: Int) -> [Int] {
        values.withUnsafeBufferPointer { topK($0, k: k) }
    }

    static func topK(_ values: UnsafeBufferPointer<Float>, k: Int) -> [Int] {
        let k = min(k, values.count)
        guard k > 0 else { return [] }
        // "a ranks below b" for the min-heap root = the worst kept element.
        @inline(__always) func below(_ a: Int, _ b: Int) -> Bool { values[a] < values[b] || (values[a] == values[b] && a > b) }
        var heap = [Int](unsafeUninitializedCapacity: k) { _, n in n = 0 }
        for i in 0..<values.count {
            if heap.count < k {
                heap.append(i)
                var c = heap.count - 1
                while c > 0 {
                    let p = (c - 1) / 2
                    guard below(heap[c], heap[p]) else { break }
                    heap.swapAt(c, p)
                    c = p
                }
            } else if below(heap[0], i) {
                heap[0] = i
                var p = 0
                while true {
                    let l = 2 * p + 1, r = l + 1
                    var m = p
                    if l < k, below(heap[l], heap[m]) { m = l }
                    if r < k, below(heap[r], heap[m]) { m = r }
                    if m == p { break }
                    heap.swapAt(p, m)
                    p = m
                }
            }
        }
        return heap.sorted { below($1, $0) }
    }
}
