import ArgumentParser
import EmbedCore
import EmbedMLX
import Foundation
import SearchCore

// Owner: search track. `index`, `search`, `eval` subcommands.

struct SearchEngineOptions: ParsableArguments {
    @Option(help: "Index database path (default: ~/Library/Application Support/EmbedSearch/index.sqlite).")
    var db: String?

    @Option(name: .customLong("model"), help: "Embedding model: Hugging Face repo id or local directory.")
    var modelID = MLXEmbedderConfiguration.default.modelID

    @Option(name: .customLong("dims"), help: "Embedding dimensions: 768, 512, 256 or 128.")
    var dimensions = MLXEmbedderConfiguration.default.dimensions

    @Flag(help: "Do not load the embedding model (lexical only, engine state .degraded).")
    var noModel = false

    @Flag(help: "Skip `shortcuts list`.")
    var noShortcuts = false

    @Option(help: "MLX buffer cache limit in MB (default: MLXEmbedderConfiguration's).")
    var cacheLimitMB: Int?

    @Option(name: .customLong("folder"), help: "Also search the images and PDFs in this folder (repeatable).")
    var folders: [String] = []

    @Option(help: "Override RankingConfig.minFileScore.")
    var minFileScore: Double?

    @Option(help: "Override RankingConfig.hubWeight.")
    var hubWeight: Double?

    @Option(help: "Override RankingConfig.fileScoreWeight.")
    var fileScoreWeight: Double?

    @Option(help: "Override RankingConfig.fileKeywordRRFWeight.")
    var fileKeywordRRFWeight: Double?

    @Option(help: "Override RankingConfig.fileKeywordScoreWeight.")
    var fileKeywordScoreWeight: Double?

    @Option(help: "Override RankingConfig.minFileKeywordCoverage.")
    var minFileKeywordCoverage: Double?

    @Option(help: "Override RankingConfig.minFileKeywordRarity.")
    var minFileKeywordRarity: Double?

    @Option(help: "Override RankingConfig.fileKeywordCandidates.")
    var fileKeywordCandidates: Int?

    @Option(help: "Override RankingConfig.fileKeywordChunks.")
    var fileKeywordChunks: Int?

    @Option(help: "Override RankingConfig.fileKeywordMaxItemNameScore.")
    var fileKeywordMaxItemNameScore: Double?

    @Option(help: "opendataloader-pdf CLI JAR (default: vendor/opendataloader/opendataloader-pdf-cli.jar, from scripts/fetch-opendataloader.sh).")
    var odlJar = "vendor/opendataloader/opendataloader-pdf-cli.jar"

    @Flag(help: "Read PDFs with PDFKit only, not opendataloader-pdf.")
    var noOdl = false

