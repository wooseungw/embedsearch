import Accelerate
import CryptoKit
import Foundation
import GRDB

/// Per-item usage for frecency. `frecency` is the exponentially decayed selection count as of `lastUsed`.
public struct UsageRecord: Sendable, Hashable {
    public let itemID: String
    public let count: Int
    public let frecency: Double
    public let lastUsed: Date
}

/// "For query Q the user opened item X" — Firefox-style adaptive history.
public struct QueryMemoryRecord: Sendable, Hashable {
    public let query: String
    public let itemID: String
    public let count: Int
    public let weight: Double
    public let lastUsed: Date
}

public struct ItemSyncSummary: Sendable, Equatable {
    public var inserted = 0
    public var updated = 0
    public var unchanged = 0
    public var deleted = 0
}

/// SQLite persistence (GRDB, WAL): items, embedding cache, usage/frecency, query memory, query
/// vectors.
///
/// Storage is kept small: vectors as float16 (half of float32; on the eval set every metric and
/// every top-1 result stayed the same), 16 KB pages (a 3 KB vector BLOB filled a 4 KB page alone,
/// wasting a quarter of it), zlib-compressed item JSON, content hashes as 32-byte BLOBs, model keys
/// as small integers, a WAL truncated to 1 MB, and incremental auto-vacuum so pruned vectors return
/// their pages.
public final class IndexStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/EmbedSearch/index.sqlite")
    }

    /// nil for an in-memory store.
    public let url: URL?
    private let db: any DatabaseWriter

    static let pageSize = 16_384

    /// Opens (creating directories and migrating as needed) a WAL database at `url`.
    public init(url: URL = IndexStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 {
            try? Self.upgradeFile(at: url)
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            guard !db.configuration.readonly else { return }
            // page_size and auto_vacuum only take effect while the file is new (GRDB switches to
            // WAL after this); `upgradeFile` converts older files.
            try db.execute(sql: """
                PRAGMA page_size = \(Self.pageSize);
                PRAGMA auto_vacuum = INCREMENTAL;
                PRAGMA journal_size_limit = 1048576;
                PRAGMA wal_autocheckpoint = 64;
                """)
        }
        self.db = try DatabasePool(path: url.path, configuration: config)
        self.url = url
        try Self.migrator.migrate(db)
        try? reclaimSpace()  // pages a migration freed
    }

    /// One-time rewrite of a database created with the default page size: migrate the schema, then
    /// VACUUM into 16 KB pages with incremental auto-vacuum. VACUUM cannot change the page size in
    /// WAL mode, and leaving WAL needs exclusive access, so while another process has the database
    /// open this does nothing and is retried at the next open.
    private static func upgradeFile(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        let current = try queue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_size"), try Int.fetchOne(db, sql: "PRAGMA auto_vacuum"))
        }
        guard current.0 != pageSize || current.1 != 2 else { return }
        try migrator.migrate(queue)
        try queue.writeWithoutTransaction { db in
            guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else { return }
            try db.execute(sql: "PRAGMA page_size = \(pageSize); PRAGMA auto_vacuum = INCREMENTAL; VACUUM")
        }
    }

    private init(inMemory db: DatabaseQueue) throws {
        self.db = db
        self.url = nil
        try Self.migrator.migrate(db)
    }

    /// Ephemeral store for tests and evaluation runs.
    public static func inMemory() throws -> IndexStore {
        try IndexStore(inMemory: DatabaseQueue())
    }

    /// The first schema (still the base of every migration chain; tests build legacy files from it).
    static let schemaV1 = """
                CREATE TABLE item (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    json TEXT NOT NULL,
                    contentHash TEXT NOT NULL,
                    updatedAt DOUBLE NOT NULL
                );
                CREATE TABLE embedding (
                    contentHash TEXT NOT NULL,
                    modelKey TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    PRIMARY KEY (contentHash, modelKey)
                );
                CREATE TABLE usage (
                    itemId TEXT PRIMARY KEY NOT NULL,
                    count INTEGER NOT NULL,
                    frecency DOUBLE NOT NULL,
                    lastUsed DOUBLE NOT NULL
                );
                CREATE TABLE queryMemory (
                    query TEXT NOT NULL,
                    itemId TEXT NOT NULL,
                    count INTEGER NOT NULL,
                    weight DOUBLE NOT NULL,
                    lastUsed DOUBLE NOT NULL,
                    PRIMARY KEY (query, itemId)
                );
                CREATE INDEX queryMemory_itemId ON queryMemory(itemId);
                """

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in try db.execute(sql: schemaV1) }
        // Compact storage: compressed item JSON without the unread kind/hash columns, hashes as
        // BLOBs and model keys as integers in the embedding cache.
        m.registerMigration("v2-compact") { db in
            try db.execute(sql: """
                CREATE TABLE model (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE);
                CREATE TABLE item2 (id TEXT PRIMARY KEY NOT NULL, json BLOB NOT NULL, updatedAt DOUBLE NOT NULL) WITHOUT ROWID;
                CREATE TABLE embedding2 (
                    modelId INTEGER NOT NULL,
                    contentHash NOT NULL,
                    vector BLOB NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    PRIMARY KEY (modelId, contentHash)
                );
                INSERT INTO model (key) SELECT DISTINCT modelKey FROM embedding;
                """)
            let insertItem = try db.makeStatement(sql: "INSERT INTO item2 (id, json, updatedAt) VALUES (?, ?, ?)")
            let items = try Row.fetchCursor(db, sql: "SELECT id, json, updatedAt FROM item")
            while let row = try items.next() {
                let json: String = row[1]
                try insertItem.execute(arguments: [row[0], try compress(Data(json.utf8)), row[2]])
            }
            let insertVector = try db.makeStatement(sql: """
                INSERT INTO embedding2 (modelId, contentHash, vector, createdAt)
                SELECT id, ?, ?, ? FROM model WHERE key = ?
                """)
            let vectors = try Row.fetchCursor(db, sql: "SELECT contentHash, modelKey, vector, createdAt FROM embedding")
            while let row = try vectors.next() {
                let hash: String = row[0]
                try insertVector.execute(arguments: [hashValue(hash), row[2], row[3], row[1]])
            }
            try db.execute(sql: """
                DROP TABLE item;
                DROP TABLE embedding;
                ALTER TABLE item2 RENAME TO item;
                ALTER TABLE embedding2 RENAME TO embedding;
                """)
        }
        // Vectors stored as float16.
        m.registerMigration("v3-float16") { db in
            let update = try db.makeStatement(sql: "UPDATE embedding SET vector = ? WHERE rowid = ?")
            let rows = try Row.fetchAll(db, sql: "SELECT rowid, vector FROM embedding")
            for row in rows {
                let float32: Data = row[1]
                try update.execute(arguments: [float16Data(floats(from: float32)), row[0]])
            }
        }
        // File content: several float16 vectors per file version (keyed by the file item's content
        // hash), and which versions are done so empty or unreadable files are not retried.
        m.registerMigration("v4-files") { db in
            try db.execute(sql: """
                CREATE TABLE fileChunk (
                    modelId INTEGER NOT NULL,
                    fileHash NOT NULL,
                    seq INTEGER NOT NULL,
                    kind INTEGER NOT NULL,
                    hub REAL NOT NULL,
                    vector BLOB NOT NULL,
                    PRIMARY KEY (modelId, fileHash, seq)
                ) WITHOUT ROWID;
                CREATE TABLE fileIndexed (
                    modelId INTEGER NOT NULL,
                    fileHash NOT NULL,
                    chunks INTEGER NOT NULL,
                    partial INTEGER NOT NULL,
                    error TEXT,
                    indexedAt DOUBLE NOT NULL,
                    PRIMARY KEY (modelId, fileHash)
                ) WITHOUT ROWID;
                """)
        }
        // The page (1-based) a PDF chunk starts on.
        m.registerMigration("v5-chunk-page") { db in
            try db.execute(sql: "ALTER TABLE fileChunk ADD COLUMN page INTEGER")
        }
        // Keyword search over file text, by file version (text does not depend on the model):
        // each text chunk's tokens (`ContentTokenizer`) in a contentless FTS5 table — the index
        // only, no copy of the text (~/Downloads: ~2.5 MB; keeping the text too: 8.8 MB; a trigram
        // index: 15 MB) — and which chunk each FTS row is. `fileText` has no index on fileHash:
        // only writes look rows up by hash, a scan of some thousand small rows, and an index
        // would nearly double the table. Records from before this kept no text (`hasText` 0):
        // their files are read again once (`SearchEngine.readMissingTexts`) — unless they had no
        // text to embed (no text, OCR or card chunk: images without text, scans), which a second
        // read would not find either; text whose embedding failed is read again.
        m.registerMigration("v6-file-text") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE fileTextIndex USING fts5(tokens, content='', contentless_delete=1, tokenize='ascii');
                CREATE TABLE fileText (id INTEGER PRIMARY KEY, fileHash NOT NULL, seq INTEGER NOT NULL, page INTEGER);
                ALTER TABLE fileIndexed ADD COLUMN hasText INTEGER NOT NULL DEFAULT 0;
                UPDATE fileIndexed SET hasText = 1
                WHERE (error IS NULL OR error <> 'text could not be embedded')
                  AND NOT EXISTS (SELECT 1 FROM fileChunk c WHERE c.modelId = fileIndexed.modelId
                                  AND c.fileHash = fileIndexed.fileHash AND c.kind IN (0, 1, 4));
                """)
        }
        // Query vectors, so a query searched before (even in an earlier run) needs no model load:
        // float16 like the other vectors, keyed by the SHA-256 of the exact query text the model
        // embedded — no query text is stored, and rows have a fixed size (~1.6 MB at the cap) —
        // and capped to the most recently used of each model (`queryVectorLimit`).
        m.registerMigration("v7-query-vector") { db in
            try db.execute(sql: """
                CREATE TABLE queryVector (
                    modelId INTEGER NOT NULL,
                    queryHash BLOB NOT NULL,
                    vector BLOB NOT NULL,
                    lastUsed DOUBLE NOT NULL,
                    PRIMARY KEY (modelId, queryHash)
                ) WITHOUT ROWID;
                """)
        }
        return m
    }

    // MARK: Encodings

    /// A content hash as stored: the lowercase hex SHA-256 that `contentHash` produces becomes its
    /// 32 bytes (a BLOB); any other string is stored as itself (TEXT), which never equals a BLOB.
    static func hashValue(_ hash: String) -> DatabaseValue {
        var hash = hash
        let digest: [UInt8]? = hash.withUTF8 { hex in
            guard hex.count == 64 else { return nil }
            var out = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 {
                guard let hi = hexNibble(hex[2 * i]), let lo = hexNibble(hex[2 * i + 1]) else { return nil }
                out[i] = hi << 4 | lo
            }
            return out
        }
        return digest.map { Data($0).databaseValue } ?? hash.databaseValue
    }

    /// Inverse of `hashValue`.
    static func hashString(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .blob(let data): hex(data)
        case .string(let string): string
        default: nil
        }
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    private static func hex(_ bytes: some Collection<UInt8>) -> String {
        String(unsafeUninitializedCapacity: 2 * bytes.count) { out in
            var i = 0
            for b in bytes {
                out[i] = hexDigits[Int(b >> 4)]
                out[i + 1] = hexDigits[Int(b & 0x0F)]
                i += 2
            }
            return i
        }
    }

    static func compress(_ json: Data) throws -> Data {
        try (json as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ blob: Data) throws -> Data {
        try (blob as NSData).decompressed(using: .zlib) as Data
    }

    /// The id of `modelKey` in the `model` table, created on demand.
    private static func modelID(_ db: Database, _ modelKey: String, create: Bool) throws -> Int64? {
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM model WHERE key = ?", arguments: [modelKey]) { return id }
        guard create else { return nil }
        try db.execute(sql: "INSERT INTO model (key) VALUES (?)", arguments: [modelKey])
        return db.lastInsertedRowID
    }

    // MARK: Items

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func allItems() throws -> [SearchItem] {
        let rows = try db.read { db in try Data.fetchAll(db, sql: "SELECT json FROM item ORDER BY id") }
        // Decompressed and decoded on all cores, outside the read transaction; rows that do not
        // decode are skipped.
        return Parallel.chunked(rows.count) { range in
            let decoder = JSONDecoder()
            return range.compactMap { try? decoder.decode(SearchItem.self, from: Self.decompress(rows[$0])) }
        }
    }

    /// Makes the item table equal to `items`: inserts new, rewrites changed, deletes vanished rows.
    @discardableResult
    public func syncItems(_ items: [SearchItem], now: Date = Date()) throws -> ItemSyncSummary {
        // Encoded and compressed on all cores; on a failure, encoding that item again throws its error.
        let attempts: [(json: Data, blob: Data)?] = Parallel.chunked(items.count) { range in
            let encoder = JSONEncoder()
            encoder.outputFormatting = Self.encoder.outputFormatting
            return range.map { i in
                guard let json = try? encoder.encode(items[i]), let blob = try? Self.compress(json) else { return nil }
                return (json, blob)
            }
        }
        let encoded = try zip(items, attempts).map { item, attempt in
            if let attempt { return attempt }
            let json = try Self.encoder.encode(item)
            return (json, try Self.compress(json))
        }
        return try db.write { db in
            var summary = ItemSyncSummary()
            var existing: [String: Data] = [:]
            existing.reserveCapacity(items.count)
            let rows = try Row.fetchCursor(db, sql: "SELECT id, json FROM item")
            while let row = try rows.next() { existing[row[0]] = row[1] }
            var keep = Set<String>()
            keep.reserveCapacity(items.count)
            let upsert = try db.cachedStatement(sql: """
                INSERT INTO item (id, json, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET json = excluded.json, updatedAt = excluded.updatedAt
                """)
            for (item, (json, blob)) in zip(items, encoded) {
                keep.insert(item.id)
                if let old = existing[item.id] {
                    // Same compressor, same JSON → same bytes; otherwise compare the JSON itself.
                    if old == blob || (try? Self.decompress(old)) == json { summary.unchanged += 1; continue }
                    summary.updated += 1
                } else {
                    summary.inserted += 1
                }
                try upsert.execute(arguments: [item.id, blob, now.timeIntervalSince1970])
            }
            let delete = try db.cachedStatement(sql: "DELETE FROM item WHERE id = ?")
            for id in existing.keys where !keep.contains(id) {
                try delete.execute(arguments: [id])
                summary.deleted += 1
            }
            return summary
        }
    }

    // MARK: Embedding cache

    /// SHA-256 (hex) of everything that feeds the embedding.
    public static func contentHash(_ item: SearchItem) -> String {
        var content = item.embeddingContent
        let digest = content.withUTF8 { SHA256.hash(data: UnsafeRawBufferPointer($0)) }
        return digest.withUnsafeBytes { hex($0) }
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    public func cachedEmbeddings(hashes: some Collection<String>, modelKey: String) throws -> [String: [Float]] {
        guard !hashes.isEmpty else { return [:] }
        let wanted = Set(hashes)
        return try db.read { db in
            var out: [String: [Float]] = [:]
            guard let model = try Self.modelID(db, modelKey, create: false) else { return out }
            let rows = try Row.fetchCursor(db, sql: "SELECT contentHash, vector FROM embedding WHERE modelId = ?",
                                           arguments: [model])
            while let row = try rows.next() {
                guard let hash = Self.hashString(row[0]), wanted.contains(hash) else { continue }
                let data: Data = row[1]
                out[hash] = Self.floats(float16: data)
            }
            return out
        }
    }

    /// The cached vectors of `hashes` that hold `dimensions` floats, packed row-major in `hashes`
    /// order straight from the BLOBs (no per-vector arrays): row r belongs to `hashes[rows[r]]`.
    public func embeddingMatrix(hashes: [String], modelKey: String, dimensions: Int) throws -> (rows: [Int32], matrix: [Float]) {
        guard !hashes.isEmpty, dimensions > 0 else { return ([], []) }
        var positions: [String: [Int32]] = [:]
        positions.reserveCapacity(hashes.count)
        for (i, h) in hashes.enumerated() { positions[h, default: []].append(Int32(i)) }
        // `floats(float16:)` keeps whole values, so a BLOB holds `dimensions` of them when its length
        // is byteCount or byteCount + 1.
        let byteCount = dimensions * MemoryLayout<UInt16>.size
        return try db.read { db in
            guard let model = try Self.modelID(db, modelKey, create: false) else { return ([], []) }
            let lengths: StatementArguments = [model, byteCount, byteCount + 1]
            // Pass 1 (no BLOB reads): which positions have a vector, hence each one's row.
            var rowOfPosition = [Int32](repeating: -1, count: hashes.count)
            let present = try DatabaseValue.fetchCursor(
                db, sql: "SELECT contentHash FROM embedding WHERE modelId = ? AND length(vector) BETWEEN ? AND ?",
                arguments: lengths)
            while let value = try present.next() {
                guard let h = Self.hashString(value) else { continue }
                for p in positions[h] ?? [] { rowOfPosition[Int(p)] = 0 }
            }
            var rows: [Int32] = []
            for p in rowOfPosition.indices where rowOfPosition[p] == 0 {
                rowOfPosition[p] = Int32(rows.count)
                rows.append(Int32(p))
            }
            // Pass 2: widen each BLOB straight into its rows.
            var matrix = [Float](repeating: 0, count: rows.count * dimensions)
            guard !rows.isEmpty else { return ([], []) }
            try matrix.withUnsafeMutableBufferPointer { out in
                let blobs = try Row.fetchCursor(
                    db, sql: "SELECT contentHash, vector FROM embedding WHERE modelId = ? AND length(vector) BETWEEN ? AND ?",
                    arguments: lengths)
                while let row = try blobs.next() {
                    guard let h = Self.hashString(row[0]), let ps = positions[h] else { continue }
                    try row.withUnsafeData(atIndex: 1) { data in
                        guard let data, data.count >= byteCount else { return }
                        data.withUnsafeBytes { half in
                            for p in ps {
                                let r = Int(rowOfPosition[Int(p)])
                                Self.widen(half.baseAddress!, into: out.baseAddress! + r * dimensions, count: dimensions)
                            }
                        }
                    }
                }
            }
            return (rows, matrix)
        }
    }

    public func saveEmbeddings(_ vectors: [String: [Float]], modelKey: String, now: Date = Date()) throws {
        guard !vectors.isEmpty else { return }
        try db.write { db in
            let model = try Self.modelID(db, modelKey, create: true)!
            let insert = try db.cachedStatement(
                sql: "INSERT OR REPLACE INTO embedding (modelId, contentHash, vector, createdAt) VALUES (?, ?, ?, ?)")
            for (hash, v) in vectors {
                try insert.execute(arguments: [model, Self.hashValue(hash), Self.float16Data(v), now.timeIntervalSince1970])
            }
        }
    }

    /// Deletes cached vectors of `modelKey` whose content no longer belongs to any item.
    @discardableResult
    public func pruneEmbeddings(keeping hashes: Set<String>, modelKey: String) throws -> Int {
        let removed = try db.write { db in
            guard let model = try Self.modelID(db, modelKey, create: false) else { return 0 }
            let stored = try DatabaseValue.fetchAll(db, sql: "SELECT contentHash FROM embedding WHERE modelId = ?", arguments: [model])
            let delete = try db.cachedStatement(sql: "DELETE FROM embedding WHERE modelId = ? AND contentHash = ?")
            var removed = 0
            for value in stored where !(Self.hashString(value).map(hashes.contains) ?? false) {
                try delete.execute(arguments: [model, value])
                removed += 1
            }
            return removed
        }
        if removed > 0 { try reclaimSpace() }
        return removed
    }

    /// Deletes every cached vector of models other than `modelKey` (e.g. after switching model or
    /// dimensions), query vectors included: they would otherwise stay in the file forever. File
    /// text no record refers to any more goes with them.
    @discardableResult
    public func pruneOtherModels(keeping modelKey: String) throws -> Int {
        let removed = try db.write { db in
            let withText = try Self.hashesWithText(db)
            var removed = 0
            for table in ["embedding", "fileChunk", "fileIndexed", "queryVector"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE modelId NOT IN (SELECT id FROM model WHERE key = ?)",
                               arguments: [modelKey])
                removed += db.changesCount
            }
            try db.execute(sql: "DELETE FROM model WHERE key <> ?", arguments: [modelKey])
            if removed > 0 {
                let orphaned = withText.subtracting(try DatabaseValue.fetchAll(db, sql: "SELECT fileHash FROM fileIndexed"))
                if !orphaned.isEmpty { try Self.deleteTexts(db) { orphaned.contains($0) } }
            }
            return removed
        }
        if removed > 0 { try reclaimSpace() }
        return removed
    }

    /// Returns free pages to the file system (incremental auto-vacuum); a no-op on files without it.
    private func reclaimSpace() throws {
        try db.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA incremental_vacuum") }
    }

    public func embeddingCount(modelKey: String? = nil) throws -> Int {
        try db.read { db in
            if let modelKey {
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM embedding WHERE modelId = (SELECT id FROM model WHERE key = ?)
                    """, arguments: [modelKey]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding") ?? 0
        }
    }

    // MARK: Query vectors

    /// Query vectors kept per model: a row is ≈ 1.6 KB (a 768-d float16 vector and a 32-byte
    /// key), so ~1.6 MB at most.
    public static let queryVectorLimit = 1_000

    /// SHA-256 of the query's UTF-8 bytes: the key of its stored vector.
    private static func queryHash(_ query: String) -> Data {
        Data(SHA256.hash(data: Data(query.utf8)))
    }

    /// The stored vector of `query` (the exact text the model embedded) under `modelKey`, or nil.
    /// Reading it marks it used, so pruning keeps the queries in use.
    public func queryVector(_ query: String, modelKey: String, now: Date = Date()) throws -> [Float]? {
        let hash = Self.queryHash(query)
        // Looked up in a read: a miss must not wait for (or fail on) the write lock.
        let found: (model: Int64, vector: Data)? = try db.read { db in
            guard let model = try Self.modelID(db, modelKey, create: false),
                  let vector = try Data.fetchOne(db, sql: "SELECT vector FROM queryVector WHERE modelId = ? AND queryHash = ?",
                                                 arguments: [model, hash])
            else { return nil }
            return (model, vector)
        }
        guard let found else { return nil }
        // A failed update (e.g. another process holds the write lock) only costs the vector its
        // recency; the hit stays a hit.
        try? db.write { db in
            try db.execute(sql: "UPDATE queryVector SET lastUsed = ? WHERE modelId = ? AND queryHash = ?",
                           arguments: [now.timeIntervalSince1970, found.model, hash])
        }
        return Self.floats(float16: found.vector)
    }

    /// Stores the vector the model gave `query` under `modelKey`, then drops that model's least
    /// recently used ones beyond `limit`. The one just saved always stays (even when its `now` is
    /// older than the others', e.g. after the clock went back), with the `limit` − 1 most recently
    /// used others.
    public func saveQueryVector(_ vector: [Float], query: String, modelKey: String, now: Date = Date(),
                                limit: Int = IndexStore.queryVectorLimit) throws {
        let hash = Self.queryHash(query)
        try db.write { db in
            let model = try Self.modelID(db, modelKey, create: true)!
            try db.execute(sql: "INSERT OR REPLACE INTO queryVector (modelId, queryHash, vector, lastUsed) VALUES (?, ?, ?, ?)",
                           arguments: [model, hash, Self.float16Data(vector), now.timeIntervalSince1970])
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queryVector WHERE modelId = ?", arguments: [model]) ?? 0
            guard count > limit else { return }
            try db.execute(sql: """
                DELETE FROM queryVector WHERE modelId = ? AND queryHash <> ? AND queryHash IN (
                    SELECT queryHash FROM queryVector WHERE modelId = ? AND queryHash <> ?
                    ORDER BY lastUsed DESC LIMIT -1 OFFSET ?)
                """, arguments: [model, hash, model, hash, max(0, limit - 1)])
        }
    }

    // MARK: File content

    /// The indexed file versions (by file item content hash) of `modelKey`.
    public func fileIndexRecords(modelKey: String) throws -> [String: FileIndexRecord] {
        try db.read { db in
            var out: [String: FileIndexRecord] = [:]
            guard let model = try Self.modelID(db, modelKey, create: false) else { return out }
            let rows = try Row.fetchCursor(db, sql: "SELECT fileHash, chunks, partial, error FROM fileIndexed WHERE modelId = ?",
                                           arguments: [model])
            while let row = try rows.next() {
                guard let hash = Self.hashString(row[0]) else { continue }
                out[hash] = FileIndexRecord(chunks: row[1], partial: row[2], error: row[3])
            }
            return out
        }
    }

    /// Calls `body(hash, kind, hub, page, float16 bytes)` for every stored chunk of `hashes` that
    /// holds `dimensions` values, in (hash, seq) order.
    public func forEachFileChunk(hashes: Set<String>, modelKey: String, dimensions: Int,
                                 _ body: (String, ChunkKind, Float, Int?, UnsafeRawBufferPointer) -> Void) throws {
        guard !hashes.isEmpty else { return }
        let byteCount = dimensions * MemoryLayout<UInt16>.size
        try db.read { db in
            guard let model = try Self.modelID(db, modelKey, create: false) else { return }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT fileHash, kind, hub, vector, page FROM fileChunk WHERE modelId = ? AND length(vector) BETWEEN ? AND ?
                """, arguments: [model, byteCount, byteCount + 1])
            while let row = try rows.next() {
                guard let hash = Self.hashString(row[0]), hashes.contains(hash) else { continue }
                let kind = ChunkKind(rawValue: UInt8(clamping: row[1] as Int)) ?? .text
                let hub: Double = row[2]
                let page: Int? = row[4]
                try row.withUnsafeData(atIndex: 3) { data in
                    data?.withUnsafeBytes { body(hash, kind, Float(hub), page, $0) }
                }
            }
        }
    }

    /// Stores each file version's chunks (replacing earlier ones) and marks it indexed. `texts`:
    /// the text pieces read from each version, by hash, kept for keyword search whether or not
    /// they could be embedded (keyword search needs no model); a version without an entry keeps
    /// no text.
    public func saveFileChunks(_ files: [(hash: String, record: FileIndexRecord, chunks: [FileChunk])],
                               texts: [String: [FileContent.Text]] = [:], modelKey: String, now: Date = Date()) throws {
        guard !files.isEmpty else { return }
        // Tokenized before the write transaction, which would otherwise hold the write lock meanwhile.
        let rows = files.map { Self.tokenRows(texts[$0.hash] ?? []) }
        try db.write { db in
            let model = try Self.modelID(db, modelKey, create: true)!
            let clear = try db.cachedStatement(sql: "DELETE FROM fileChunk WHERE modelId = ? AND fileHash = ?")
            let insert = try db.cachedStatement(sql: """
                INSERT INTO fileChunk (modelId, fileHash, seq, kind, hub, vector, page) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            let mark = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO fileIndexed (modelId, fileHash, chunks, partial, error, indexedAt, hasText)
                VALUES (?, ?, ?, ?, ?, ?, 1)
                """)
            let hashes = files.map { Self.hashValue($0.hash) }
            try Self.clearTexts(db, hashes)
            for (file, hash) in zip(files, hashes) {
                try clear.execute(arguments: [model, hash])
                for (seq, chunk) in file.chunks.enumerated() {
                    try insert.execute(arguments: [model, hash, seq, Int(chunk.kind.rawValue), Double(chunk.hub),
                                                   Self.float16Data(chunk.vector), chunk.page])
                }
                try mark.execute(arguments: [model, hash, file.record.chunks, file.record.partial, file.record.error,
                                             now.timeIntervalSince1970])
            }
            try Self.addTexts(db, hashes, rows)
        }
    }

    /// File versions of `modelKey` indexed before their text was kept for keyword search.
    public func fileHashesWithoutText(modelKey: String) throws -> Set<String> {
        try db.read { db in
            guard let model = try Self.modelID(db, modelKey, create: false) else { return [] }
            let values = try DatabaseValue.fetchAll(db, sql: "SELECT fileHash FROM fileIndexed WHERE modelId = ? AND hasText = 0",
                                                    arguments: [model])
            return Set(values.compactMap(Self.hashString))
        }
    }

    /// Stores the text of already indexed file versions (replacing earlier text) and marks their
    /// records, of every model, as having it. Returns how many versions it stored: one without a
    /// record (pruned meanwhile) is skipped, so no text outlives its records.
    @discardableResult
    public func saveFileTexts(_ files: [(hash: String, texts: [FileContent.Text])]) throws -> Int {
        guard !files.isEmpty else { return 0 }
        let rows = files.map { Self.tokenRows($0.texts) }
        return try db.write { db in
            let hashes = files.map { Self.hashValue($0.hash) }
            try Self.clearTexts(db, hashes)
            return try Self.addTexts(db, hashes, rows)
        }
    }

    /// (seq, page, tokens joined by spaces) of the texts that have any tokens.
    private static func tokenRows(_ texts: [FileContent.Text]) -> [(seq: Int, page: Int?, tokens: String)] {
        texts.enumerated().compactMap { seq, text in
            let tokens = ContentTokenizer.tokens(text.text)
            return tokens.isEmpty ? nil : (seq, text.page, tokens.joined(separator: " "))
        }
    }

    /// Versions some record marks as having their text stored. Text rows exist only for these, so
    /// a version outside this set needs no scan of `fileText`.
    private static func hashesWithText(_ db: Database) throws -> Set<DatabaseValue> {
        Set(try DatabaseValue.fetchAll(db, sql: "SELECT DISTINCT fileHash FROM fileIndexed WHERE hasText = 1"))
    }

    /// Deletes the stored text of `hashes`, if any.
    private static func clearTexts(_ db: Database, _ hashes: [DatabaseValue]) throws {
        let stored = Set(hashes).intersection(try hashesWithText(db))
        if !stored.isEmpty { try deleteTexts(db) { stored.contains($0) } }
    }

    /// Stores `rows` as the text of `hashes` and marks every record of each as having it; a
    /// version without a record gets none. Returns the versions stored.
    @discardableResult
    private static func addTexts(_ db: Database, _ hashes: [DatabaseValue],
                                 _ rows: [[(seq: Int, page: Int?, tokens: String)]]) throws -> Int {
        let mark = try db.cachedStatement(sql: "UPDATE fileIndexed SET hasText = 1 WHERE fileHash = ?")
        let insertRow = try db.cachedStatement(sql: "INSERT INTO fileText (fileHash, seq, page) VALUES (?, ?, ?)")
        // OR REPLACE: a reused id whose FTS row survived somehow replaces it instead of failing the save.
        let insertTokens = try db.cachedStatement(sql: "INSERT OR REPLACE INTO fileTextIndex (rowid, tokens) VALUES (?, ?)")
        var stored = 0
        for (hash, rows) in zip(hashes, rows) {
            try mark.execute(arguments: [hash])
            guard db.changesCount > 0 else { continue }
            for row in rows {
                try insertRow.execute(arguments: [hash, row.seq, row.page])
                try insertTokens.execute(arguments: [db.lastInsertedRowID, row.tokens])
            }
            stored += 1
        }
        return stored
    }

    /// Deletes the text rows of the file versions (stored hash values) for which `drop` is true,
    /// and marks their remaining records (other models) as without text, so they are read again
    /// if used. Returns how many versions lost their text.
    @discardableResult
    private static func deleteTexts(_ db: Database, where drop: (DatabaseValue) -> Bool) throws -> Int {
        var ids: [Int64] = []
        var dropped = Set<DatabaseValue>()
        let rows = try Row.fetchCursor(db, sql: "SELECT id, fileHash FROM fileText")
        while let row = try rows.next() {
            let hash: DatabaseValue = row[1]
            if drop(hash) {
                ids.append(row[0])
                dropped.insert(hash)
            }
        }
        let deleteTokens = try db.cachedStatement(sql: "DELETE FROM fileTextIndex WHERE rowid = ?")
        let deleteRow = try db.cachedStatement(sql: "DELETE FROM fileText WHERE id = ?")
        for id in ids {
            try deleteTokens.execute(arguments: [id])
            try deleteRow.execute(arguments: [id])
        }
        let unmark = try db.cachedStatement(sql: "UPDATE fileIndexed SET hasText = 0 WHERE fileHash = ?")
        for hash in dropped { try unmark.execute(arguments: [hash]) }
        return dropped.count
    }

    /// Deletes the chunks and records of `modelKey` whose file version is not in `hashes`, and the
    /// text of every version not in `hashes`.
    @discardableResult
    public func pruneFileIndex(keeping hashes: Set<String>, modelKey: String) throws -> Int {
        let keep = Set(hashes.map(Self.hashValue))
        let (removed, textsRemoved) = try db.write { db in
            let stale = try Self.hashesWithText(db).subtracting(keep)
            let texts = stale.isEmpty ? 0 : try Self.deleteTexts(db) { stale.contains($0) }
            guard let model = try Self.modelID(db, modelKey, create: false) else { return (0, texts) }
            let stored = try DatabaseValue.fetchAll(db, sql: "SELECT fileHash FROM fileIndexed WHERE modelId = ?", arguments: [model])
            var removed = 0
            for value in stored where !keep.contains(value) {
                try db.execute(sql: "DELETE FROM fileChunk WHERE modelId = ? AND fileHash = ?", arguments: [model, value])
                try db.execute(sql: "DELETE FROM fileIndexed WHERE modelId = ? AND fileHash = ?", arguments: [model, value])
                removed += 1
            }
            // Chunks without a record (an interrupted save cannot leave these, but be safe).
            try db.execute(sql: """
                DELETE FROM fileChunk WHERE modelId = ? AND fileHash NOT IN (SELECT fileHash FROM fileIndexed WHERE modelId = ?)
                """, arguments: [model, model])
            return (removed, texts)
        }
        if removed + textsRemoved > 0 { try reclaimSpace() }
        return removed
    }

    /// Bytes of stored file-chunk vectors (all models).
    public func fileChunkBytes() throws -> Int {
        try db.read { db in try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(vector)), 0) FROM fileChunk") ?? 0 }
    }

    /// Bytes the keyword index takes in the file: the FTS5 tables and the chunk map, in whole pages.
    public func fileTextBytes() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name = 'fileText' OR name LIKE 'fileTextIndex%'
                """) ?? 0
        }
    }

    /// A file version's best keyword match (see `keywordMatches`).
    public struct KeywordMatch: Sendable, Equatable {
        public let fileHash: String
        /// The FTS5 bm25 of its best chunk, sign flipped: higher is better.
        public let score: Double
        /// The IDF-weighted share of the query's words that occur in that chunk, 0…1.
        public let coverage: Double
        /// How few files have the words that chunk has: 1 for a word only one file has (see
        /// `keywordMatches`).
        public let rarity: Double
        /// The page that chunk starts on.
        public let page: Int?
    }

    /// File versions whose text has any of the query `words`, best first: the `chunks` best chunk
    /// rows by bm25, of which each version keeps its best. A word is its `ContentTokenizer` tokens
    /// matched as a phrase, so "캐스팅" needs 캐스 right before 스팅 ("다이캐스팅" has them,
    /// "포캐스트 테스팅" does not).
    ///
    /// Coverage = Σ idf of the words in that chunk / Σ idf of all words, with idf(w) =
    /// ln(1 + (N − df + 0.5) / (df + 0.5)) over the N stored chunks (BM25's, kept positive). A word
    /// no chunk has gets the highest idf, so a query whose distinctive words are missing
    /// ("카카오톡 알림": a document with "알림" but no "카카오톡") has low coverage however often
    /// its common words occur.
    ///
    /// Rarity = Σ over the words in that chunk of the same idf counted in files instead of chunks
    /// (F files with text, f of them with the word), divided by that of a word one file has
    /// (f = 1). Files, because a paper repeats its own terms: on ~/Downloads (274 files) "navsim"
    /// is in 7 chunks of 1 file (rarity 1.0) and "densepass" in 13 chunks of 2 (0.90), while
    /// "meeting" is in 5 chunks of 4 files (0.79) and "회의" in 15 chunks of 9 (0.65).
    ///
    /// One MATCH per word gives its chunk and file counts and which best chunks have it; that costs
    /// the rows of each word, a few thousand for common ones.
    public func keywordMatches(words: [[String]], chunks: Int) throws -> [KeywordMatch] {
        var seen = Set<String>()
        // At most 32 words: a long pasted query costs no more than this.
        let phrases = words.map { $0.filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(32)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        guard !phrases.isEmpty, chunks > 0 else { return [] }
        return try db.read { db in
            guard let counts = try Row.fetchOne(db, sql: "SELECT COUNT(*), COUNT(DISTINCT fileHash) FROM fileText") else { return [] }
            let n: Int = counts[0], files: Int = counts[1]
            guard n > 0 else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.rowid, m.rank, t.fileHash, t.page
                FROM (SELECT rowid, rank FROM fileTextIndex WHERE fileTextIndex MATCH ? ORDER BY rank LIMIT ?) m
                JOIN fileText t ON t.id = m.rowid ORDER BY m.rank, m.rowid
                """, arguments: [phrases.joined(separator: " OR "), chunks])
            var best: [(row: Int64, hash: DatabaseValue, score: Double, page: Int?)] = []
            var seenFiles = Set<DatabaseValue>()
            for row in rows {
                let hash: DatabaseValue = row[2]
                if seenFiles.insert(hash).inserted { best.append((row[0], hash, -(row[1] as Double), row[3])) }
            }
            var slot: [Int64: Int] = [:]
            for (i, b) in best.enumerated() { slot[b.row] = i }
            func idf(_ count: Int, of total: Int) -> Double {
                log(1 + (Double(max(0, total - count)) + 0.5) / (Double(count) + 0.5))
            }
            var present = [UInt32](repeating: 0, count: best.count)
            var chunkIDF: [Double] = [], fileIDF: [Double] = []
            for (w, phrase) in phrases.enumerated() {
                var df = 0
                var inFiles = Set<DatabaseValue>()
                let matches = try Row.fetchCursor(db, sql: """
                    SELECT f.rowid, t.fileHash FROM fileTextIndex f JOIN fileText t ON t.id = f.rowid WHERE fileTextIndex MATCH ?
                    """, arguments: [phrase])
                while let row = try matches.next() {
                    df += 1
                    inFiles.insert(row[1])
                    if let i = slot[row[0]] { present[i] |= 1 << w }
                }
                chunkIDF.append(idf(df, of: n))
                fileIDF.append(idf(inFiles.count, of: files))
            }
            let total = chunkIDF.reduce(0, +), unique = idf(1, of: files)
            return best.enumerated().compactMap { i, b in
                guard let hash = Self.hashString(b.hash) else { return nil }
                let has = phrases.indices.filter { present[i] & 1 << $0 != 0 }
                let covered = has.reduce(0.0) { $0 + chunkIDF[$1] }, rare = has.reduce(0.0) { $0 + fileIDF[$1] }
                return KeywordMatch(fileHash: hash, score: b.score, coverage: total > 0 ? covered / total : 0,
                                    rarity: unique > 0 ? rare / unique : 0, page: b.page)
            }
        }
    }

    /// The database file plus its WAL, in bytes (nil for an in-memory store).
    public func fileSize() -> Int? {
        guard let url else { return nil }
        return ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? Int) ?? 0
            return total + size
        }
    }

    // MARK: Vector encodings

    /// Float32 bytes (the first schema's vector format).
    static func data(from v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        let n = data.count / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: n) { buf, count in
            _ = data.copyBytes(to: buf)
            count = n
        }
    }

    /// IEEE half-precision bytes, rounded to nearest even (vImage: both architectures, unlike
    /// Swift's `Float16` on x86_64).
    static func float16Data(_ v: [Float]) -> Data {
        var out = Data(count: v.count * MemoryLayout<UInt16>.size)
        guard !v.isEmpty else { return out }
        v.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                           width: vImagePixelCount(v.count), rowBytes: v.count * 4)
                var destination = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(v.count),
                                                rowBytes: v.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    static func floats(float16 data: Data) -> [Float] {
        let n = data.count / MemoryLayout<UInt16>.size
        return [Float](unsafeUninitializedCapacity: n) { buf, count in
            if n > 0 { data.withUnsafeBytes { widen($0.baseAddress!, into: buf.baseAddress!, count: n) } }
            count = n
        }
    }

    static func widen(_ half: UnsafeRawPointer, into out: UnsafeMutablePointer<Float>, count: Int) {
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: half), height: 1,
                                   width: vImagePixelCount(count), rowBytes: count * 2)
        var destination = vImage_Buffer(data: out, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
    }

    /// `v` as it reads back from the store. Vectors are indexed in this form even when freshly
    /// embedded, so results do not depend on whether a vector came from the model or the cache.
    public static func storedPrecision(_ v: [Float]) -> [Float] {
        floats(float16: float16Data(v))
    }

    // MARK: Usage and query memory

    /// Records that the user opened `itemID` after typing `query`: bumps frecency (decayed with
    /// `halfLife`) and the query→item memory under the normalized query. Returns the rows as stored,
    /// so a caller can update its copy without re-reading the tables.
    @discardableResult
    public func recordSelection(itemID: String, query: String, at now: Date = Date(),
                                halfLife: TimeInterval) throws -> (usage: UsageRecord, memory: QueryMemoryRecord?) {
        let t = now.timeIntervalSince1970
        let normalized = TextNormalizer.normalize(query)
        return try db.write { db in
            let usage: UsageRecord
            if let row = try Row.fetchOne(db, sql: "SELECT count, frecency, lastUsed FROM usage WHERE itemId = ?", arguments: [itemID]) {
                let decayed = Frecency.decay(row["frecency"], elapsed: t - row["lastUsed"], halfLife: halfLife)
                try db.execute(sql: "UPDATE usage SET count = count + 1, frecency = ?, lastUsed = ? WHERE itemId = ?",
                               arguments: [decayed + 1, t, itemID])
                usage = UsageRecord(itemID: itemID, count: row["count"] + 1, frecency: decayed + 1,
                                    lastUsed: Date(timeIntervalSince1970: t))
            } else {
                try db.execute(sql: "INSERT INTO usage (itemId, count, frecency, lastUsed) VALUES (?, 1, 1, ?)", arguments: [itemID, t])
                usage = UsageRecord(itemID: itemID, count: 1, frecency: 1, lastUsed: Date(timeIntervalSince1970: t))
            }
            guard !normalized.isEmpty else { return (usage, nil) }
            let memory: QueryMemoryRecord
            if let row = try Row.fetchOne(db, sql: "SELECT count, weight, lastUsed FROM queryMemory WHERE query = ? AND itemId = ?",
                                          arguments: [normalized, itemID]) {
                let decayed = Frecency.decay(row["weight"], elapsed: t - row["lastUsed"], halfLife: halfLife)
                try db.execute(sql: "UPDATE queryMemory SET count = count + 1, weight = ?, lastUsed = ? WHERE query = ? AND itemId = ?",
                               arguments: [decayed + 1, t, normalized, itemID])
                memory = QueryMemoryRecord(query: normalized, itemID: itemID, count: row["count"] + 1, weight: decayed + 1,
                                           lastUsed: Date(timeIntervalSince1970: t))
            } else {
                try db.execute(sql: "INSERT INTO queryMemory (query, itemId, count, weight, lastUsed) VALUES (?, ?, 1, 1, ?)",
                               arguments: [normalized, itemID, t])
                memory = QueryMemoryRecord(query: normalized, itemID: itemID, count: 1, weight: 1,
                                           lastUsed: Date(timeIntervalSince1970: t))
            }
            return (usage, memory)
        }
    }

    public func usageRecords() throws -> [String: UsageRecord] {
        try db.read { db in
            var out: [String: UsageRecord] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT itemId, count, frecency, lastUsed FROM usage") {
                let r = UsageRecord(itemID: row["itemId"], count: row["count"], frecency: row["frecency"],
                                    lastUsed: Date(timeIntervalSince1970: row["lastUsed"]))
                out[r.itemID] = r
            }
            return out
        }
    }

    public func queryMemoryRecords() throws -> [QueryMemoryRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT query, itemId, count, weight, lastUsed FROM queryMemory").map {
                QueryMemoryRecord(query: $0["query"], itemID: $0["itemId"], count: $0["count"], weight: $0["weight"],
                                  lastUsed: Date(timeIntervalSince1970: $0["lastUsed"]))
            }
        }
    }

    /// Forgets all usage, query memory and remembered query vectors (items and embeddings stay).
    public func resetUsage() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM usage; DELETE FROM queryMemory; DELETE FROM queryVector;")
        }
    }
}

/// One indexed file version: how many chunks it has, whether images were skipped (no image
/// embedder at the time), and why it has none.
public struct FileIndexRecord: Sendable, Equatable {
    public var chunks: Int
    public var partial: Bool
    public var error: String?

    public init(chunks: Int, partial: Bool = false, error: String? = nil) {
        self.chunks = chunks
        self.partial = partial
        self.error = error
    }
}

/// One embedded piece of a file.
public struct FileChunk: Sendable {
    public var kind: ChunkKind
    /// Mean cosine to the generic probe queries (see `ChunkIndex`).
    public var hub: Float
    public var vector: [Float]
    /// The PDF page (1-based) the piece starts on.
    public var page: Int?

    public init(kind: ChunkKind, hub: Float, vector: [Float], page: Int? = nil) {
        self.kind = kind
        self.hub = hub
        self.vector = vector
        self.page = page
    }
}
