# Local inference runtimes for EmbeddingGemma on Apple Silicon (native macOS launcher), state as of 2026-10-13

Scope: running `google/embeddinggemma-2` (released 2026-10-06) or `google/embeddinggemma-300m` (v1, Sept 2025) offline, inside or next to a signed and notarized macOS .app. Korean and English text. Repo metadata (stars, license, last release, last push) was pulled with `gh repo view` on 2026-10-13. HF download counts come from the HF models API on the same day.

Freshness warning: EmbeddingGemma 2 is **one week old**. Almost every v2 integration below was merged 2026-10-06 to 2026-10-12, and several are on `main` only, not yet in a tagged release. Treat all v2 support as "days old, unproven."

---

## 0. Model facts that decide runtime correctness (v1 vs v2 pipeline, prompts, precision)

### Takeaway
v1 and v2 have **different post-transformer pipelines**. v1 (300m) is `Gemma3 trunk → mean pool → Dense 768→3072 → Dense 3072→768 → L2 normalize`. That means two Dense layers, confirmed. v2 has **no separate Dense modules** in its sentence-transformers config: the 512→768 projection lives inside the model, followed by mean pool and normalize. Neither model tolerates fp16 activations. Both need the task prefixes. A runtime that implements only the transformer trunk, uses causal attention, or runs plain fp16 will silently produce degraded vectors.

### Cited Findings
- **EmbeddingGemma 2 release:** Google DeepMind launched EmbeddingGemma 2 on Oct 6, 2026. It is a 740M multimodal model (text, image, audio, video). The launch blog lists only Google's own runtimes: LiteRT (`.litertlm`), MediaPipe Universal Embedder / Semantic Retriever, Google AI Edge Gallery, and "Google AI Edge Foresight (Mac)". It also gives ~191 MB active RAM for text-only and ~567 MB for the full model on a Pixel 11 Pro, plus 37.3 ms per image on a "MacBook M5 Pro GPU" — [Google Developers Blog](https://developers.googleblog.com/en/google-ai-edge-with-embeddinggemma-2/)
- **v2 architecture (model card):** 740M total. The text backbone is 270M (130M transformer + 140M embedder). Vision is 170M and audio is 300M. Other specs:
  - 24 layers, model dim 512, hidden 2048, vocab 262,144.
  - 8,192-token context, 768-d output, MRL 128/256/512/768, mean pooling.
  - "Builds upon … Gemma 4", tagged apache-2.0.
  - "Run inference in bfloat16 or float32. Do not use float16", which can produce NaN or silently degraded embeddings.
  - Source: [HF google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2)
