import Darwin
import EmbedCore
import Foundation
import SearchCore

// Model-free benchmark and golden-output snapshot of everything around the embedding model:
// sources → store → lexical + vector indexes → hybrid ranking. A deterministic n-gram embedder
// stands in for EmbeddingGemma, so results are reproducible and timings exclude the model.
//
//   swift run -c release SearchBench --save-corpus /tmp/corpus.json      # snapshot this Mac's items once
//   swift run -c release SearchBench --corpus /tmp/corpus.json --golden /tmp/golden.txt
//   swift run -c release SearchBench --corpus /tmp/corpus.json --synthetic 20000

struct Options {
    var corpus: String?
    var saveCorpus: String?
    var golden: String?
    var synthetic = 0
    var dims = 768
    var reps = 5
    var evalFile = "eval/queries.jsonl"
    /// Keep the benchmark's database files in this directory instead of a deleted temp directory.
    var keepDB: String?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--corpus": corpus = it.next()
            case "--save-corpus": saveCorpus = it.next()
            case "--golden": golden = it.next()
            case "--synthetic": synthetic = Int(it.next() ?? "") ?? 0
            case "--dims": dims = Int(it.next() ?? "") ?? 768
            case "--reps": reps = Int(it.next() ?? "") ?? 5
            case "--eval": evalFile = it.next() ?? evalFile
            case "--keep-db": keepDB = it.next()
            default: fatalError("unknown argument \(a)")
            }
        }
    }
}

/// Hashed character 1–3-grams, L2-normalized (same idea as the test FakeEmbedder).
struct NGramEmbedder: TextEmbedder {
    let info: EmbeddingModelInfo
    init(dimensions: Int) { info = EmbeddingModelInfo(modelID: "bench-ngram", revision: "1", dimensions: dimensions) }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        inputs.map { input in
            switch input {
            case .query(let q): vector(q)
            case .document(let title, let text): vector((title ?? "") + " " + text)
            }
        }
    }

    func vector(_ text: String) -> [Float] {
        let chars = Array(TextNormalizer.compact(text).unicodeScalars.map(\.value))
        var v = [Float](repeating: 0, count: info.dimensions)
        for n in 1...3 where chars.count >= n {
            for i in 0...(chars.count - n) {
                var h: UInt64 = 1469598103934665603
                for c in chars[i..<(i + n)] { h = (h ^ UInt64(c)) &* 1099511628211 }
                v[Int(h % UInt64(info.dimensions))] += Float(n)
            }
        }
        return VectorMath.normalized(v)
    }
}

func syntheticItems(_ n: Int) -> [SearchItem] {
    let words = ["설정", "디스플레이", "네트워크", "키보드", "사운드", "알림", "개인정보", "보안", "배터리", "Bluetooth",
                 "Wi-Fi", "display", "sound", "keyboard", "privacy", "network", "battery", "screen", "time", "mouse"]
    return (0..<n).map { i in
        let a = words[i % words.count], b = words[(i / 7) % words.count], c = words[(i / 13) % words.count]
        return SearchItem(id: "synthetic:\(i)", kind: i % 3 == 0 ? .systemSetting : .application,
                          title: "\(a) \(b) \(i)", subtitle: "\(c) › \(b)",
                          keywords: [a, b, c, "\(c) \(a) 옵션 \(i % 50)", "keyword\(i % 300)"],
                          embeddingTitle: "\(a) \(b) \(i)", embeddingText: "\(a) \(b) \(c) synthetic item \(i)",
                          action: .builtinCommand(id: "noop"), icon: .systemSymbol("questionmark"))
    }
}

// MARK: - Measurement helpers

@inline(__always) func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func heapInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func us(_ ns: UInt64) -> String { String(format: "%.1f µs", Double(ns) / 1_000) }
func ms(_ ns: UInt64) -> String { String(format: "%.2f ms", Double(ns) / 1_000_000) }
func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

func summary(_ label: String, _ samples: [UInt64]) {
    let s = samples.sorted()
    guard !s.isEmpty else { return }
    func p(_ x: Double) -> UInt64 { s[min(s.count - 1, Int((Double(s.count - 1) * x).rounded()))] }
    let mean = s.reduce(0, +) / UInt64(s.count)
    print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) n=\(s.count)  mean \(us(mean))  p50 \(us(p(0.5)))  p95 \(us(p(0.95)))  max \(us(s.last!))")
}

