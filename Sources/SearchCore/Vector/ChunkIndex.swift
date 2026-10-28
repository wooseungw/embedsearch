import Accelerate
import Foundation

/// File content vectors, several per item (PDF text chunks, recognized text, the image itself).
/// Rows stay float16 as stored (half the memory of float32) and are widened a block at a time per
/// query.
///
/// An item's score is its best chunk's cosine minus `hubWeight` × that chunk's hubness: its mean
/// cosine to a fixed set of generic queries (`SearchEngine.hubProbes`). Without it, long documents
/// and text in the query's language come close to every query, and images, whose cosines to text
/// run lower, never surface.
public struct ChunkIndex: Sendable {
    public struct Hit: Sendable, Equatable {
        public let itemID: String
        /// The best chunk's cosine minus its weighted hubness.
        public let score: Float
        /// That chunk's cosine.
        public let cosine: Float
        public let kind: ChunkKind
        /// The PDF page that chunk starts on.
        public let page: Int?
    }

    public let dimensions: Int
    /// Row-major float16 bits, `rowCount × dimensions`.
    private var halves: [UInt16] = []
    private var rowSlot: [Int32] = []
    private var rowKind: [UInt8] = []
    private var rowHub: [Float] = []
    /// 0: no page.
    private var rowPage: [Int32] = []
    private var slotIDs: [String] = []
    private var slotOf: [String: Int32] = [:]
    private var slotRows: [Int32] = []

    /// Rows widened per block when scoring.
    static let block = 1024

    public init(dimensions: Int) {
        precondition(dimensions > 0)
        self.dimensions = dimensions
    }

    public var rowCount: Int { rowSlot.count }
    public var itemCount: Int { slotIDs.count }
    public func chunkCount(of itemID: String) -> Int { slotOf[itemID].map { Int(slotRows[Int($0)]) } ?? 0 }