    func makeEngine(config: RankingConfig = .default, quiet: Bool = false,
                    extraSources: [any ItemSource] = []) async throws -> SearchEngine {
        let store = try db.map { try IndexStore(url: URL(filePath: ($0 as NSString).expandingTildeInPath)) } ?? IndexStore()
        var config = config
        if let minFileScore { config.minFileScore = minFileScore }
        if let hubWeight { config.hubWeight = hubWeight }
        if let fileScoreWeight { config.fileScoreWeight = fileScoreWeight }
        if let fileKeywordRRFWeight { config.fileKeywordRRFWeight = fileKeywordRRFWeight }
        if let fileKeywordScoreWeight { config.fileKeywordScoreWeight = fileKeywordScoreWeight }
        if let minFileKeywordCoverage { config.minFileKeywordCoverage = minFileKeywordCoverage }
        if let minFileKeywordRarity { config.minFileKeywordRarity = minFileKeywordRarity }
        if let fileKeywordCandidates { config.fileKeywordCandidates = max(0, fileKeywordCandidates) }
        if let fileKeywordChunks { config.fileKeywordChunks = max(0, fileKeywordChunks) }
        if let fileKeywordMaxItemNameScore { config.fileKeywordMaxItemNameScore = fileKeywordMaxItemNameScore }
        var embedder: (any TextEmbedder)?
        var configuration = MLXEmbedderConfiguration(modelID: modelID, dimensions: dimensions)
        if let cacheLimitMB { configuration.cacheLimit = cacheLimitMB * 1024 * 1024 }
        if !noModel {
            let start = Date()
            embedder = try await MLXTextEmbedder.load(configuration)
            if !quiet { log("model loaded in \(seconds(Date().timeIntervalSince(start))) — \(embedder!.info.cacheKey)") }
        }
        let engine = SearchEngine(store: store, embedder: embedder,
                                  sources: DefaultSources.all(includeShortcuts: !noShortcuts) + extraSources, config: config)
        // Latencies measure query embedding, and the App's stored query vectors stay untouched.
        await engine.setStoresQueryVectors(false)
        if !folders.isEmpty {
            await engine.setFileFolders(folders.map { URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) })
            if !noOdl {
                let jar = URL(filePath: (odlJar as NSString).expandingTildeInPath)
                if let reader = OpenDataLoader.locate(jar: jar) {
                    await engine.setPDFReader(reader)
                    if !quiet { log("PDFs: opendataloader-pdf via \(reader.java.path(percentEncoded: false))") }
                } else if !quiet {
                    log("PDFs: PDFKit (no Java 11+ or no \(odlJar))")
                }
            }
            if let embedder {
                // The vision model loads only if there are images to embed, and goes after 30 s idle.
                let config = configuration
                await engine.setImageEmbedder(OnDemandImageEmbedder(
                    info: embedder.info, idleTimeout: .seconds(30), load: { try await MLXImageEmbedder.load(config) },
                    didUnload: { MLXTextEmbedder.releaseCachedMemory() }))
            }
        }
        return engine
    }
}

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index", abstract: "Scan sources, embed new/changed items (cached) and print index statistics.")

    @OptionGroup var engineOptions: SearchEngineOptions

    @Option(help: "Write every indexed item as JSON Lines to this path.")
    var dump: String?

    func run() async throws {
        let engine = try await engineOptions.makeEngine()
        let stream = await engine.stateUpdates()
        let progress = Task {
            var lastTenth = -1
            for await state in stream {
                if case .indexing(let done, let total) = state, total > 0 {
                    let tenth = done * 10 / total
                    if tenth != lastTenth { lastTenth = tenth; log("  embedding \(done)/\(total)") }
                }
            }
        }
        let stats = await engine.refreshWithStats()
        progress.cancel()

        print("Sources:")
        for (name, count) in stats.sourceCounts.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(count) items in \(ms(stats.sourceSeconds[name] ?? 0))")
        }
        for (name, error) in stats.sourceErrors.sorted(by: { $0.key < $1.key }) { print("  \(name): ERROR \(error)") }
        print("Items by kind:")
        for kind in ItemKind.allCases { print("  \(kind.rawValue): \(stats.itemCounts[kind] ?? 0)") }
        print("  total: \(stats.totalItems)")
        print("Store sync: +\(stats.sync.inserted) new, ~\(stats.sync.updated) changed, =\(stats.sync.unchanged) unchanged, -\(stats.sync.deleted) deleted")
        print("Scan: \(seconds(stats.scanSeconds))")
        if let key = stats.modelKey {
            print("Embeddings (\(key)): \(stats.embeddedNew) embedded, \(stats.embeddingCacheHits) cache hits, \(stats.vectorCount) vectors in \(seconds(stats.embedSeconds))")
            if stats.embeddedNew > 0 {
                print(String(format: "  throughput: %.1f items/s", Double(stats.embeddedNew) / max(stats.embedSeconds, 1e-9)))
            }
        }
        if let error = stats.embeddingError { print("Embedding error: \(error)") }
        if !engineOptions.folders.isEmpty {
            print("Files: \(stats.filesIndexed) embedded (\(stats.fileErrors) without readable content, \(stats.pdfsStructured) PDFs read by opendataloader-pdf), \(stats.fileTextsRead) read again for their text, \(stats.fileChunks) chunks indexed, \(seconds(stats.fileSeconds))")
            if let error = stats.imageEmbeddingError { print("  image embedding error: \(error)") }
            for f in await engine.fileIndexSummary().folders {
                print("  \(f.path): \(f.images) images, \(f.documents) PDFs · indexed \(f.indexed) (\(f.failed) without content), pending \(f.pending) · \(f.chunks) chunks · \(kb(f.bytes)) stored, \(kb(f.estimatedBytes)) when done\(f.error.map { " · ERROR \($0)" } ?? "")")
            }
        }
        if let size = engine.store.fileSize() {
            let text = (try? engine.store.fileTextBytes()).map { " · keyword index \(kb($0)), vectors \(kb((try? engine.store.fileChunkBytes()) ?? 0))" } ?? ""
            print("Database file: \(kb(size))\(text)")
        }
        print("State: \(await engine.currentState)")

        if let dump {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var lines: [String] = []
            for item in await engine.allItems() {
                lines.append(String(decoding: try encoder.encode(item), as: UTF8.self))
            }
            try lines.joined(separator: "\n").appending("\n").write(toFile: dump, atomically: true, encoding: .utf8)
            print("Wrote \(lines.count) items to \(dump)")
        }
    }
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Run a query against the index and print ranked results.")

    @OptionGroup var engineOptions: SearchEngineOptions

    @Argument(help: "Query text.")
    var query: [String] = []

    @Option(help: "lexical | semantic | hybrid")
    var mode: SearchMode = .hybrid

    @Option(help: "Number of results.")
    var limit = 10

    @Flag(help: "Print the score breakdown, id and action of each result.")
    var explain = false

    @Flag(help: "Use the stored index without rescanning sources.")
    var noRefresh = false

    @Option(help: "Benchmark: run every eval query (or the given query) this many times through instantSearch and fullSearch.")
    var bench: Int?

    @Option(help: "Eval set used by --bench.")
    var benchFile = "eval/queries.jsonl"

    @Option(help: "Add this many synthetic items to the corpus (benchmarking at a larger size).")
    var synthetic = 0

    @Option(help: "Run every line of this file as a query (one model load), printing the top results.")
    var batch: String?

    @Option(help: "File search check: lines `query<TAB>part of the expected file name`; prints the expected file's rank.")
    var expect: String?

    func run() async throws {
        let extra: [any ItemSource] = synthetic > 0 ? [StaticItemSource(name: "synthetic", items: syntheticItems(synthetic))] : []
        let engine = try await engineOptions.makeEngine(extraSources: extra)
        if noRefresh { await engine.loadFromStore() } else { await engine.refresh() }
        if await engine.itemCount == 0 { await engine.refresh() }
        let text = query.joined(separator: " ")

        if let reps = bench {
            try await runBenchmark(engine: engine, reps: reps, single: text.isEmpty ? nil : text)
            return
        }
        if let expect {
            let lines = try String(contentsOfFile: expect, encoding: .utf8).split(separator: "\n")
                .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
                .filter { $0.count == 2 }
            var reciprocal = 0.0, top1 = 0, top5 = 0
            for line in lines {
                let results = try await engine.search(line[0], mode: mode, limit: 50)
                let rank = results.firstIndex { $0.item.kind == .file && $0.item.title.contains(line[1]) }.map { $0 + 1 }
                if let rank {
                    reciprocal += 1 / Double(rank)
                    if rank == 1 { top1 += 1 }
                    if rank <= 5 { top5 += 1 }
                }
                let hit = rank.map { results[$0 - 1] }
                print("\(rank.map { String(format: "%3d", $0) } ?? "  -")  \(line[0])  →  \(hit.map { "\($0.item.title.prefix(50)) [\($0.signals.map(\.rawValue).sorted().joined(separator: ","))]" } ?? "(not in top 50: \(line[1]))")")
            }
            let n = Double(max(1, lines.count))
            print(String(format: "MRR %.3f · top-1 %d/%d · top-5 %d/%d", reciprocal / n, top1, lines.count, top5, lines.count))
            return
        }
        if let batch {
            let queries = try String(contentsOfFile: batch, encoding: .utf8).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            for q in queries {
                let results = try await engine.search(q, mode: mode, limit: limit)
                print("\n「\(q)」")
                for (i, r) in results.enumerated() {
                    if r.section == .settings, i == 0 || results[i - 1].section != .settings { print("  ── 설정 ──") }
                    let b = r.breakdown
                    let signals = r.signals.map(\.rawValue).sorted().joined(separator: ",")
                    print("  \(badge(r.item.kind)) \(signals.padding(toLength: 17, withPad: " ", startingAt: 0)) cos \(f3(b.cosine ?? 0))  \(r.item.title)")
                }
            }
            return
        }
        guard !text.isEmpty else { throw ValidationError("missing query") }

        let start = Date()
        let results = try await engine.search(text, mode: mode, limit: limit)
        let elapsed = Date().timeIntervalSince(start)
        let instantStart = Date()
        _ = await engine.instantSearch(text, limit: limit)
        let instantElapsed = Date().timeIntervalSince(instantStart)

        let analysis = QueryAnalyzer.analyze(text)
        print("\"\(text)\" — \(mode.rawValue), \(results.count) results in \(ms(elapsed)) (instant path \(ms(instantElapsed)))")
        if explain {
            print("  tokens: \(analysis.contentTokens.map { $0.joined(separator: "|") })  intents: \(analysis.intents.map { "\($0.key.rawValue)=\($0.value)" }.sorted())")
            print("  state: \(await engine.currentState)")
        }
        for (i, r) in results.enumerated() {
            if r.section == .settings, i == 0 || results[i - 1].section != .settings { print("    ── 설정 ──") }
            let sub = r.item.subtitle.map { " — \($0)" } ?? ""
            print(String(format: "%2d. [%@] %@%@", i + 1, badge(r.item.kind), r.item.title, sub))
            if explain {
                let b = r.breakdown
                var parts: [String] = []
                if let lr = b.lexicalRank { parts.append(String(format: "lex #%d %.3f", lr, b.lexicalScore ?? 0)) }
                if let sr = b.semanticRank { parts.append(String(format: "sem #%d", sr)) }
                if let kr = b.keywordRank { parts.append(String(format: "kw #%d cov %.2f", kr, b.keywordCoverage ?? 0)) }
                if let c = b.cosine { parts.append(String(format: "cos %.3f", c)) }
                if b.frecencyBoost > 0 { parts.append(String(format: "usage +%.4f", b.frecencyBoost)) }
                parts.append(String(format: "final %.5f", b.final))
                parts.append("signals " + r.signals.map(\.rawValue).sorted().joined(separator: ","))
                print("      \(parts.joined(separator: " · "))")
                print("      \(r.item.id) → \(describe(r.item.action))")
            }
        }
    }
}

