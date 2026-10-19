# EmbedSearch — Design (Phase 1–2)

Local, offline semantic launcher for macOS (Apple Silicon) using `google/embeddinggemma-2` on MLX.
Research basis: `docs/reports/EmbeddingGemma 맥 임베딩 검색 런처.md` (+ `docs/research_notes/`).

## Scope of this phase
1. **Correctness first**: Python sentence-transformers fp32 reference vectors vs MLX parity test (cosine ≥ 0.999), benchmark, and a Korean/English eval set.
2. **Launcher** for sources that need no special permissions: installed **apps**, **System Settings** panes/anchors, built-in **commands** and **Shortcuts**.
3. Later phases (not now): files, browser history, clipboard.

## UX requirements (from the user)
- Global hotkey **⌥Space** toggles the panel (detect registration failure → let the user pick another).
- **Notch style (default on notch displays)**: the panel is born from the MacBook notch — a black shape starting at the notch rect (built-in display here: notch 185×32 pt, centered at top, screen 1512×982) that springs open **wide left/right** and drops down, with the search field sitting **directly under the notch** and the Raycast-style results list below it. Collapses back into the notch on hide.
  On screens without a notch (`NSScreen.auxiliaryTopLeftArea == nil`): same black panel attached to the top-center edge of that screen. Optional setting: classic Raycast-style floating panel (centered, top at 18% of visible height).
- Raycast-like list: icon, title, subtitle, kind badge, selection highlight, footer with engine state and `↵ 열기`.
- Search behavior (both are required):
  - while typing (only when **not composing Hangul** — `hasMarkedText == false`): instant lexical results on each committed change, then hybrid semantic search after ~200 ms debounce (cancel previous task);
  - **Enter**: if the visible results are stale for the current text (semantic search not finished for exactly this text), run the full search immediately and do NOT open; otherwise open the selected result. If Enter commits IME composition, it only commits + searches.
- Keys: ↑/↓, ⌃N/⌃P, ↵ open, ⌘1–9 open Nth, Esc (clear text → close), ⌘, settings.

## Module layout (SwiftPM `Package.swift` + XcodeGen app)
| Target | Path | Owner track | Notes |
|---|---|---|---|
| `EmbedCore` | `Sources/EmbedCore` | shared (frozen contract) | `EmbeddingInput`, `EmbeddingModelInfo`, `TextEmbedder`, `EmbeddingPrompt`, `VectorMath`. No MLX. |
| `EmbedMLX` | `Sources/EmbedMLX` | **Embedding track** | `MLXTextEmbedder: TextEmbedder` via `MLXEmbedders` (mlx-swift-lm pinned @ 028a828). |
| `SearchCore` | `Sources/SearchCore` | **Search track** | `Models.swift` is the frozen contract (items, results, `SearchService`, `EngineState`). Sources, lexical, vector index, store (GRDB), `SearchEngine`. |
| `EmbedSearchCLI` | `Sources/EmbedSearchCLI` | Embedding track owns `EmbedCommands.swift`; Search track owns `SearchCommands.swift` | `embed`, `parity`, `bench` / `index`, `search`, `eval`. |
| App | `App/` + `project.yml` | **App track** | AppKit+SwiftUI, LSUIElement agent app, hotkey, notch panel, actions, settings. |
| Python reference | `tools/parity/` | Embedding track | uv project; writes `tools/parity/reference.json`. |
| Eval set | `eval/queries.jsonl` | Search track | |

**Frozen contracts**: `Sources/EmbedCore/Embedding.swift`, `Sources/EmbedCore/VectorMath.swift`, `Sources/SearchCore/Models.swift`. Do not change existing declarations; additive changes only, and mention them in your report.

### `MLXTextEmbedder` public API (Embedding track implements; others code against it)
```swift
public struct MLXEmbedderConfiguration: Sendable {
    public var modelID: String          // default "mlx-community/embeddinggemma-2-bf16" (EmbedderRegistry.embeddinggemma2)
    public var dimensions: Int          // default 768; 512/256/128 = MRL truncation + renormalize
    public var maxTokens: Int           // default 2048 (hard cap 8192)
    public var batchSize: Int           // default 32
    public static let `default`: MLXEmbedderConfiguration
}
public final class MLXTextEmbedder: TextEmbedder {   // Sendable; internally serialized
    public static func load(_ configuration: MLXEmbedderConfiguration = .default,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> MLXTextEmbedder
    public var info: EmbeddingModelInfo { get }
    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]]
}
```

