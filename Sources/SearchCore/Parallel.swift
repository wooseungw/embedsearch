import Foundation

enum Parallel {
    /// Splits `0..<count` into contiguous chunks of at least `minimumChunk`, runs `chunk` on them
    /// concurrently and concatenates the results in order. Small inputs run inline.
    static func chunked<T: Sendable>(_ count: Int, minimumChunk: Int = 64,
                                     _ chunk: @Sendable (Range<Int>) -> [T]) -> [T] {
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount * 2, count / max(1, minimumChunk))
        guard chunks > 1 else { return chunk(0..<count) }
        var parts = [[T]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                out[c] = chunk((count * c / chunks)..<(count * (c + 1) / chunks))
            }
        }
        return Array(parts.joined())
    }
}