extension SearchCommand {
    private func runBenchmark(engine: SearchEngine, reps: Int, single: String?) async throws {
        let queries = try single.map { [$0] } ?? EvalSet.load(URL(filePath: benchFile)).map(\.q)
        print("Corpus: \(await engine.itemCount) items, \(await engine.vectorCount) vectors; \(queries.count) queries × \(reps)")
        // Warm-up of the lexical path only; the first fullSearch per query below embeds the query (cold).
        for q in queries { _ = await engine.instantSearch(q, limit: limit) }
        var instant: [TimeInterval] = []
        for _ in 0..<max(1, reps) {
            for q in queries {
                let t = Date()
                _ = await engine.instantSearch(q, limit: limit)
                instant.append(Date().timeIntervalSince(t))
            }
        }
        report("instantSearch", instant)
        guard await engine.vectorCount > 0 else { return }
        // Cold query embedding: each query embedded once (first fullSearch for that text).
        var cold: [TimeInterval] = []
        for q in queries {
            let t = Date()
            _ = try await engine.fullSearch(q, limit: limit)
            cold.append(Date().timeIntervalSince(t))
        }
        report("fullSearch (query embedding + ranking)", cold)
        var warm: [TimeInterval] = []
        for _ in 0..<max(1, reps) {
            for q in queries {
                let t = Date()
                _ = try await engine.fullSearch(q, limit: limit)
                warm.append(Date().timeIntervalSince(t))
            }
        }
        report("fullSearch (cached query vector)", warm)
    }