### Built-in command ids (Search track defines items in `BuiltinCommands`; App track executes them)
`lock-screen`, `sleep`, `display-sleep`, `screen-saver`, `restart`*, `shut-down`*, `log-out`*, `empty-trash`*,
`toggle-dark-mode`, `toggle-mute`, `volume-up`, `volume-down`, `screenshot`, `toggle-hidden-files`,
`open-downloads`, `open-desktop`, `open-documents`, `open-home`, `eject-all`*, `restart-finder`, `restart-dock`
(* = `requiresConfirmation = true`)

### Item id conventions
`app:<bundleID>` · `setting:<extensionBundleID>#<anchor or "root">` · `cmd:<id>` · `shortcut:<name>`

## Model usage rules (from research — violating them silently degrades quality)
- Prompts: query `task: search result | query: {q}`; document `title: {title|none} | text: {text}` (prefix stays English even for Korean text). Use `EmbeddingPrompt.format`.
- **Never fp16.** bf16 weights, fp32 output. MRL truncation must re-normalize.
- Batched inference must pass the padding attention mask; batch results must equal single results.
- Every stored vector is tagged with `EmbeddingModelInfo.cacheKey`; a different key ⇒ re-embed.

## Retrieval (Phase 2 corpus ≈ 1–2k items)
- Lexical: NFC normalize, lowercase, Hangul 초성/jamo matching, tiers exact > prefix > word-prefix > substring > 초성 > fuzzy subsequence, over ko+en keywords.
- Dense: in-memory contiguous Float matrix, Accelerate brute force, top-k.
- Fusion: RRF (k=60) of lexical and semantic rank lists + frecency (zoxide/Firefox-style decay) + query→item memory + light kind prior / intent routing (e.g. "설정/settings" → systemSetting). Semantic-only hits need a minimum cosine.
- Store: GRDB SQLite at `~/Library/Application Support/EmbedSearch/index.sqlite` (path injectable): items (zlib JSON), embedding cache (content hash + cacheKey → float16 BLOB, widened to float32 in memory), usage/frecency, query memory, query vectors (float16 per model key, keyed by the query's SHA-256 — no query text is stored — the most recently used 1,000, so a repeated query needs no model).
- Files (`SearchCore/Files`): images and PDFs in user-chosen folders are `.file` items; content chunks (PDF text of 5 pages, OCR, pixels via the vision tower) live in a float16 `ChunkIndex` scored by best chunk cosine minus hubness, fused as their own RRF list. The chunks' text is also kept as tokens (`ContentTokenizer`: words, Hangul as syllable bigrams) in a contentless FTS5 table keyed by file version; a hybrid query's words (as phrases of their tokens) are matched by bm25, and files whose best chunk covers enough of the query (IDF-weighted) are fused as another file list (signal `lexical`), without the model — files the content search missed only for words few files have, and none when the query names an app, setting or command. With files among the results, name-only file matches below a substring match are dropped and loosely matching settings move to a trailing "설정" section (`ResultSections`); confident settings (query asks for settings, or name match ≥ 0.65) keep their rank. `FolderWatcher` (FSEvents) re-syncs.
- App model lifecycle: `EngineRuntime` gives the engine an `OnDemandEmbedder` (EmbedCore). The model is loaded on first use (a query whose vector is neither cached in memory nor stored, or items to embed; opening the panel loads it ahead on external power outside Low Power Mode when no indexing runs, and otherwise only restarts a loaded model's idle clock; a failed load is not retried ahead of need for 10 minutes) and released after `modelIdleSeconds` (default 180) without use; cached vectors keep serving semantic search meanwhile. The model's `EmbeddingModelInfo` is remembered in UserDefaults after the first load, so later launches need no model load to start; a reload with a different `cacheKey` triggers a full re-embed.

## Build conventions (important)
- The default shell runs under **Rosetta** (`uname -m` = x86_64). Prefix every `swift`/`xcodebuild` invocation with **`arch -arm64`**.
- Anything linking MLX must be built with **xcodebuild** (SwiftPM CLI cannot compile Metal shaders):
  `arch -arm64 xcodebuild -scheme embedsearch-cli -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd-<track> build`
- MLX-free targets can use SwiftPM: `arch -arm64 swift build --target SearchCore --scratch-path .build-<track>` / `swift test --filter ... --scratch-path .build-<track>`.
- Use a separate derived-data/scratch path per track so parallel builds don't lock each other.
- Machine: Apple M3 Pro, 18 GB RAM, macOS 26.6.2, Xcode 27.0, ~40 GB free disk.
