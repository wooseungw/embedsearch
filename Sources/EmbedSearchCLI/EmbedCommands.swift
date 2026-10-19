import ArgumentParser
import Darwin
import EmbedCore
import EmbedMLX
import Foundation
import MLX
import Synchronization

// Owner: embedding track. `embed`, `parity`, `bench` subcommands.

extension MLXEmbedderPrecision: ExpressibleByArgument {}

struct MLXEmbedderOptions: ParsableArguments {
    @Option(name: .customLong("model"), help: "Hugging Face repo id or local model directory.")
    var modelID = MLXEmbedderConfiguration.default.modelID

    @Option(name: .customLong("dims"), help: "Output dimensions: 768, 512, 256 or 128.")
    var dimensions = MLXEmbedderConfiguration.default.dimensions

    @Option(help: "Maximum tokens per input (including <bos>/<eos>).")
    var maxTokens = MLXEmbedderConfiguration.default.maxTokens

    @Option(help: "Maximum inputs per forward pass.")
    var batchSize = MLXEmbedderConfiguration.default.batchSize

    @Option(help: "Activation precision: float32 (layers upcast) or bfloat16 (checkpoint dtype).")
    var precision = MLXEmbedderConfiguration.default.precision

    @Option(help: "MLX buffer cache limit in MB (default: MLXEmbedderConfiguration's).")
    var cacheLimitMB: Int?

    func configuration(dimensions: Int? = nil, maxTokens: Int? = nil) -> MLXEmbedderConfiguration {
        MLXEmbedderConfiguration(
            modelID: modelID, dimensions: dimensions ?? self.dimensions,
            maxTokens: maxTokens ?? self.maxTokens, batchSize: batchSize, precision: precision,
            cacheLimit: cacheLimitMB.map { $0 * 1024 * 1024 } ?? MLXEmbedderConfiguration.default.cacheLimit)
    }

    func load(dimensions: Int? = nil, maxTokens: Int? = nil) async throws -> MLXTextEmbedder {
        let lastReported = Mutex(-1)
        return try await MLXTextEmbedder.load(configuration(dimensions: dimensions, maxTokens: maxTokens)) {
            fraction in
            let percent = Int(fraction * 100)
            let report = lastReported.withLock { last in
                defer { if percent / 10 > last / 10 { last = percent } }
                return percent / 10 > last / 10 && percent < 100
            }
            if report { stderrLine("  download \(percent)%") }
        }
    }
}

struct EmbedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Embed texts with MLX and print norms, leading values and pairwise cosines.")

    @OptionGroup var options: MLXEmbedderOptions

    @Flag(help: "Embed the texts as documents (`title: … | text: …`) instead of queries.")
    var document = false

    @Option(help: "Document title (with --document).")
    var title: String?

    @Option(help: "Leading values to print per vector.")
    var head = 6

    @Argument(help: "Texts to embed.")
    var texts: [String]

    func run() async throws {
        let embedder = try await options.load()
        print("model: \(embedder.info.cacheKey)")
        let inputs: [EmbeddingInput] = texts.map {
            document ? .document(title: title, text: $0) : .query($0)
        }
        let start = ContinuousClock.now
        let vectors = try await embedder.embed(inputs)
        let elapsed = ContinuousClock.now - start
        print("embedded \(inputs.count) input(s) in \(format(elapsed))")
        for (index, (input, vector)) in zip(inputs, vectors).enumerated() {
            let norm = vector.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
            let values = vector.prefix(head).map { String(format: "%+.5f", $0) }.joined(separator: " ")
            print(
                "[\(index)] dims=\(vector.count) tokens=\(embedder.tokenize(input).count) "
                    + "norm=\(String(format: "%.6f", norm)) [\(values) …]")
            print("    \(EmbeddingPrompt.format(input).prefix(100))")
        }
        guard vectors.count > 1 else { return }
        print("\ncosine")
        print("     " + vectors.indices.map { String(format: "%7d", $0) }.joined())
        for i in vectors.indices {
            let row = vectors.indices.map { String(format: "%7.4f", cosine(vectors[i], vectors[$0])) }
            print(String(format: "%4d ", i) + row.joined())
        }
    }
}