    private func report(_ label: String, _ samples: [TimeInterval]) {
        let s = samples.sorted()
        guard !s.isEmpty else { return }
        func p(_ x: Double) -> TimeInterval { s[min(s.count - 1, Int((Double(s.count - 1) * x).rounded()))] }
        print("\(label): n=\(s.count) p50 \(ms(p(0.5))) p95 \(ms(p(0.95))) max \(ms(s.last!))")
    }

    private func syntheticItems(_ n: Int) -> [SearchItem] {
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
}

struct EvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval", abstract: "Evaluate retrieval quality on eval/queries.jsonl (MRR@10, success@1/5).")

    @OptionGroup var engineOptions: SearchEngineOptions

    @Option(help: "Eval set (JSON Lines).")
    var file = "eval/queries.jsonl"

    @Option(help: "lexical | semantic | hybrid | all")
    var mode = "all"

    @Flag(help: "Use the stored index without rescanning sources.")
    var noRefresh = false

    @Option(help: "Print at most this many failures per mode.")
    var maxFailures = 60

    @Flag(help: "Coordinate-descent tuning of fusion weights on odd lines, reported on even (held-out) lines.")
    var tune = false

    @Option(help: "Override RankingConfig.minSemanticCosine.")
    var minCosine: Double?
    @Option(help: "Override RankingConfig.lexicalScoreWeight.")
    var lexicalScoreWeight: Double?
    @Option(help: "Override RankingConfig.semanticRRFWeight.")
    var semanticWeight: Double?
    @Option(help: "Override RankingConfig.cosineWeight.")
    var cosineWeight: Double?
    @Option(help: "Override RankingConfig.intentWeight.")
    var intentWeight: Double?