- **v2 access:** The v2 HF repo is **not gated** and its license field is `apache-2.0`. The repo files include `1_Pooling`, `2_Normalize` and no `*_Dense` folder — [HF API google/embeddinggemma-2](https://huggingface.co/api/models/google/embeddinggemma-2)
- **v2 sentence-transformers pipeline:** `modules.json` = Transformer → Pooling → Normalize. There are no Dense modules — [modules.json](https://huggingface.co/google/embeddinggemma-2/blob/main/modules.json). The pooling config is `{"embedding_dimension": 768, "pooling_mode": "mean", "include_prompt": true}` — [1_Pooling/config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/1_Pooling/config.json)
- **v2 config.json details:**
  - `architectures: ["EmbeddingGemma2Model"]`, `model_type: "embedding_gemma2"`.
  - Text config has `hidden_size: 512` and `embedding_dim: 768`, so the projection to 768 is inside the model.
  - Layers follow a 5 sliding : 1 full pattern. `sliding_window: 512`.
  - The full-attention layers (5, 11, 17, 23) use `head_dim: 512` with 1 KV head. `max_position_embeddings: 262144`.
  - Built with `transformers_version: "5.18.0.dev0"`.
  - Source: [config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json)
- **Sliding-window conflict:** The ONNX community card lists "Sliding Window: 1024 tokens" while config.json says 512. The two may be one-sided vs total window. — [onnx-community/embeddinggemma-2-ONNX](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX) vs [config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json)
- **v2 prompts** (config_sentence_transformers.json, built with sentence-transformers 6.1.0):
  - Query: `"task: search result | query: "`
  - Document: `"title: none | text: "`
  - Also classification, clustering, code retrieval, and others.
  - Source: [config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json)
- **v2 benchmarks (768d):** MTEB multilingual v2 61.36 vs v1 61.15. MTEB code 78.68 vs 68.76. Truncated: 512d 61.17, 256d 60.41, 128d 57.89 — [HF google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2)
- **v2 languages:** "100+ languages", with training data covering "over 140 languages". Korean is not named explicitly — [HF google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2)
- **v1 basics:** 308M parameters (~100M model + ~200M embedding), 2K context. Google claims "<15ms embedding inference time (256 input tokens) on EdgeTPU" and "<200MB RAM with quantization". Launch tooling listed: sentence-transformers, llama.cpp, MLX, Ollama, LiteRT, transformers.js, LM Studio — [Google Developers Blog, Introducing EmbeddingGemma](https://developers.googleblog.com/en/introducing-embeddinggemma/)
- **v1 pipeline (two Dense layers):** v1 `modules.json` = Transformer → Pooling → `2_Dense` → `3_Dense` → Normalize. `2_Dense` is `in 768, out 3072, bias false, Identity activation`. `3_Dense` is `in 3072, out 768, bias false, Identity`. Read from the ungated unsloth mirror, because google/embeddinggemma-300m is gated — [unsloth/embeddinggemma-300m modules.json](https://huggingface.co/unsloth/embeddinggemma-300m/blob/main/modules.json), [2_Dense](https://huggingface.co/unsloth/embeddinggemma-300m/blob/main/2_Dense/config.json), [3_Dense](https://huggingface.co/unsloth/embeddinggemma-300m/blob/main/3_Dense/config.json)
- **v1 license and precision:** v1 is gated under the "gemma" license (Gemma Terms of Use) and says "activations do not support float16" — [HF google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
- **Why fp16 fails, with a workaround:** "activations reach ~2,000, so squaring them inside RMSNorm overflows fp16". A plain fp16 conversion gave cosine 0.95 to the reference. Dividing each RMSNorm row by its max-abs value first restored cosine 0.9996 — [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **v1 bidirectional attention:** v1's config has `"use_bidirectional_attention": true`. transformers halves the sliding window when this is set: `|i-j| < sliding_window//2 + 1`, which is ±256 for window 512. A runtime that keeps causal masks gets final cosine of only 0.45–0.70 vs transformers — [mlx-swift-lm PR #654](https://github.com/ml-explore/mlx-swift-lm/pull/654)

### Inferences
- **Correctness checklist for any runtime:**
  - (a) bidirectional (non-causal) attention with the correct symmetric sliding window;
  - (b) mean pooling with the padding mask;
  - (c) v1: both Dense layers; v2: the in-model projection;
  - (d) L2 normalize, and normalize again after MRL truncation;
  - (e) the exact prompt prefixes, added by the app since most runtimes do not add them;
  - (f) fp32/bf16, or an fp16 port with the RMSNorm rescaling trick;
  - (g) correct padding mask in batched mode.
- **Why v2 is easier to port:** Since v2 has no external Dense modules, pipelines that only run the HF model and mean-pool can still be correct for v2 as long as the model graph includes the projection. For v1, "trunk only" ports are wrong.
- **License:** v2's Apache-2.0 license and ungated repo make bundling the weights inside a distributed .app simpler than v1's Gemma Terms.

### Gaps
- No official Google statement that Korean is in the 100+ languages for either version. No Korean-specific MTEB numbers found.

---

## 1. MLX ecosystem (mlx-swift / MLXEmbedders, mlx-embeddings, mlx-vlm, mlx-community weights)

### Takeaway
MLXEmbedders is the most complete native-Swift option for both v1 and v2. It **now lives in `ml-explore/mlx-swift-lm`**, not mlx-swift-examples. v2 support (PR #684) and the critical v1 bidirectional-attention fix (PR #654) were both merged **after** the latest tagged release, 3.32.3 (2026-09-30). The app must therefore pin a `main` commit or wait for the next tag. Before the fix, v1 in MLXEmbedders was **silently wrong**. The Python `mlx-embeddings` supports v1 only, and has an open padding-mask bug for quantized checkpoints.

### Cited Findings
- **Where MLXEmbedders lives:** The model files are `Bert.swift, EmbeddingGemma2.swift, Gemma3.swift, LFM2Bidirectional.swift, NomicBert.swift, Qwen3.swift` — [mlx-swift-lm/Libraries/MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXEmbedders). mlx-swift-examples' last release is 2.29.1 (2025-10-16) — [mlx-swift-examples releases](https://github.com/ml-explore/mlx-swift-examples/releases/tag/2.29.1)
- **v2 support (PR #684):** "Add EmbeddingGemma 2 full support", merged 2026-10-12.
  - It treats v2 as a bidirectional encoder and states that "the VLM factory cannot load it".
  - Checked against transformers SDPA: "cosine 0.9999 for audio, video and interleaved inputs, and 0.99995 at 2,880 and 7,490 tokens."
  - After rebasing on #580: "Initial live MLX memory measured 288 MB versus 1.23 GB" with `mlx-community/embeddinggemma-2-8bit`, because vision and audio load lazily.
  - Source: [mlx-swift-lm PR #684](https://github.com/ml-explore/mlx-swift-lm/pull/684)
- **Third-party text-only test of PR #684:**
  - Model: `mlx-community/embeddinggemma-2-4bit` with vision/audio tensors stripped (~176 MB).
  - Parity vs transformers: cos min 0.9998 / mean 0.9999 on short and 512-token texts; 0.99997 on 1k/2k/4k tokens. A padded batch matched one-by-one runs at ≥0.99994.
  - iPhone 14 Pro: load 0.59 s, ~208 s per 1,000 docs at 512 tokens, peak ~391 MB.
  - Retrieval on a small Polish/English set: MRR 0.94, "identical to the full-precision model in sentence-transformers".
  - Pitfalls reported: (1) leftover `vision_config` without weights fails to load; (2) `hiddenStates` is always nil; (3) fixed 8,192-token cutoff.
  - Source: [PR #684 comment](https://github.com/ml-explore/mlx-swift-lm/pull/684)
- **MLXEmbedders README for v2:**
  - Load with `EmbedderRegistry.embeddinggemma2`. The model "returns a projected, normalized vector in `pooledOutput`; the factory uses `.none` pooling".
  - For padded batches, pass the mask. Truncates at 8,192 tokens and "does not add task prefixes".
  - `dimensions` accepts 128/256/512/768 and re-normalizes.
  - Multimodal input goes through `MLXVLM.EmbeddingGemma2Embedding`.
  - Source: [MLXEmbedders README](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/README.md)
- **v1 causal-attention bug (issue #638):** v1 EmbeddingGemma in MLXEmbedders built **causal** masks and ignored `use_bidirectional_attention`.
  - On 20 German queries against 24 passages: causal hit@1 75% / MRR 0.87 vs patched bidirectional 100% / 1.00.
  - Reported against mlx-swift-lm 3.31.4 on an M5 Max.
  - Source: [mlx-swift-lm issue #638](https://github.com/ml-explore/mlx-swift-lm/issues/638)
- **v1 fix (PR #654):** Merged 2026-10-07.
  - Adds a proper symmetric sliding-window + padding mask.
  - Per-stage error vs transformers fp32: before = final cosine 0.452–0.701; after = ≥0.99999999999 on CPU and GPU.
  - Tested on mlx-swift 0.32.2, macOS 27, M1.
  - Source: [mlx-swift-lm PR #654](https://github.com/ml-explore/mlx-swift-lm/pull/654)
- **Earlier v1 fix:** PR #223 (Apr 2026) "Fix EmbeddingGemma init-order crash + dense head hidden size". Gemma3.swift applies mean pooling and then a `dense` layer list, inferring the Dense hidden dim from the checkpoint — [PR #223](https://github.com/ml-explore/mlx-swift-lm/pull/223); [Gemma3.swift](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/Models/Gemma3.swift)
- **Tags vs fixes:** mlx-swift-lm tags show `3.32.3` (commit date 2026-09-30) as the latest. PRs #654 (merged 10-07) and #684 (merged 10-12) are after it — [mlx-swift-lm releases](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3)
- **Open refactor:** Issue #682 notes that MLXEmbedders' Gemma3/Qwen3 are drifting copies of the MLXLLM code ("a mask bug in EmbeddingGemma sits in code that MLXLLM already has"). It proposes a shared core; this is still open — [mlx-swift-lm issue #682](https://github.com/ml-explore/mlx-swift-lm/issues/682)
- **Build requirement:** "SwiftPM (command line) cannot build the Metal shaders"; you must use Xcode or `xcodebuild` — [mlx-swift README](https://github.com/ml-explore/mlx-swift)
- **mlx-embeddings (Python) supported architectures:** XLM-R, BERT, ModernBERT, Qwen3, Qwen3-VL, Llama-bidirectional, Nemotron-VL. The models dir has `gemma3_text.py`, which covers v1. There is no `embedding_gemma2` model file — [mlx-embeddings README / models dir](https://github.com/Blaizzy/mlx-embeddings/tree/main/mlx_embeddings/models)
- **mlx-embeddings v1 pipeline:** `gemma3_text.py` builds a bidirectional mask and does "Pool first, then dense (matches SentenceTransformers pipeline)" — [gemma3_text.py](https://github.com/Blaizzy/mlx-embeddings/blob/main/mlx_embeddings/models/gemma3_text.py)
- **mlx-embeddings padding bug (open since 2026-08-23):** With quantized checkpoints such as `mlx-community/embeddinggemma-300m-8bit`, the attention mask is cast to packed **uint32**, which "silently destroys the `-inf` entries, so pad tokens leak into attention".
  - Batched cosine falls to 0.884; mean 0.928 over a real 395-sentence transcript.
  - Fix PR #73 is open.
  - Source: [mlx-embeddings issue #72](https://github.com/Blaizzy/mlx-embeddings/issues/72), [PR #73](https://github.com/Blaizzy/mlx-embeddings/pull/73)
- **mlx-embeddings OOM issue (open):** "generate() called per-item in a loop causes unrecoverable Metal OOM crash on ~3,800 sequential calls" — [mlx-embeddings issue #74](https://github.com/Blaizzy/mlx-embeddings/issues/74)
- **mlx-community v2 weights:**
  - Converted with **mlx-vlm** (branch `pc/embeddinggemma-2`), not mlx-embeddings, with MLX 0.32.3.
  - BF16 conversion is 1.489 GB with all modalities.
  - Text min cosine 0.999937 vs PyTorch FP32. "do not cast this model to float16."
  - Source: [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)
- **8-bit variant validation:** Run on an Apple M3 Ultra. Text min cosine 0.99981 vs torch fp32. Weight bytes 1,234,238,431, i.e. full multimodal; most of the size is unquantized media towers — [validation.json](https://huggingface.co/mlx-community/embeddinggemma-2-8bit/blob/main/validation.json)
- **Available MLX conversions:** v2 variants are bf16, 8bit, mxfp8, 4bit, mxfp4, nvfp4, 5bit, 6bit. v1 variants are 4bit, 8bit, bf16, 6bit, 5bit, plus qat-q8/q4 unquantized-bf16. Download counts are low, e.g. v2 bf16 ~2.9k and v1 4bit ~2.3k — [HF models API search "embeddinggemma"](https://huggingface.co/api/models?search=embeddinggemma-2)

### Inferences
- **Recommended path for a Swift launcher:**
  - Use MLXEmbedders from `mlx-swift-lm` pinned to a commit ≥ the PR #684 merge, with `mlx-community/embeddinggemma-2-*` text-only weights.
  - Strip the vision/audio keys and tensors, or rely on #580 lazy loading. That gives ~176–288 MB on disk/RAM.
  - Pure Swift, in-process, no daemon. Build with Xcode/xcodebuild, which is the normal flow for a .app anyway.
- **v1 on a tagged release is unsafe:** If staying on a tagged release ≤3.32.3, v1 EmbeddingGemma output is wrong (causal mask), and v2 is unavailable. This is the single biggest correctness trap found.
- **Quantization headroom:** Throughput evidence on Mac for MLXEmbedders is missing. The iPhone 14 Pro data (~4.8 docs/s at 512 tokens) is a floor; M-series Macs should be much faster (not measured).

### Gaps
- No published Mac (M1–M4) latency or throughput numbers for MLXEmbedders or mlx-embeddings with EmbeddingGemma.
- Unknown when the next mlx-swift-lm tag (including #654/#684) ships.
- No quality numbers for 4-bit vs 8-bit MLX v2 beyond the single PR comment.

---

## 2. llama.cpp (GGUF, Metal, Swift bindings, quantization)

### Takeaway
llama.cpp supports v1 with Dense layers since Oct 2025 and v2 (text+vision+audio) since 2026-10-06. It ships an official prebuilt **XCFramework** per build (64 MB zip for b11583) that can be linked into a .app. Swift wrappers are thin: `mattt/llama.swift` re-exports the C API. There are several fresh v2 bugs and perf issues, mostly CUDA-specific. The OpenAI-compatible server still lacks the `dimensions` parameter.

### Cited Findings
- **v1 support:** PR #15918 "llama : add GEMMA_EMBEDDING architecture support" (Sept 2025) — [llama.cpp PR #15918](https://github.com/ggml-org/llama.cpp/pull/15918). PR #16367 "EmbeddingGemma Adding Support for SentenceTransformers Dense Modules", merged 2025-10-09 — [PR #16367](https://github.com/ggml-org/llama.cpp/pull/16367)
- **Early GGUFs lacked Dense layers:** A third-party repo named "embeddinggemma-300m-GGUF-with-dense-modules" exists. This implies GGUFs converted before PR #16367 lack the two Dense layers, so re-download or use ggml-org's file (updated 2026-04-29) — [cduk/embeddinggemma-300m-GGUF-with-dense-modules](https://huggingface.co/cduk/embeddinggemma-300m-GGUF-with-dense-modules); [ggml-org/embeddinggemma-300M-GGUF](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF)
- **v2 support:** PR #30054 "model: support embeddinggemma2 (text+vision+audio)", merged 2026-10-06, with official GGUF at ggml-org/embeddinggemma-2-GGUF — [llama.cpp PR #30054](https://github.com/ggml-org/llama.cpp/pull/30054)
- **v2 GGUF files:**
  - ggml-org: `embeddinggemma-2-BF16.gguf` 558 MB, `Q8_0` 310 MB, plus mmproj BF16 982 MB / Q8_0 555 MB for the media towers. The README just says `llama serve -hf ggml-org/embeddinggemma-2-GGUF` — [ggml-org/embeddinggemma-2-GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF)
  - unsloth adds UD-Q4_K_XL 176 MB, UD-Q5_K_XL 210 MB, UD-Q6_K_XL 249 MB, F16 558 MB — [unsloth/embeddinggemma-2-GGUF](https://huggingface.co/unsloth/embeddinggemma-2-GGUF)
- **v2 bugs and fixes, CUDA-specific:**
  - Issue #30398: with `-fa on`, v2 runs ~10× slower when the token count isn't a multiple of 256, because head_dim 512 forces a CPU fallback. Closed 2026-10-12. It was CUDA, Linux, RTX PRO 2000 Blackwell — [issue #30398](https://github.com/ggml-org/llama.cpp/issues/30398)
  - PR #30416 "pad the KV dimension of the no-cache attention to 256", merged 2026-10-12 — [PR #30416](https://github.com/ggml-org/llama.cpp/pull/30416)
- **Memory-related PRs for embedding models:**
  - PR #30255 (merged 2026-10-09) skips the logits buffer for models without an LM head (EmbeddingGemma, BERT) — [PR #30255](https://github.com/ggml-org/llama.cpp/pull/30255)
  - PR #30445 (open 2026-10-13) skips the LM head for all pooled embeddings. Example: Qwen3-Embedding-0.6B compute buffer 5.0 GiB → 0.54 GiB on CUDA — [PR #30445](https://github.com/ggml-org/llama.cpp/pull/30445)
- **`dimensions` parameter (MRL) unsupported:** The OpenAI-compatible `/v1/embeddings` doesn't accept `dimensions`. Issue #25210 and PR #24898 are both open — [issue #25210](https://github.com/ggml-org/llama.cpp/issues/25210), [PR #24898](https://github.com/ggml-org/llama.cpp/pull/24898)
- **Other v1/v2 bugs:**
  - Issue #18532: `GGML_ASSERT` with `--parallel` not a power of 2 for embeddinggemma (closed Jan 2026) — [issue #18532](https://github.com/ggml-org/llama.cpp/issues/18532)
  - Issue #30195: v2 vision bug, open — [issue #30195](https://github.com/ggml-org/llama.cpp/issues/30195)
  - Issue #30082: server `/embedding` ignored image_data, closed — [issue #30082](https://github.com/ggml-org/llama.cpp/issues/30082)
- **XCFramework:** llama.cpp ships "a precompiled version of the library for iOS, visionOS, tvOS, and macOS" that can be used as a SwiftPM `binaryTarget` — [docs/xcframework.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)
- **Latest build assets:** Build b11583 (2026-10-13) includes `llama-b11583-xcframework.zip` (64 MB) and `llama-b11583-bin-macos-arm64.tar.gz` (12 MB). llama.cpp also now has a separate `v0.6.0` tag (2026-10-05) used for the new `llama` CLI / llama.app — [llama.cpp release b11583](https://github.com/ggml-org/llama.cpp/releases/tag/b11583)
- **mattt/llama.swift:** "re-exports the llama.cpp C++ APIs directly, using the precompiled XCFramework", tracks upstream releases, macOS 13+. ~83 stars, MIT — [mattt/llama.swift](https://github.com/mattt/llama.swift)
- **LLM.swift:** ~882 stars, MIT, last release v3.0.3 (2026-07-19). It is chat/generation-oriented, and embedding support was not verified — [eastriverlee/LLM.swift](https://github.com/eastriverlee/LLM.swift)
- **Quantization quality, v1 vs v2:**
  - v1 has Google QAT checkpoints: `ggml-org/embeddinggemma-300m-qat-q8_0-GGUF` (~34k downloads) and `…-qat-q4_0-GGUF` — [HF models API](https://huggingface.co/api/models?search=embeddinggemma-300m)
  - v2 has no QAT GGUF from Google on HF; Google's QAT INT4/INT8 for v2 is in LiteRT form — [Google Developers Blog](https://developers.googleblog.com/en/google-ai-edge-with-embeddinggemma-2/)

### Inferences
- **Integration effort:** llama.cpp is a strong candidate if the app wants one C API for embedding plus possible future LLM features. Integration means:
  - writing a small Swift wrapper: tokenize, create a context with `embeddings=true` and mean pooling (`LLAMA_POOLING_TYPE_MEAN`), `llama_decode`, `llama_get_embeddings_seq`;
  - adding the prefixes yourself;
  - doing MRL truncation and re-normalization yourself.
- **Packaging:** The XCFramework is signed together with the app. No daemon is needed.
- **v2 maturity:** v2 on llama.cpp is days old. The perf bugs found were on CUDA. No Metal-specific v2 issues were found, but no Metal perf data was found either.

### Gaps
- No published quality comparison (cosine vs sentence-transformers, or retrieval) for v2 Q8_0 / Q4_K_M / UD-Q4_K_XL GGUFs.
- No Metal latency or throughput numbers for EmbeddingGemma on M-series.
- I did not verify whether `llama-embedding` defaults to mean pooling from GGUF metadata for v2.

---

## 3. Ollama and LM Studio (external daemon)

### Takeaway
Both serve EmbeddingGemma v1 and v2 over HTTP: Ollama `/api/embed`, LM Studio's OpenAI-compatible `/v1/embeddings`. v2 support arrived in Ollama 0.40.x on 2026-10-10 to 10-12. On macOS, some Ollama v2 tags are **MLX-only safetensors**. Both force a user-installed daemon with independent versioning, ports and defaults, which is a poor fit for a self-contained notarized launcher. Use them only as an optional "bring your own runtime" backend.

### Cited Findings
- **Ollama v1:** `embeddinggemma:300m` is 622 MB, 2K context, text, and requires Ollama v0.11.10+. Use via `POST /api/embed` — [ollama.com/library/embeddinggemma](https://ollama.com/library/embeddinggemma)
- **Ollama v2 tags:**
  - `embeddinggemma-2` sizes: `270m` (text, 378 MB), `440m` (text+image, 714 MB), `570m` (text+audio, 990 MB), `740m` (1.3 GB).
  - bf16, mxfp8 and nvfp4 variants exist; mxfp8/nvfp4 carry an MLX badge.
  - Every tag lists a 256K context.
  - Source: [ollama.com/library/embeddinggemma-2/tags](https://ollama.com/library/embeddinggemma-2/tags)
- **MLX-only v2 tags:** `embeddinggemma-2:740m`/`latest` has the same digest as `740m-nvfp4`. Its layers are all safetensors with no GGUF, so it errors on Linux: "this model requires MLX support, but the MLX runtime is not available". Reported on Ollama 0.40.4-rc0 — [ollama issue #18971](https://github.com/ollama/ollama/issues/18971)
- **Ollama v2 updates:**
  - PR #18917 (merged 2026-10-12) updates vendored llama.cpp to b11521 for EmbeddingGemma 2. "EmbeddingGemma 2 GGUFs can embed images and audio" — [ollama PR #18917](https://github.com/ollama/ollama/pull/18917)
  - PR #18973 (merged 2026-10-13) fixes multimodal embedding load with small num_ctx — [ollama PR #18973](https://github.com/ollama/ollama/pull/18973)
- **Ollama v1 perf and bugs:**
  - Issue #12239 (open since Sept 2025): 200 requests batched took 9.27 s for bf16 and 2.08 s for qat-q8_0 on an RTX 4090. One commenter: "On mac, the speed for embeddinggemma is ok" — [ollama issue #12239](https://github.com/ollama/ollama/issues/12239)
  - Issue #12508 (open): "164x slowdown with excessive whitespace in text" — [ollama issue #12508](https://github.com/ollama/ollama/issues/12508)
  - Issue #12426 (open): can't run fine-tuned embeddinggemma GGUF — [ollama issue #12426](https://github.com/ollama/ollama/issues/12426)
- **LM Studio v2:** LM Studio 0.4.26 with llama.cpp runtime 2.55.0 (b11511) on macOS 26.4.1 / M3 loads `embeddinggemma-2` Q8_0 GGUF and "works for text".
  - `/v1/embeddings` rejects image/audio input.
  - The default context "tries to allocate a 128 GB buffer and fails; `--context-length 8192` works".
  - Source: [lmstudio-bug-tracker #2486](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2486)
- **LM Studio v1:** LM Studio has a model page for EmbeddingGemma 300M (2048 context) — [lmstudio.ai/models/google/embedding-gemma-300m](https://lmstudio.ai/models/google/embedding-gemma-300m). An earlier load bug was in v0.3.25 — [lmstudio-bug-tracker #978](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/978)
- **Repo metadata:** Ollama is MIT, ~183k stars, v0.40.3 released 2026-10-11 — [ollama/ollama](https://github.com/ollama/ollama). LM Studio's `lms` CLI repo is MIT, ~5.3k stars, no GitHub releases — [lmstudio-ai/lms](https://github.com/lmstudio-ai/lms)

### Inferences
- **Version skew is real:** The dev machine used for this research has Ollama 0.22.1 installed, far older than the 0.40.x needed for v2. A launcher can't control the user's daemon version, model tag, `num_ctx`, keep-alive, or whether it's running.
- **Context footgun:** v2's config advertises `max_position_embeddings: 262144`, and Ollama's page shows 256K. Daemons may size buffers from that unless the app sets the context to 8K explicitly, as the LM Studio report shows.
- **Daemon pros and cons:**
  - Pros: zero model-runtime code in the app, shared model cache with the user's other tools, GPU/MLX handled by the daemon.
  - Cons: install friction, port conflicts, no guarantee about prefixes/pooling, cross-process latency, and unclear behavior when the daemon unloads the model (keep_alive).
  - Good as an optional fallback, not as the primary engine.

### Gaps
- No Mac-specific latency numbers for Ollama/LM Studio with EmbeddingGemma v1 or v2.
- Not verified whether LM Studio's MLX engine serves v2 embeddings.
- Not verified whether Ollama's MLX path applies mean pooling and prefixes correctly for v2.

---

## 4. Core ML / ANE, swift-transformers, swift-embeddings, Apple NL / Foundation Models

### Takeaway
Two community Core ML ports exist:
- **v2: `FluidInference/embeddinggemma-2-coreml`.** The text model runs 100% on the ANE, with the best published Apple Silicon numbers found: ~2.6–27 ms per text, ~644 texts/s on an M5 Pro. It was published 2026-10-09 (4 days old).
- **v1: `shirochenkov90/embeddinggemma-300m-coreml`.** Full pipeline including both Dense layers, very low adoption.

Core ML needs **fixed or enumerated shapes** (≤512 tokens) and a one-time ANE compile that can take minutes. `swift-embeddings` does **not** support Gemma. Apple's built-in NLContextualEmbedding covers Korean but isn't designed for retrieval. No Foundation Models embedding API was found.

### Cited Findings
- **FluidInference v2 Core ML port:**
  - `EmbeddingGemma2Text.mlpackage`: an fp16 ML Program with 7 functions sharing one weight set (271 MB). `embed_32 … embed_512` plus `pack_256`, which handles up to 8 short texts per call.
  - The token-embedding table (`embeddings.bf16`, 256 MB) is looked up outside Core ML.
  - "Every function has fixed shapes, which is what keeps it on the Neural Engine. Variable-length (enumerated) shapes put the whole graph on the CPU."
  - Inputs >512 tokens must be truncated.
  - Requires macOS 15 / iOS 18. "The first load on a device compiles all seven functions for the Neural Engine, which takes several minutes once; Core ML caches the result."
  - Source: [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **FluidInference numbers (M5 Pro, macOS 27):**
  - 3,862 / 3,862 ops on the Neural Engine.
  - Latency per text: 32 tokens 2.6 ms, 64 tokens 3.2 ms, 128 tokens 5.6 ms, 256 tokens 11.3 ms, 512 tokens 27.4 ms.
  - Throughput: 644 texts/s (`pack_256`) or 307/s one per call.
  - Cosine vs PyTorch fp32 sentence-transformers: ≥0.9984, mean 0.99996 over 562 posts.
  - The fp16 RMSNorm max-abs rescaling trick is used (plain fp16 gives 0.95).
  - Demos: 5,617 functions indexed in 16 s; ~700 searches/s.
  - License Apache 2.0. Swift implementation: `EmbeddingGemma2Manager` in FluidUse.
  - Source: [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **FluidUse repo:** ~506 stars, Apache-2.0, SwiftPM `from: "0.3.0"`. It contains `Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Manager.swift` — [FluidInference/FluidUse](https://github.com/FluidInference/FluidUse)
- **FluidInference image path:** The vision encoder runs faster on GPU than ANE at every budget. At 70 tokens: 14.6 ms GPU vs 37 ms ANE on an M5 Pro — [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **shirochenkov90 v1 Core ML port:**
  - Pipeline: "Gemma3 transformer → mean pooling over attention_mask → Dense(768→3072) → Dense(3072→768) → L2 normalization".
  - fp16 ML Program (615 MB weights).
  - Enumerated shapes (1,64) or (1,256), batch size 1, right padding, macOS 15+.
  - Cosine vs PyTorch fp32: 0.999963 / 0.999966.
  - ~194 downloads.
  - Source: [shirochenkov90/embeddinggemma-300m-coreml](https://huggingface.co/shirochenkov90/embeddinggemma-300m-coreml)
- **coremltools:** Latest release 9.0 (2025-11-10), BSD-3, ~5.4k stars, last push 2026-09-30 — [apple/coremltools](https://github.com/apple/coremltools)
- **swift-transformers tokenizer issue (#383, open):** `Tokenizer.encode` is quadratic in the number of added tokens. With Gemma-3 (6,415 added tokens) that costs "~29 ms per newline": 40 newline-separated lines take 1,148 ms on swift-transformers 1.3.3 — [swift-transformers issue #383](https://github.com/huggingface/swift-transformers/issues/383)
- **swift-transformers metadata:** v1.3.5 (2026-10-09), Apache-2.0, ~1.36k stars — [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers). swift-huggingface 1.0.0 (2026-10-09) — [huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface)
- **swift-embeddings (jkrukowski):** "Run embedding models locally in Swift using MLTensor".
  - Supports BERT, ModernBERT, NomicBERT, RoBERTa, XLM-RoBERTa (e.g. multilingual-e5-small), Qwen3-Embedding, CLIP text, Model2Vec, Static and Word2Vec embeddings. **No Gemma/EmbeddingGemma.**
  - "BF16 … MLTensor cannot represent", so a Float32 conversion is needed.
  - ~155 stars, MIT, v0.1.1 (2026-09-21).
  - Searching the repo for EmbeddingGemma found no issues or PRs.
  - Source: [jkrukowski/swift-embeddings](https://github.com/jkrukowski/swift-embeddings)
- **NLContextualEmbedding:**
  - macOS 14+. 27 languages in three script models: Latin, Cyrillic and CJK, with **Korean in the CJK model**.
  - Assets are "downloaded as needed" (`hasAvailableAssets` / `requestAssets`).
  - Presented as an input layer for training classifiers and taggers, not as a semantic-search embedding.
  - Source: [WWDC23 10042 notes](https://wwdcnotes.com/documentation/wwdc23-10042-explore-natural-language-multilingual-models/); [Apple docs](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- **Foundation Models:** No source found for an embeddings API in the Foundation Models framework. Secondary blogs claim WWDC 2026 opened Foundation Models to MLX/HF models; this is unverified against Apple docs — [Medium (secondary)](https://medium.com/@nuthalapativarun/mlx-is-now-a-first-class-citizen-in-apples-ai-stack-run-any-hugging-face-model-through-foundation-9dfb8dad2191)

### Inferences
- **Best latency and energy:** Core ML on the ANE is likely the lowest-latency, lowest-power path for a background-indexing launcher. It keeps the GPU free and is a zero-dependency system framework, so signing and notarization are simple.
- **Core ML trade-offs:**
  - Truncation at 512 tokens; documents need chunking.
  - A one-time multi-minute ANE compile per device, so it needs UX for first-run indexing.
  - Dependency on a 4-day-old third-party conversion.
  - The tokenizer must be reproduced exactly in Swift: `<bos>`/`<eos>`, right padding. The quadratic added-token behavior in swift-transformers is a real risk for multi-line documents, so verify it with EmbeddingGemma's tokenizer.json or use a different tokenizer implementation.
- **Apple-native fallback:** NLContextualEmbedding could serve as a zero-download Apple-native fallback for "related" signals in Korean/English. Its retrieval quality vs EmbeddingGemma is unmeasured, and it isn't trained for query/document asymmetry.

### Gaps
- No ANE numbers on M1/M2/M3/M4. FluidInference reports only M5 Pro; ANE generations differ.
- No independent verification of FluidInference's parity claims. No Korean-specific check.
- No published Core ML port of v2 with dynamic shapes, or official Apple conversion.
- NLContextualEmbedding dimension and retrieval quality not found.

---

## 5. ONNX Runtime (CoreML EP), onnx-community weights, Rust (fastembed-rs, ort, candle), TEI

### Takeaway
ONNX is mature for v1. onnx-community ONNX outputs `sentence_embedding` (full pipeline), and fastembed-rs ships v1 in fp32, q8 and q4. For v2, onnx-community published ONNX on launch day, with good fp16/q8 parity and q4 text cosine 0.988, but no Rust/Swift library wraps it yet. On macOS, ORT's CoreML EP gives partial, fragmentation-prone acceleration for transformer graphs, and the official ORT Swift package lags 7 minor versions. candle and TEI have no v2 support.

### Cited Findings
- **onnx-community v1 ONNX:**
  - "activations do not support fp16 … use fp32, q8, or q4".
  - Python ORT example: `session.run` returns `sentence_embedding` of shape (5, 768).
  - Files: fp32 1.23 GB, quantized (q8) 309 MB, q4 197 MB, q4f16 175 MB.
  - Source: [onnx-community/embeddinggemma-300m-ONNX](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX)
- **onnx-community v2 ONNX:**
  - Created 2026-10-04 and updated 2026-10-06. Separate `model`, `vision_encoder` and `audio_encoder` ONNX files.
  - Text model sizes and cosine vs fp32: fp32 1085 MB; fp16 543 MB (0.9998); q8 314 MB (0.9997); q4 175 MB (text 0.988); q4f16 157 MB (text 0.988).
  - Output `sentence_embedding`. Text-only loading by removing encoder configs.
  - Source: [onnx-community/embeddinggemma-2-ONNX](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX)
- **ORT CoreML EP behavior:**
  - The MLProgram format is opt-in; the default is NeuralNetwork.
  - Requesting ANE "does not guarantee the entire model to be executed using ANE".
  - Dynamic shapes are allowed but "performance may be negatively impacted".
  - Source: [ONNX Runtime CoreML EP docs](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
- **ORT CoreML EP op coverage:** Recent ORT commits are still adding ops (Where/And, bool Cast) so transformer graphs run "as a single CoreML partition instead of fragmenting across CPU". This is search-snippet level from commit mirrors and was not fetched in full — [semanticdiff commit mirror](https://app.semanticdiff.com/gh/microsoft/onnxruntime/commit/5dd7f15cd0be9e9d8c8741cd9a5d99272bf106ed)
- **ORT versions:** ORT v1.31.0 was released 2026-10-09 (MIT, ~22k stars) — [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime). The official Swift package `onnxruntime-swift-package-manager` is at 1.24.2 (2026-02-25), ~100 stars — [microsoft/onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
- **fastembed-rs:**
  - Enum variants `EmbeddingGemma300M` (`onnx/model.onnx`), `EmbeddingGemma300MQ4` (`model_q4.onnx`) and `EmbeddingGemma300MQ` (`model_quantized.onnx`), all from onnx-community/embeddinggemma-300m-ONNX with `output_key: "sentence_embedding"`.
  - No v2 variant.
  - Source: [fastembed-rs text_embedding.rs](https://github.com/Anush008/fastembed-rs/blob/main/src/models/text_embedding.rs)
  - The quantized variants were added in PR #256, merged 2026-06 — [fastembed-rs PR #256](https://github.com/anush008/fastembed-rs/pull/256)
  - Metadata: Apache-2.0, ~1.04k stars, v7.1.1 (2026-10-07). It uses `pykeio/ort` — [Anush008/fastembed-rs](https://github.com/Anush008/fastembed-rs)
- **ort:** v2.0.0-rc.14 (2026-10-12), still a release candidate. Apache-2.0, ~2.6k stars — [pykeio/ort](https://github.com/pykeio/ort)
- **candle:** No merged EmbeddingGemma model. Open PR #3363 adds a WASM example for quantized EmbeddingGemma 300M GGUF by modifying `quantized_gemma3.rs`, "post-processed by 2 dense layers and normalized" — [candle PR #3363](https://github.com/huggingface/candle/pull/3363). candle has ~21k stars, Apache-2.0, no GitHub releases — [huggingface/candle](https://github.com/huggingface/candle)
- **TEI (text-embeddings-inference):**
  - v1 supported (gemma3 test #718; Dense-module loading fix #738).
  - v1 only supported in fp32 (#748).
  - A reported mismatch vs sentence-transformers (#749) was resolved as a dtype difference: bf16 in ST vs fp32 in TEI.
  - v2 is unsupported: "malformed config.json" (#947, open 2026-10-08).
  - Sources: [TEI #749](https://github.com/huggingface/text-embeddings-inference/issues/749), [TEI #748](https://github.com/huggingface/text-embeddings-inference/issues/748), [TEI #947](https://github.com/huggingface/text-embeddings-inference/issues/947), [TEI #738](https://github.com/huggingface/text-embeddings-inference/pull/738)

### Inferences
- **Rust stack:** fastembed-rs (ORT) is a reasonable Rust option for v1 today, CPU-only or with the CoreML EP. A Rust core bridged to a Swift UI via FFI adds build complexity but gives a portable engine.
- **v2 via ONNX:** Running v2 in Rust or Swift would mean driving ORT directly against the onnx-community files. The tokenizer can come from the `tokenizers` crate.
- **CoreML EP vs native Core ML:** The CoreML EP's fragmentation and dynamic-shape penalties make it likely slower than a purpose-built Core ML conversion (section 4). This is unmeasured.

### Gaps
- No Mac benchmarks for ORT CPU vs CoreML EP with EmbeddingGemma.
- Unknown whether onnx-community v2's fp16 parity (0.9998) uses a similar RMSNorm rescaling trick.
- No fastembed-rs v2 issue or PR found.

---

## 6. Python sidecar (sentence-transformers + PyTorch MPS, or MLX Python)

### Takeaway
Python is the **reference-correct** path, since sentence-transformers defines the pipeline. v2 currently needs bleeding-edge versions: transformers 5.18.0.dev0 was used to build it. As an app sidecar it means bundling a Python interpreter plus a 127 MB torch wheel (much larger installed), with a slow cold start. Use it for offline evaluation and as a parity oracle, not as the shipped engine.

### Cited Findings
- **Version requirements:** v2's `config_sentence_transformers.json` records pytorch 2.14.0, sentence_transformers 6.1.0 and transformers 5.18.0.dev0. It also notes older ST versions "ignore the order of multimodal dict inputs" — [config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json)
- **Processor support:** "stock PyPI Transformers 5.18.0 does not yet expose" `EmbeddingGemma2Processor`, which is needed only for multimodal; text-only uses AutoTokenizer — [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)
- **PyPI sizes on 2026-10-13:**
  - torch 2.14.1 macOS arm64 cp312 wheel: 127.3 MB
  - transformers 5.19.0 (2026-10-06): 12.6 MB
  - sentence-transformers 6.1.0: 0.7 MB
  - onnxruntime 1.31.0 arm64 wheel: 20.9 MB
  - mlx 0.32.3 wheel: 0.7 MB (plus the separate mlx-metal package)
  - Sources: [PyPI torch](https://pypi.org/project/torch/), [PyPI transformers](https://pypi.org/project/transformers/), [PyPI sentence-transformers](https://pypi.org/project/sentence-transformers/), [PyPI onnxruntime](https://pypi.org/project/onnxruntime/)
- **Precision:** fp16 is forbidden for both v1 and v2. On MPS that means fp32 or bf16 — [HF google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2); [HF google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
- **Dtype affects comparisons:** A reported ST vs TEI mismatch disappeared when both used fp32 — [TEI #749](https://github.com/huggingface/text-embeddings-inference/issues/749)

### Inferences
- **Packaging cost:** A Python sidecar means signing every embedded `.so`/`.dylib` in the bundle for notarization, shipping several hundred MB, and paying multi-second interpreter + torch import + model load at startup. Those are general experience-based expectations, not measured here.
- **MLX Python:** mlx + mlx-vlm/mlx-embeddings is lighter than torch but still Python, and mlx-embeddings has the open padding bug (#72).

### Gaps
- No published cold-start time or RSS for sentence-transformers + EmbeddingGemma on MPS.
- Not verified whether transformers 5.19.0 (released on v2 launch day) includes `embedding_gemma2` in a stable release.
- A local M3 Pro 18 GB (macOS 26.6.2) with sentence-transformers 5.1.1 was available but **not benchmarked**, to avoid large downloads.

---

## 7. Benchmarks on Apple Silicon (what exists, with hardware)

### Takeaway
Published, hardware-attributed numbers for EmbeddingGemma on Macs are **scarce**. The only solid Mac throughput and latency figures are FluidInference's Core ML/ANE numbers on an **M5 Pro**. There are MLX parity and memory figures (M3 Ultra validation; iPhone 14 Pro timings) and Google's own figures (EdgeTPU, Pixel, M5 Pro vision). **No head-to-head MLX vs llama.cpp vs Core ML embedding benchmark on M1–M4 was found.** The app team should run its own benchmark.

### Cited Findings
- **Core ML, ANE, M5 Pro, v2 text:** 2.6 ms at 32 tokens, 5.6 ms at 128, 11.3 ms at 256, 27.4 ms at 512. 644 texts/s packed short posts, 307/s single — [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **MLX Swift, iPhone 14 Pro (6 GB), v2 4-bit text-only:** load 0.59 s, ~208 s per 1,000 docs at 512 tokens (≈4.8 docs/s), peak ~391 MB — [mlx-swift-lm PR #684 comment](https://github.com/ml-explore/mlx-swift-lm/pull/684)
- **MLX Swift memory, v2 8-bit:** 288 MB live MLX memory text-only vs 1.23 GB with all towers. The device is not stated — [mlx-swift-lm PR #684](https://github.com/ml-explore/mlx-swift-lm/pull/684)
- **MLX Python validation (Apple M3 Ultra):** Parity checks only, with no timing: text min cosine 0.99981 (8-bit) — [validation.json](https://huggingface.co/mlx-community/embeddinggemma-2-8bit/blob/main/validation.json)
- **Google's v2 figures:** ~191 MB text-only and ~567 MB full on a Pixel 11 Pro; image embedding 37.3 ms on an M5 Pro GPU. Google's v1 figures: <15 ms per 256 tokens on EdgeTPU, <200 MB RAM quantized — [Google v2 blog](https://developers.googleblog.com/en/google-ai-edge-with-embeddinggemma-2/); [Google v1 blog](https://developers.googleblog.com/en/introducing-embeddinggemma/)
- **llama.cpp v2, NVIDIA only (not Mac):**
  - RTX PRO 2000 Blackwell, Q8_0, `-fa off`: 1024 tokens 0.056 s, 2048 tokens 0.111 s, 3840 tokens 0.30 s per request.
  - Shows how v2 scales with length; useful only as relative data.
  - Source: [llama.cpp issue #30398](https://github.com/ggml-org/llama.cpp/issues/30398)
- **Ollama v1, RTX 4090 (not Mac):** 200 batched requests of ~300-char strings took 9.27 s (bf16) and 2.08 s (qat-q8_0) — [ollama issue #12239](https://github.com/ollama/ollama/issues/12239)
- **Unreliable estimates:** willitrunai.com gives "estimated" tokens/s and a ~3.8 GB memory figure for embeddinggemma-300m GGUF on M4. These are decode-speed estimates that don't apply to encoders and conflict with Google's <200 MB claim, so **disregard them** — [willitrunai M4 Max page](https://willitrunai.com/can-run/hf-ggml-org--embeddinggemma-300m-gguf-on-m4-max-64gb)

### Inferences
- **Indexing speed:** Using M5 Pro ANE numbers as an optimistic bound, ~300–650 short texts/s means indexing 100k short launcher items (file names, titles, snippets) would take minutes, not hours. Older ANEs (M1/M2) will be slower; magnitude unknown.
- **Query latency:** A single short query (~32–64 tokens) costs a few ms on Core ML/ANE. MLX/llama.cpp on GPU is likely in the low tens of ms including launch overhead (unmeasured). Both are well within launcher keystroke budgets if the model stays resident.

### Gaps
- No M1/M2/M3/M4 numbers for any runtime with EmbeddingGemma.
- No cold-start (model load) times on Mac for llama.cpp, Core ML (beyond the "several minutes once" ANE compile) or Python.
- Suggested in-house benchmark on the available M3 Pro 18 GB:
  - Runtimes: MLXEmbedders main, llama.cpp b11583 XCFramework with Q8_0/UD-Q4_K_XL, FluidInference Core ML, and ORT q8 via ST/fastembed.
  - Metrics: ms/query at 16/64 tokens, docs/s at 256/512 tokens, RSS, cold load.
  - Parity: cosine vs sentence-transformers fp32 on a Korean+English set.

---

## 8. Runtime repo metadata summary (as of 2026-10-13, via `gh repo view`)

### Takeaway
The most active repos with v2 support right now are llama.cpp, Ollama and mlx-swift-lm (main only). The Core ML port is newest and least proven. fastembed-rs and TEI cover v1 only. swift-embeddings and candle have no EmbeddingGemma support.

### Cited Findings
| Runtime | GitHub | Stars | License | Latest release / last push | EmbeddingGemma status |
|---|---|---|---|---|---|
| mlx-swift (core) | [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) | ~2.06k | MIT | 0.32.3 (2026-09-30) / 2026-10-12 | Runtime only |
| mlx-swift-lm (MLXEmbedders) | [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | ~834 | MIT | 3.32.3 (2026-09-30) / 2026-10-12 | v1 fixed on main ([#654](https://github.com/ml-explore/mlx-swift-lm/pull/654), 10-07); v2 on main ([#684](https://github.com/ml-explore/mlx-swift-lm/pull/684), 10-12); **not in a tag yet** |
| mlx-swift-examples | [ml-explore/mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | ~2.68k | MIT | 2.29.1 (2025-10-16) / 2026-07-20 | Superseded by mlx-swift-lm for MLXEmbedders (stale) |
| mlx-embeddings (Py) | [Blaizzy/mlx-embeddings](https://github.com/Blaizzy/mlx-embeddings) | ~449 | "Other" per GitHub | v0.1.0 (2026-03-24) / 2026-05-13 | v1 only; padding bug [#72](https://github.com/Blaizzy/mlx-embeddings/issues/72) open; no v2 |
| mlx-lm (Py) | [ml-explore/mlx-lm](https://github.com/ml-explore/mlx-lm) | ~7.3k | MIT | v0.31.3 (2026-04-22) / 2026-10-10 | n/a. v2 MLX conversion used mlx-vlm branch ([mlx-community](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)) |
| llama.cpp | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | ~131k | MIT | b11583 (2026-10-13); v0.6.0 tag (2026-10-05) | v1 ([#15918](https://github.com/ggml-org/llama.cpp/pull/15918), Dense [#16367](https://github.com/ggml-org/llama.cpp/pull/16367)); v2 ([#30054](https://github.com/ggml-org/llama.cpp/pull/30054), 10-06) |
| llama.swift | [mattt/llama.swift](https://github.com/mattt/llama.swift) | ~83 | MIT | no GH releases / 2026-10-12 | Thin C-API re-export of the XCFramework |
| LLM.swift | [eastriverlee/LLM.swift](https://github.com/eastriverlee/LLM.swift) | ~882 | MIT | v3.0.3 (2026-07-19) | Embedding API not verified |
| Ollama | [ollama/ollama](https://github.com/ollama/ollama) | ~183k | MIT | v0.40.3 (2026-10-11) / 2026-10-13 | v1 (≥0.11.10); v2 ([#18917](https://github.com/ollama/ollama/pull/18917), 10-12); some v2 tags MLX-only ([#18971](https://github.com/ollama/ollama/issues/18971)) |
| LM Studio CLI | [lmstudio-ai/lms](https://github.com/lmstudio-ai/lms) | ~5.3k | MIT (CLI) | none / 2026-10-09 | v2 text works via llama.cpp runtime 2.55.0; media blocked ([#2486](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2486)) |
| coremltools | [apple/coremltools](https://github.com/apple/coremltools) | ~5.4k | BSD-3 | 9.0 (2025-11-10) / 2026-09-30 | Community ports: [v2](https://huggingface.co/FluidInference/embeddinggemma-2-coreml), [v1](https://huggingface.co/shirochenkov90/embeddinggemma-300m-coreml) |
| FluidUse (Core ML Swift) | [FluidInference/FluidUse](https://github.com/FluidInference/FluidUse) | ~506 | Apache-2.0 | SPM 0.3.0+ / 2026-10-13 | `EmbeddingGemma2Manager` (v2, ANE) |
| swift-transformers | [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) | ~1.36k | Apache-2.0 | 1.3.5 (2026-10-09) | Tokenizer; quadratic added-token issue [#383](https://github.com/huggingface/swift-transformers/issues/383) |
| swift-huggingface | [huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface) | ~178 | Apache-2.0 | 1.0.0 (2026-10-09) | Hub client used by MLXEmbedders |
| swift-embeddings | [jkrukowski/swift-embeddings](https://github.com/jkrukowski/swift-embeddings) | ~155 | MIT | 0.1.1 (2026-09-21) | **No Gemma support** |
| ONNX Runtime | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | ~22k | MIT | v1.31.0 (2026-10-09) | Runs onnx-community [v1](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX)/[v2](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX) ONNX |
| ORT Swift package | [microsoft/onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) | ~100 | MIT | 1.24.2 (2026-02-25) | Lags ORT core |
| fastembed-rs | [Anush008/fastembed-rs](https://github.com/Anush008/fastembed-rs) | ~1.04k | Apache-2.0 | v7.1.1 (2026-10-07) | v1 fp32/q8/q4 ([#256](https://github.com/anush008/fastembed-rs/pull/256)); no v2 |
| ort (Rust) | [pykeio/ort](https://github.com/pykeio/ort) | ~2.56k | Apache-2.0 | v2.0.0-rc.14 (2026-10-12) | Generic ORT binding (still RC) |
| candle | [huggingface/candle](https://github.com/huggingface/candle) | ~21.2k | Apache-2.0 | no GH releases / 2026-10-13 | No merged EmbeddingGemma; WASM PR [#3363](https://github.com/huggingface/candle/pull/3363) open |
| TEI | [huggingface/text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference) | ~5.08k | Apache-2.0 | v1.9.4 (2026-09-15) | v1 fp32 only; v2 unsupported ([#947](https://github.com/huggingface/text-embeddings-inference/issues/947)) |
| sentence-transformers | [UKPLab → huggingface/sentence-transformers](https://github.com/huggingface/sentence-transformers) | ~19.2k | Apache-2.0 | v6.1.0 (2026-09-18) | Reference implementation (v1 and v2) |

- HF adoption signal for v2 converted weights on 2026-10-13: onnx-community/embeddinggemma-2-ONNX ~105k downloads; unsloth GGUF ~81.5k; litert-community 740m ~64.6k; ggml-org GGUF ~31.7k; mlx-community bf16 ~2.9k; FluidInference Core ML ~547 — [HF models API](https://huggingface.co/api/models?search=embeddinggemma-2)

### Inferences
- **Recommended stack for an offline, notarized, Swift-native launcher with Korean+English:**
  - **Primary: MLXEmbedders on mlx-swift-lm main + mlx-community text-only v2 weights.** Correct pipeline with verified parity, in-process, MIT, ~176–288 MB.
  - **Or: FluidInference Core ML on the ANE.** Fastest and lowest power, but ≤512 tokens, first-run compile, and only 4 days old.
  - **Alternative: llama.cpp XCFramework + GGUF.** Broadest ecosystem and a C API, but v2 is days old and MRL truncation is client-side.
  - **Optional external backends:** Ollama/LM Studio.
  - **Python:** only for evaluation and parity testing.
- **Ship v1 or v2?** If the team wants to ship v1 (300m) instead, any MLX build must include PR #654. llama.cpp needs a post-#16367 GGUF. Core ML/ONNX ports already include the Dense layers.

### Gaps
- The mlx-embeddings license is shown only as "Other" by GitHub; the LICENSE text was not read.
- LM Studio desktop app licensing and redistribution terms were not checked; only the MIT `lms` CLI repo was.