/// Every Character prefix of every query (what the launcher sees while typing), unique, in order.
func keystrokes(_ queries: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for q in queries {
        var prefix = ""
        for ch in q {
            prefix.append(ch)
            if seen.insert(prefix).inserted { out.append(prefix) }
        }
    }
    return out
}

func bits(_ d: Double) -> String { String(d.bitPattern, radix: 16) }

func describe(_ r: SearchResult) -> String {
    let b = r.breakdown
    return "\(r.item.id) \(bits(r.score)) lr=\(b.lexicalRank.map(String.init) ?? "-") ls=\(b.lexicalScore.map(bits) ?? "-") "
        + "sr=\(b.semanticRank.map(String.init) ?? "-") cos=\(b.cosine.map(bits) ?? "-") sig=\(r.signals.map(\.rawValue).sorted().joined(separator: ","))"
}

// MARK: - Main

let options = Options(CommandLine.arguments)

if let path = options.saveCorpus {
    var items: [SearchItem] = []
    let t0 = now()
    for source in DefaultSources.all(includeShortcuts: false) { items += try await source.loadItems() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(items).write(to: URL(filePath: path))
    print("saved \(items.count) items to \(path) (sources loaded in \(ms(now() - t0)))")
    exit(0)
}

var corpus: [SearchItem]
if let path = options.corpus {
    corpus = try JSONDecoder().decode([SearchItem].self, from: Data(contentsOf: URL(filePath: path)))
} else {
    corpus = []
    for source in DefaultSources.all(includeShortcuts: false) { corpus += try await source.loadItems() }
}
corpus += syntheticItems(options.synthetic)
let queries = try EvalSet.load(URL(filePath: options.evalFile)).map(\.q)
let typed = keystrokes(queries)
// Hot loops for `sample <pid>`: PROFILE=lexical|instant|full|load|refresh, PROFILE_SECONDS=n.
if let mode = ProcessInfo.processInfo.environment["PROFILE"] {
    let seconds = ProcessInfo.processInfo.environment["PROFILE_SECONDS"].flatMap(Double.init) ?? 10
    let dir = FileManager.default.temporaryDirectory.appending(path: "searchbench-profile-\(getpid())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try IndexStore(url: dir.appending(path: "index.sqlite"))
    var config = RankingConfig()
    config.useUsageSignals = false
    let engine = SearchEngine(store: store, embedder: NGramEmbedder(dimensions: options.dims),
                              sources: [StaticItemSource(items: corpus)], config: config)
    await engine.refresh()
    let index = LexicalIndex(items: corpus)
    let analyses = typed.map(QueryAnalyzer.analyze)
    print("profiling \(mode) for \(seconds)s, pid \(getpid())")
    fflush(stdout)
    let end = now() + UInt64(seconds * 1e9)
    var n = 0
    while now() < end {
        switch mode {
        case "lexical": for a in analyses { n += index.search(a, limit: 50).count }
        case "instant": for q in typed { n += await engine.instantSearch(q, limit: 50).count }
        case "full": for q in queries { n += try await engine.fullSearch(q, limit: 50).count }
        case "load": await engine.loadFromStore(); n += 1
        case "refresh": await engine.refresh(); n += 1
        case "settings": n += try await SystemSettingsSource().loadItems().count
        case "apps": n += try await ApplicationSource().loadItems().count
        default: fatalError("unknown PROFILE \(mode)")
        }
    }
    print(n)
    try? FileManager.default.removeItem(at: dir)  // `exit` skips `defer`
    exit(0)
}

print("corpus \(corpus.count) items · \(queries.count) queries · \(typed.count) keystroke prefixes · dims \(options.dims)")

// Source scan (real I/O, only when not using a snapshot).
if options.corpus == nil {
    print("sources")
    var total: [UInt64] = []
    var perSource: [String: [UInt64]] = [:]
    for _ in 0..<3 {
        let t = now()
        for source in DefaultSources.all(includeShortcuts: false) {
            let s = now()
            _ = try await source.loadItems()
            perSource[source.name, default: []].append(now() - s)
        }
        total.append(now() - t)
    }
    for (name, samples) in perSource.sorted(by: { $0.key < $1.key }) { summary("loadItems \(name)", samples) }
    summary("loadItems (all, sequential)", total)
}

// MARK: Index construction

print("lexical index")
do {
    var build: [UInt64] = []
    for _ in 0..<options.reps {
        let t = now()
        let index = LexicalIndex(items: corpus)
        build.append(now() - t)
        withExtendedLifetime(index) {}
    }
    summary("LexicalIndex(items:)", build)
    let before = heapInUse()
    let index = LexicalIndex(items: corpus)
    let after = heapInUse()
    print("  heap retained by LexicalIndex: \(mb(after - before))")

    let analyses = typed.map(QueryAnalyzer.analyze)
    var search: [UInt64] = []
    for _ in 0..<options.reps {
        for a in analyses {
            let t = now()
            let hits = index.search(a, limit: 50)
            search.append(now() - t)
            withExtendedLifetime(hits) {}
        }
    }
    summary("LexicalIndex.search (keystrokes)", search)

    var analyze: [UInt64] = []
    var ranking: [UInt64] = []
    let kinds = Dictionary(corpus.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
    for _ in 0..<options.reps {
        for q in typed {
            var t = now()
            let a = QueryAnalyzer.analyze(q)
            analyze.append(now() - t)
            let lex = index.search(a, limit: 50)
            t = now()
            let ranked = HybridRanker.rank(HybridRanker.Input(analysis: a, lexical: lex, semantic: nil, kinds: kinds),
                                           mode: .lexical, config: RankingConfig(), limit: 50)
            ranking.append(now() - t)
            withExtendedLifetime(ranked) {}
        }
    }
    summary("QueryAnalyzer.analyze", analyze)
    summary("HybridRanker.rank (lexical)", ranking)
    withExtendedLifetime(index) {}
}

print("vector index")
do {
    let embedder = NGramEmbedder(dimensions: options.dims)
    let vectors = corpus.map { embedder.vector(($0.embeddingTitle ?? "") + " " + $0.embeddingText) }
    let queryVectors = queries.map(embedder.vector)
    let before = heapInUse()
    var index = VectorIndex(dimensions: options.dims)
    let t = now()
    for (item, v) in zip(corpus, vectors) { index.upsert(id: item.id, vector: v) }
    let built = now() - t
    print("  upsert all: \(ms(built)) · heap retained: \(mb(heapInUse() - before))")
    var search: [UInt64] = []
    for _ in 0..<options.reps {
        for qv in queryVectors {
            let t = now()
            let top = index.search(qv, k: 50)
            search.append(now() - t)
            withExtendedLifetime(top) {}
        }
    }
    summary("VectorIndex.search k=50", search)
}

// MARK: Engine

print("engine (file store)")
let tmp = options.keepDB.map { URL(filePath: $0, directoryHint: .isDirectory) }
    ?? FileManager.default.temporaryDirectory.appending(path: "searchbench-\(getpid())", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { if options.keepDB == nil { try? FileManager.default.removeItem(at: tmp) } }
var config = RankingConfig()
config.useUsageSignals = false
let embedder = NGramEmbedder(dimensions: options.dims)
do {
    let store = try IndexStore(url: tmp.appending(path: "index.sqlite"))
    let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: corpus)], config: config)
    var t = now()
    await engine.refresh()
    print("  refresh (cold: sync + embed + save): \(ms(now() - t))")
    var warm: [UInt64] = []
    for _ in 0..<3 {
        t = now()
        await engine.refresh()
        warm.append(now() - t)
    }
    summary("refresh (warm: nothing changed)", warm)
}

do {
    let store = try IndexStore(url: tmp.appending(path: "index.sqlite"))
    var t = now()
    let hashes = corpus.map(IndexStore.contentHash)
    print("  contentHash × \(corpus.count): \(ms(now() - t))")
    t = now()
    let loaded = try store.allItems()
    print("  store.allItems (\(loaded.count)): \(ms(now() - t))")
    t = now()
    try store.syncItems(corpus)
    print("  store.syncItems (unchanged): \(ms(now() - t))")
    t = now()
    let cached = try store.cachedEmbeddings(hashes: hashes, modelKey: embedder.info.cacheKey)
    print("  store.cachedEmbeddings (\(cached.count)): \(ms(now() - t))")
}

let heapBeforeEngine = heapInUse()
let footprintBefore = physFootprint()
let store = try IndexStore(url: tmp.appending(path: "index.sqlite"))
let engine = SearchEngine(store: store, embedder: embedder, sources: [StaticItemSource(items: corpus)], config: config)
var t0 = now()
await engine.loadFromStore()
print("  loadFromStore (warm start): \(ms(now() - t0))")
print("  heap retained by engine: \(mb(heapInUse() - heapBeforeEngine)) · phys_footprint delta \(mb(physFootprint() - footprintBefore))")

for q in typed { _ = await engine.instantSearch(q, limit: 50) }
var instant: [UInt64] = []
for _ in 0..<options.reps {
    for q in typed {
        let t = now()
        _ = await engine.instantSearch(q, limit: 50)
        instant.append(now() - t)
    }
}
summary("instantSearch (keystrokes)", instant)

for q in queries { _ = try await engine.fullSearch(q, limit: 50) }
var full: [UInt64] = []
for _ in 0..<options.reps {
    for q in queries {
        let t = now()
        _ = try await engine.fullSearch(q, limit: 50)
        full.append(now() - t)
    }
}
summary("fullSearch (cached query vector)", full)

// Usage signals: a realistic query-memory table, then ranking with frecency + memory on.
do {
    let names = corpus.prefix(400).map(\.id)
    let day = 86_400.0
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    for (i, q) in typed.enumerated() where i % 2 == 0 {
        try store.recordSelection(itemID: names[i % names.count], query: q, at: base.addingTimeInterval(Double(i) * 0.01 * day),
                                  halfLife: 14 * day)
    }
    var usageConfig = RankingConfig()
    usageConfig.useUsageSignals = true
    await engine.setConfig(usageConfig)
    await engine.loadFromStore()
    var withUsage: [UInt64] = []
    for _ in 0..<options.reps {
        for q in typed {
            let t = now()
            _ = await engine.instantSearch(q, limit: 50)
            withUsage.append(now() - t)
        }
    }
    summary("instantSearch + usage signals", withUsage)
    var select: [UInt64] = []
    for (i, q) in queries.prefix(40).enumerated() {
        let t = now()
        await engine.recordSelection(itemID: names[i], query: q)
        select.append(now() - t)
    }
    summary("recordSelection", select)
    await engine.setConfig(config)
}

// MARK: Golden output

if let path = options.golden {
    var out = ""
    // Fresh engine + in-memory store so usage records from the benchmark do not leak in.
    let goldenEngine = SearchEngine(store: try IndexStore.inMemory(), embedder: embedder,
                                    sources: [StaticItemSource(items: corpus)], config: config)
    await goldenEngine.refresh()
    for q in typed {
        let a = QueryAnalyzer.analyze(q)
        out += "A\t\(q)\t\(a.normalized)\t\(a.words)\t\(a.contentTokens)\t\(a.intents.map { "\($0.key.rawValue)=\($0.value)" }.sorted())\n"
        for (i, r) in await goldenEngine.instantSearch(q, limit: 50).enumerated() { out += "I\t\(q)\t\(i)\t\(describe(r))\n" }
    }
    for q in queries {
        for mode in SearchMode.allCases {
            for (i, r) in try await goldenEngine.search(q, mode: mode, limit: 50).enumerated() {
                out += "S\t\(mode.rawValue)\t\(q)\t\(i)\t\(describe(r))\n"
            }
        }
    }
    // Query-memory boosts against a synthetic history with a fixed clock.
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    let memoryStore = try IndexStore.inMemory()
    for (i, q) in typed.enumerated() {
        for r in 0..<(1 + i % 3) {
            let at = base.addingTimeInterval(-Double(i) * 3_600 + Double(r))
            try memoryStore.recordSelection(itemID: corpus[i % corpus.count].id, query: q, at: at, halfLife: 14 * 86_400)
        }
    }
    let records = try memoryStore.queryMemoryRecords()
    for q in typed {
        let boosts = Frecency.memoryBoosts(records, query: TextNormalizer.normalize(q), now: base, config: RankingConfig())
        out += "M\t\(q)\t" + boosts.sorted { $0.key < $1.key }.map { "\($0.key)=\(bits($0.value))" }.joined(separator: " ") + "\n"
    }
    for item in corpus.prefix(200) { out += "H\t\(item.id)\t\(IndexStore.contentHash(item))\n" }
    for item in corpus.prefix(500) {
        out += "N\t\(TextNormalizer.normalize(item.title))\t\(Hangul.keystrokeJamo(item.title))\t\(Hangul.choseongString(item.title))\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    print("golden: \(out.split(separator: "\n").count) lines → \(path)")
}