    /// Appends a chunk of `itemID` from `dimensions` float16 values.
    public mutating func append(itemID: String, kind: ChunkKind, hub: Float, page: Int? = nil,
                                float16 bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count >= dimensions * 2, "chunk has fewer than \(dimensions) float16 values")
        let slot = slot(for: itemID)
        bytes.withMemoryRebound(to: UInt16.self) { halves.append(contentsOf: $0.prefix(dimensions)) }
        rowSlot.append(slot)
        rowKind.append(kind.rawValue)
        rowHub.append(hub)
        rowPage.append(Int32(clamping: page ?? 0))
        slotRows[Int(slot)] += 1
    }

    /// Appends a chunk of `itemID`, rounded to float16.
    public mutating func append(itemID: String, kind: ChunkKind, hub: Float, page: Int? = nil, vector: [Float]) {
        precondition(vector.count == dimensions, "dimension mismatch \(vector.count) vs \(dimensions)")
        IndexStore.float16Data(vector).withUnsafeBytes { append(itemID: itemID, kind: kind, hub: hub, page: page, float16: $0) }
    }

    /// Makes room for `rows` more chunks before a bulk load. Growing one append at a time doubles
    /// the arrays, which left 40 MiB reserved for 16 MB of vectors (measured).
    public mutating func reserveCapacity(forAdditionalRows rows: Int) {
        guard rows > 0 else { return }
        let total = rowSlot.count + rows
        halves.reserveCapacity(total * dimensions)
        rowSlot.reserveCapacity(total)
        rowKind.reserveCapacity(total)
        rowHub.reserveCapacity(total)
        rowPage.reserveCapacity(total)
    }

    /// Gives back the room that growth and removals left, once it is over an eighth of the rows
    /// and 64 KB (malloc's size classes round small arrays up anyway).
    public mutating func shrinkToFit() {
        let spare = (halves.capacity - halves.count) * MemoryLayout<UInt16>.size
        guard spare > halves.count * MemoryLayout<UInt16>.size / 8, spare >= 64 * 1024 else { return }
        halves = Self.exactCopy(halves)
        rowSlot = Self.exactCopy(rowSlot)
        rowKind = Self.exactCopy(rowKind)
        rowHub = Self.exactCopy(rowHub)
        rowPage = Self.exactCopy(rowPage)
    }

    private static func exactCopy<T>(_ array: [T]) -> [T] {
        var copy: [T] = []
        copy.reserveCapacity(array.count)
        copy.append(contentsOf: array)
        return copy
    }

    /// Bytes reserved for the vectors (tests).
    var vectorCapacityBytes: Int { halves.capacity * MemoryLayout<UInt16>.size }

    private mutating func slot(for itemID: String) -> Int32 {
        if let s = slotOf[itemID] { return s }
        let s = Int32(slotIDs.count)
        slotOf[itemID] = s
        slotIDs.append(itemID)
        slotRows.append(0)
        return s
    }

    /// Removes every chunk of the items for which `shouldRemove` is true, keeping row order.
    public mutating func removeAll(where shouldRemove: (String) -> Bool) {
        let drop = slotIDs.map(shouldRemove)
        guard drop.contains(true) else { return }
        var newSlot = [Int32](repeating: -1, count: slotIDs.count)
        var ids: [String] = []
        var rows: [Int32] = []
        for s in slotIDs.indices where !drop[s] {
            newSlot[s] = Int32(ids.count)
            ids.append(slotIDs[s])
            rows.append(slotRows[s])
        }
        let d = dimensions
        var kept = 0
        halves.withUnsafeMutableBufferPointer { h in
            for r in rowSlot.indices {
                let s = newSlot[Int(rowSlot[r])]
                guard s >= 0 else { continue }
                if kept != r {
                    (h.baseAddress! + kept * d).update(from: h.baseAddress! + r * d, count: d)
                    rowKind[kept] = rowKind[r]
                    rowHub[kept] = rowHub[r]
                    rowPage[kept] = rowPage[r]
                }
                rowSlot[kept] = s
                kept += 1
            }
        }
        halves.removeLast(halves.count - kept * d)
        rowSlot.removeLast(rowSlot.count - kept)
        rowKind.removeLast(rowKind.count - kept)
        rowHub.removeLast(rowHub.count - kept)
        rowPage.removeLast(rowPage.count - kept)
        slotIDs = ids
        slotRows = rows
        slotOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Int32($0)) })
    }

    /// The `k` best items, best first (ties: the item added first).
    public func search(_ query: [Float], k: Int, hubWeight: Float) -> [Hit] {
        precondition(query.count == dimensions, "dimension mismatch \(query.count) vs \(dimensions)")
        guard k > 0, !rowSlot.isEmpty else { return [] }
        var best = [Float](repeating: -.infinity, count: slotIDs.count)
        var bestRow = [Int32](repeating: -1, count: slotIDs.count)
        var cosines = [Float](repeating: 0, count: slotIDs.count)
        let d = dimensions, block = Self.block
        withUnsafeTemporaryAllocation(of: Float.self, capacity: block * d) { scratch in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: block) { scores in
                halves.withUnsafeBufferPointer { h in
                    query.withUnsafeBufferPointer { q in
                        for start in stride(from: 0, to: rowSlot.count, by: block) {
                            let n = min(block, rowSlot.count - start)
                            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: h.baseAddress! + start * d),
                                                       height: 1, width: vImagePixelCount(n * d), rowBytes: n * d * 2)
                            var destination = vImage_Buffer(data: scratch.baseAddress!, height: 1,
                                                            width: vImagePixelCount(n * d), rowBytes: n * d * 4)
                            _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
                            vDSP_mmul(scratch.baseAddress!, 1, q.baseAddress!, 1, scores.baseAddress!, 1,
                                      vDSP_Length(n), 1, vDSP_Length(d))
                            for i in 0..<n {
                                let r = start + i
                                let s = Int(rowSlot[r])
                                let adjusted = scores[i] - hubWeight * rowHub[r]
                                if adjusted > best[s] {
                                    best[s] = adjusted
                                    bestRow[s] = Int32(r)
                                    cosines[s] = scores[i]
                                }
                            }
                        }
                    }
                }
            }
        }
        return VectorIndex.topK(best, k: k).map { s in
            let row = Int(bestRow[s])
            return Hit(itemID: slotIDs[s], score: best[s], cosine: cosines[s],
                       kind: ChunkKind(rawValue: rowKind[row]) ?? .text, page: rowPage[row] > 0 ? Int(rowPage[row]) : nil)
        }
    }
}