    func run() async throws {
        let queries = try EvalSet.load(URL(filePath: file))
        var config = RankingConfig.default
        config.useUsageSignals = false
        if let minCosine { config.minSemanticCosine = minCosine }
        if let lexicalScoreWeight { config.lexicalScoreWeight = lexicalScoreWeight }
        if let semanticWeight { config.semanticRRFWeight = semanticWeight }
        if let cosineWeight { config.cosineWeight = cosineWeight }
        if let intentWeight { config.intentWeight = intentWeight }

        let engine = try await engineOptions.makeEngine(config: config)
        if noRefresh { await engine.loadFromStore() } else { await engine.refresh() }
        let items = await engine.allItems()
        print("Corpus: \(items.count) items — " + ItemKind.allCases.map { k in "\(k.rawValue) \(items.filter { $0.kind == k }.count)" }.joined(separator: ", "))
        print("State: \(await engine.currentState)")
        let unmatched = EvalSet.unmatchedExpectations(queries, items: items)
        if !unmatched.isEmpty {
            print("WARNING: \(unmatched.count) expectations match no item:")
            for u in unmatched { print("  \(u)") }
        }
        print("Queries: \(queries.count) — " + Dictionary(grouping: queries, by: \.lang).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))

        if tune {
            try await runTuning(engine: engine, queries: queries, base: config)
            return
        }