struct ParityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parity",
        abstract: "Compare MLX embeddings with the Python fp32 reference (tools/parity/reference.json).")

    @OptionGroup var options: MLXEmbedderOptions

    @Option(help: "Reference JSON written by tools/parity/make_reference.py.")
    var reference = "tools/parity/reference.json"

    @Option(help: "Minimum cosine to the reference for every row.")
    var threshold = 0.999

    @Option(help: "Maximum 1 - cosine between batched and one-by-one MLX vectors.")
    var batchTolerance = 1e-4

    @Option(
        name: .customLong("check-dims"), parsing: .upToNextOption,
        help: "Dimensions to check (each must be in the reference).")
    var checkDims: [Int] = [768, 256]

    @Flag(help: "Print every row, not just the worst ones.")
    var verbose = false

    func run() async throws {
        let data = try Data(contentsOf: URL(filePath: reference))
        let ref = try JSONDecoder().decode(ParityReference.self, from: data)
        print("reference: \(ref.modelID)@\(ref.revision) \(ref.dtype)/\(ref.device) attn=\(ref.attnImplementation)")
        print(
            "  torch \(ref.versions["torch"] ?? "?"), transformers \(ref.versions["transformers"] ?? "?"), "
                + "sentence-transformers \(ref.versions["sentence_transformers"] ?? "?")")
        print("  \(ref.items.count) rows + \(ref.truncation.items.count) truncation rows (maxTokens \(ref.truncation.maxTokens))")
        guard ref.promptVersion == EmbeddingPrompt.version else {
            throw ValidationError("reference prompt version \(ref.promptVersion) != \(EmbeddingPrompt.version)")
        }

        var failures: [String] = []
        for dims in checkDims {
            let embedder = try await options.load(dimensions: dims)
            print(
                "\n== \(embedder.info.cacheKey), \(options.precision), batchSize \(options.batchSize), "
                    + "maxTokens \(options.maxTokens)")
            failures += try await check(ref.items, dims: dims, embedder: embedder, label: "d\(dims)")
        }
        let truncating = try await options.load(dimensions: 768, maxTokens: ref.truncation.maxTokens)
        print("\n== truncation: \(truncating.info.cacheKey), maxTokens \(ref.truncation.maxTokens)")
        failures += try await check(ref.truncation.items, dims: 768, embedder: truncating, label: "trunc")

        if failures.isEmpty {
            print("\nPASS: every row ≥ \(threshold) vs reference, batch == single within \(batchTolerance), tokens identical")
        } else {
            print("\nFAIL:")
            failures.forEach { print("  - \($0)") }
            throw ExitCode.failure
        }
    }

    private func check(
        _ items: [ParityReference.Item], dims: Int, embedder: MLXTextEmbedder, label: String
    ) async throws -> [String] {
        var failures: [String] = []
        let inputs = items.map(\.input)
        for (item, input) in zip(items, inputs) {
            let prompt = EmbeddingPrompt.format(input)
            if prompt != item.prompt {
                failures.append("\(label) \(item.id): prompt differs: \(prompt.debugDescription) vs \(item.prompt.debugDescription)")
            }
            let tokens = embedder.tokenize(input)
            if tokens != item.tokenIDs {
                let at =
                    zip(tokens, item.tokenIDs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    ?? min(tokens.count, item.tokenIDs.count)
                failures.append(
                    "\(label) \(item.id): token ids differ at \(at) (swift \(tokens.count), python \(item.tokenIDs.count))")
            }
        }

        var single: [[Float]] = []
        let singleStart = ContinuousClock.now
        for input in inputs { single.append(try await embedder.embed([input])[0]) }
        let singleTime = ContinuousClock.now - singleStart
        let batchStart = ContinuousClock.now
        let batched = try await embedder.embed(inputs)
        let batchTime = ContinuousClock.now - batchStart

        // Thread safety: the same inputs from concurrent tasks must give the one-by-one vectors.
        let concurrent = try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, try await embedder.embed([input])[0]) }
            }
            var vectors = [[Float]](repeating: [], count: inputs.count)
            for try await (index, vector) in group { vectors[index] = vector }
            return vectors
        }
        let concurrentDrift = zip(concurrent, single).map { 1 - cosine($0, $1) }.max() ?? 0
        if concurrentDrift > batchTolerance {
            failures.append("\(label): concurrent calls drift \(concurrentDrift) > \(batchTolerance)")
        }

        struct Row { let id: String; let tokens: Int; let single: Double; let batch: Double; let drift: Double }
        var rows: [Row] = []
        for (index, item) in items.enumerated() {
            guard let expected = item.embedding[String(dims)] else {
                throw ValidationError("reference has no \(dims)-d vectors")
            }
            rows.append(
                Row(
                    id: item.id, tokens: item.tokenIDs.count,
                    single: cosine(single[index], expected), batch: cosine(batched[index], expected),
                    drift: 1 - cosine(batched[index], single[index])))
        }

        let shown = verbose ? rows : Array(rows.sorted { min($0.single, $0.batch) < min($1.single, $1.batch) }.prefix(8))
        print("  \(verbose ? "all rows" : "worst rows"):")
        print("  " + "id".padding(toLength: 22, withPad: " ", startingAt: 0) + "tokens  cos(single)  cos(batch)  1-cos(b,s)")
        for row in shown {
            print(
                "  " + row.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                    + String(format: "%6d  %10.6f  %10.6f  %10.2e", row.tokens, row.single, row.batch, row.drift))
        }
        let singles = rows.map(\.single), batches = rows.map(\.batch), drifts = rows.map(\.drift)
        print(
            String(
                format: "  single: min %.6f mean %.6f | batch: min %.6f mean %.6f | max batch drift %.2e",
                singles.min()!, mean(singles), batches.min()!, mean(batches), drifts.max()!))
        print(String(format: "  concurrent one-by-one calls vs sequential: max drift %.2e", concurrentDrift))
        print("  time: one-by-one \(format(singleTime)), batched \(format(batchTime))")

        for row in rows {
            if row.single < threshold { failures.append("\(label) \(row.id): single cosine \(row.single) < \(threshold)") }
            if row.batch < threshold { failures.append("\(label) \(row.id): batch cosine \(row.batch) < \(threshold)") }
            if row.drift > batchTolerance { failures.append("\(label) \(row.id): batch drift \(row.drift) > \(batchTolerance)") }
        }
        return failures
    }
}

struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Measure cold load, query latency, document throughput and memory.")

    @OptionGroup var options: MLXEmbedderOptions

    @Option(help: "Timed single-query runs per query length.")
    var iterations = 50

    @Option(help: "Documents per throughput measurement.")
    var documents = 64

    @Option(parsing: .upToNextOption, help: "Query lengths in tokens.")
    var queryTokens: [Int] = [16, 64]

    @Option(parsing: .upToNextOption, help: "Document lengths in tokens.")
    var documentTokens: [Int] = [256, 512]

    @Option(parsing: .upToNextOption, help: "Batch sizes for document throughput (each ≤ --batch-size).")
    var batchSizes: [Int] = [1, 8, 32]

    func run() async throws {
        print("machine: \(machineDescription()), load average \(loadAverage())")
        printMemory("start")

        let loadStart = ContinuousClock.now
        let embedder = try await options.load()
        let loadTime = ContinuousClock.now - loadStart
        print("model: \(embedder.info.cacheKey), \(options.precision), batchSize \(options.batchSize)")
        print("cold load: \(format(loadTime)) (weights from local cache)")
        printMemory("after load")

        let warmStart = ContinuousClock.now
        try await embedder.warmUp()
        print("first inference (warm-up): \(format(ContinuousClock.now - warmStart))")
        printMemory("after warm-up")

        print("\nquery latency (single query per call, \(iterations) runs)")
        for target in queryTokens {
            let query = EmbeddingInput.query(text(tokens: target, embedder: embedder) { .query($0) })
            for _ in 0 ..< 3 { _ = try await embedder.embed([query]) }
            var samples: [Duration] = []
            for _ in 0 ..< iterations {
                let start = ContinuousClock.now
                _ = try await embedder.embed([query])
                samples.append(ContinuousClock.now - start)
            }
            samples.sort()
            print(
                "  ~\(target) tokens (actual \(embedder.tokenize(query).count)): "
                    + "p50 \(format(percentile(samples, 0.5))) p95 \(format(percentile(samples, 0.95))) "
                    + "min \(format(samples.first!)) max \(format(samples.last!))")
        }
        printMemory("after queries")

        print("\ndocument throughput (\(documents) documents per run)")
        for target in documentTokens {
            let docs = (0 ..< documents).map { index -> EmbeddingInput in
                let body = text(tokens: target, embedder: embedder, seed: index) {
                    .document(title: "Document \(index)", text: $0)
                }
                return .document(title: "Document \(index)", text: body)
            }
            let actual = docs.map { embedder.tokenize($0).count }
            for batch in batchSizes where batch <= options.batchSize {
                _ = try await embedder.embed(Array(docs.prefix(batch)))
                Memory.peakMemory = 0  // resets MLX's peak counter
                let start = ContinuousClock.now
                var cursor = 0
                while cursor < docs.count {
                    let end = min(docs.count, cursor + batch)
                    _ = try await embedder.embed(Array(docs[cursor ..< end]))
                    cursor = end
                }
                let seconds = seconds(ContinuousClock.now - start)
                let tokens = actual.reduce(0, +)
                print(
                    "  ~\(target) tokens (mean \(actual.reduce(0, +) / actual.count)), batch \(batch): "
                        + String(format: "%.1f docs/s, %.0f tokens/s, %.1f ms/doc", Double(docs.count) / seconds,
                                 Double(tokens) / seconds, seconds * 1000 / Double(docs.count))
                        + ", MLX peak \(megabytes(Memory.peakMemory))")
            }
            printMemory("after \(target)-token docs")
        }
        Memory.clearCache()
        printMemory("after MLX clearCache")
        print("load average at end: \(loadAverage())")
    }

    /// Deterministic mixed Korean/English text whose formatted input has ≈ `tokens` tokens.
    private func text(
        tokens: Int, embedder: MLXTextEmbedder, seed: Int = 0, wrap: (String) -> EmbeddingInput
    ) -> String {
        let words = [
            "블루투스", "settings", "화면", "brightness", "배터리", "launcher", "단축키", "keyboard",
            "알림", "display", "개인정보", "privacy", "음악", "music", "파일", "folder", "검색", "search",
        ]
        func candidate(_ count: Int) -> String {
            (0 ..< count).map { words[($0 * 7 + seed) % words.count] }.joined(separator: " ")
        }
        // Largest word count whose formatted input does not exceed the target.
        var low = 1, high = tokens
        while low < high {
            let mid = (low + high + 1) / 2
            if embedder.tokenize(wrap(candidate(mid))).count <= tokens { low = mid } else { high = mid - 1 }
        }
        return candidate(low)
    }
}