        let modes: [SearchMode] = mode == "all" ? SearchMode.allCases : [try parseMode(mode)]
        var reports: [EvalReport] = []
        for m in modes {
            if m != .lexical, engineOptions.noModel { continue }
            // Warm the query-vector cache so latency reflects ranking + cached query embedding consistently.
            reports.append(await Evaluator.run(engine: engine, queries: queries, mode: m))
        }
        printSummary(reports)
        for r in reports { printBreakdown(r); printFailures(r, limit: maxFailures) }
    }

    private func parseMode(_ s: String) throws -> SearchMode {
        guard let m = SearchMode(rawValue: s) else { throw ValidationError("mode must be lexical, semantic, hybrid or all") }
        return m
    }

    private func printSummary(_ reports: [EvalReport]) {
        print("\n| mode | n | MRR@10 | success@1 | success@5 | success@10 | p50 | p95 |")
        print("|---|---|---|---|---|---|---|---|")
        for r in reports {
            let m = r.overall
            print("| \(r.mode.rawValue) | \(m.count) | \(f3(m.mrr10)) | \(pct(m.success1)) | \(pct(m.success5)) | \(pct(m.success10)) | \(ms(r.latencyP50)) | \(ms(r.latencyP95)) |")
        }
    }

    private func printBreakdown(_ r: EvalReport) {
        print("\n[\(r.mode.rawValue)] by language")
        for (k, m) in r.byLang { print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) n=\(m.count)  MRR \(f3(m.mrr10))  s@1 \(pct(m.success1))  s@5 \(pct(m.success5))") }
        print("[\(r.mode.rawValue)] by type")
        for (k, m) in r.byType { print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) n=\(m.count)  MRR \(f3(m.mrr10))  s@1 \(pct(m.success1))  s@5 \(pct(m.success5))") }
    }

    private func printFailures(_ r: EvalReport, limit: Int) {
        let failures = r.failures
        guard !failures.isEmpty else { return }
        print("[\(r.mode.rawValue)] not at rank 1 (\(failures.count)):")
        for o in failures.prefix(limit) {
            let got = o.top.prefix(3).map { "\($0.item.title)" }.joined(separator: " | ")
            print("  \(o.rank.map { "#\($0)" } ?? "miss") \(o.query.q) [\(o.query.lang)/\(o.query.type)] → got: \(got)")
        }
    }

    /// Coordinate descent over the main fusion knobs; objective = MRR@10 (+ success@1 as tie-break)
    /// on the odd-numbered queries. Reports the even-numbered (held-out) queries before/after.
    private func runTuning(engine: SearchEngine, queries: [EvalQuery], base: RankingConfig) async throws {
        let tuneSet = queries.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let holdout = queries.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        func score(_ config: RankingConfig, _ set: [EvalQuery]) async -> EvalMetrics {
            await engine.setConfig(config)

            return await Evaluator.run(engine: engine, queries: set, mode: .hybrid).overall
        }
        func objective(_ m: EvalMetrics) -> Double { m.mrr10 + 0.001 * m.success1 }

        var best = base
        var bestScore = objective(await score(best, tuneSet))
        let before = await score(base, holdout)
        typealias Knob = (name: String, values: [Double], set: (inout RankingConfig, Double) -> Void)
        let knobs: [Knob] = [
            ("minSemanticCosine", [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5], { $0.minSemanticCosine = $1 }),
            ("lexicalScoreWeight", [0, 0.005, 0.01, 0.02, 0.03, 0.05], { $0.lexicalScoreWeight = $1 }),
            ("semanticRRFWeight", [0.5, 0.75, 1, 1.25, 1.5, 2], { $0.semanticRRFWeight = $1 }),
            ("cosineWeight", [0, 0.01, 0.02, 0.05, 0.1], { $0.cosineWeight = $1 }),
            ("cosineFloor", [0.2, 0.3, 0.4], { $0.cosineFloor = $1 }),
            ("intentWeight", [0, 0.003, 0.006, 0.01, 0.02], { $0.intentWeight = $1 }),
        ]
        for round in 1...2 {
            for knob in knobs {
                for v in knob.values {
                    var c = best
                    knob.set(&c, v)
                    let s = objective(await score(c, tuneSet))
                    if s > bestScore + 1e-9 { bestScore = s; best = c }
                }
            }
            print("round \(round): tune objective \(f3(bestScore))")
        }
        let after = await score(best, holdout)
        let allAfter = await score(best, queries)
        await engine.setConfig(base)
        let allBefore = await score(base, queries)
        print("""
            best: minSemanticCosine=\(best.minSemanticCosine) lexicalScoreWeight=\(best.lexicalScoreWeight) \
            semanticRRFWeight=\(best.semanticRRFWeight) cosineWeight=\(best.cosineWeight) cosineFloor=\(best.cosineFloor) \
            intentWeight=\(best.intentWeight)
            held-out (even lines, n=\(holdout.count)): MRR \(f3(before.mrr10)) → \(f3(after.mrr10)), s@1 \(pct(before.success1)) → \(pct(after.success1))
            all queries (n=\(queries.count)): MRR \(f3(allBefore.mrr10)) → \(f3(allAfter.mrr10)), s@1 \(pct(allBefore.success1)) → \(pct(allAfter.success1))
            """)
    }
}

extension SearchMode: ExpressibleByArgument {}

// MARK: Formatting helpers

private func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

private func seconds(_ t: TimeInterval) -> String { String(format: "%.2f s", t) }
private func ms(_ t: TimeInterval) -> String { String(format: "%.1f ms", t * 1000) }
private func kb(_ bytes: Int) -> String { bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(bytes / 1024) KB" }
private func f3(_ x: Double) -> String { String(format: "%.3f", x) }
private func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

private func badge(_ kind: ItemKind) -> String {
    switch kind {
    case .application: "앱"
    case .systemSetting: "설정"
    case .command: "명령"
    case .shortcut: "단축어"
    case .file: "파일"
    }
}

private func describe(_ action: ItemAction) -> String {
    switch action {
    case .openApplication(let path): "open \(path)"
    case .openURL(let url): "open \(url)"
    case .runShortcut(let name): "shortcuts run \"\(name)\""
    case .builtinCommand(let id): "builtin \(id)"
    case .openFile(let path): "open \(path)"
    }
}