// MARK: - Reference file

private struct ParityReference: Decodable {
    struct Item: Decodable {
        let id: String
        let kind: String
        let title: String?
        let text: String
        let prompt: String
        let tokenIDs: [Int]
        let embedding: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case id, kind, title, text, prompt, embedding
            case tokenIDs = "token_ids"
        }

        var input: EmbeddingInput {
            kind == "query" ? .query(text) : .document(title: title, text: text)
        }
    }

    struct Truncation: Decodable {
        let maxTokens: Int
        let items: [Item]
        enum CodingKeys: String, CodingKey {
            case items
            case maxTokens = "max_tokens"
        }
    }

    let modelID: String
    let revision: String
    let promptVersion: String
    let dtype: String
    let device: String
    let attnImplementation: String
    let versions: [String: String]
    let items: [Item]
    let truncation: Truncation

    enum CodingKeys: String, CodingKey {
        case revision, dtype, device, versions, items, truncation
        case modelID = "model_id"
        case promptVersion = "prompt_version"
        case attnImplementation = "attn_implementation"
    }
}

// MARK: - Helpers

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count, "dimension mismatch \(a.count) vs \(b.count)")
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices {
        dot += Double(a[i]) * Double(b[i])
        na += Double(a[i]) * Double(a[i])
        nb += Double(b[i]) * Double(b[i])
    }
    return dot / max((na * nb).squareRoot(), 1e-12)
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

private func format(_ duration: Duration) -> String {
    let s = seconds(duration)
    return s >= 1 ? String(format: "%.2f s", s) : String(format: "%.1f ms", s * 1000)
}

private func percentile(_ sorted: [Duration], _ p: Double) -> Duration {
    sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

private func stderrLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func megabytes(_ bytes: some BinaryInteger) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

/// Physical footprint (what Activity Monitor shows), peak RSS, and MLX's own allocator counters.
private func printMemory(_ label: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let footprint = result == KERN_SUCCESS ? megabytes(info.phys_footprint) : "?"
    let peakFootprint = result == KERN_SUCCESS ? megabytes(info.ledger_phys_footprint_peak) : "?"
    print(
        "  [mem \(label)] footprint \(footprint) (peak \(peakFootprint)), peak RSS \(megabytes(usage.ru_maxrss)), "
            + "MLX active \(megabytes(Memory.activeMemory)) cache \(megabytes(Memory.cacheMemory)) peak \(megabytes(Memory.peakMemory))")
}

/// 1/5/15-minute load averages: benchmarks are only comparable on an otherwise idle machine.
private func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return "?" }
    return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
}

private func machineDescription() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    let cpu = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let memory = ProcessInfo.processInfo.physicalMemory
    return "\(cpu), \(memory / 1_073_741_824) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
}
