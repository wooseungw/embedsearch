# EmbeddingGemma 2 (google/embeddinggemma-2) and EmbeddingGemma-300m (v1) as the embedding model for an offline Korean+English semantic-search launcher on Apple Silicon

Research date: 2026-10-13. "v2" means `google/embeddinggemma-2`; "v1" means `google/embeddinggemma-300m`. Several numbers below come from my own pulls of Hugging Face (HF) API metadata and the official MTEB results repository; those are marked "(computed from raw data)".

## 1. Does "google/embeddinggemma-2" exist? Repo ids, release date, variants, license, gating

### Takeaway
Yes. `google/embeddinggemma-2` is a real, **ungated, Apache-2.0** Hugging Face repo. It was released publicly on **6 Oct 2026**; the repo was created 14 Sep 2026. It is **one multimodal checkpoint** (740M total). Its text-only path is 270M parameters, and vision (+170M) and audio (+300M) encoders can be loaded selectively. It is not a family of separate size checkpoints. There is no `google/embeddinggemma-2-300m`. The predecessor, `google/embeddinggemma-300m`, is still gated under the Gemma Terms of Use.

### Cited Findings
- `google/embeddinggemma-2` exists. The HF API returns 200 with `gated: False`, `private: False`, `createdAt: 2026-09-14T14:53:42Z`, `lastModified: 2026-10-06`, `library_name: transformers`, `pipeline_tag: feature-extraction`, tag `license:apache-2.0`, and model type `embedding_gemma2` — [HF API](https://huggingface.co/api/models/google/embeddinggemma-2)
- `google/embeddinggemma-2-300m` does not exist publicly (the HF API returns 401, which is HF's response for a missing or private repo) — [HF API](https://huggingface.co/api/models/google/embeddinggemma-2-300m)
- The repo holds one `model.safetensors` of 1,488,915,288 bytes. The HF API reports 744,371,512 BF16 parameters; the card states "740M" — [HF API](https://huggingface.co/api/models/google/embeddinggemma-2?blobs=true)
- The card describes it as an "open multimodal embedding model built by Google DeepMind which maps text (incl. code), images, video, and audio inputs ... into a single, unified 768-dimensional vector space. The model has 740M total parameters, combining a 270M parameter text model with modular vision (170M) and audio (300M) encoders." — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- The card states the license as Apache 2.0. The license link points to ai.google.dev/gemma/docs/gemma_4_license. Deployments "must adhere to the Gemma Prohibited Use Policy" — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- Launch blog: published **Oct 06, 2026** under a "commercially permissive Apache 2.0 license", "built on the Gemma 4 architecture" and "built from the same technology as Gemini Embedding models". Weights are on Hugging Face and Kaggle; Model Garden is "coming soon" — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)
- Developer guide published Oct 6, 2026 by Maarten Grootendorst and Ian Ballantyne. Load-time configurations: Full 740M, Text+vision 440M, Text+audio 570M, Text/code-only 270M. "All configurations project into the same vector space", and "adding an encoder later does not require recomputing existing embeddings" — [Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)
- The official HF collection is `huggingface.co/collections/google/embeddinggemma-2`. The ai.google.dev docs link a v2 model card at `/gemma/docs/embeddinggemma/model_card_2` and a v1 card at `/gemma/docs/embeddinggemma/model_card` — [ai.google.dev EmbeddingGemma overview](https://ai.google.dev/gemma/docs/embeddinggemma)
- Google publishes no other v2 weight repos besides `google/embeddinggemma-2`. A search for `author=google&search=embeddinggemma` returns only `google/embeddinggemma-2`, `google/embeddinggemma-300m`, `google/embeddinggemma-300m-qat-q8_0-unquantized` and `google/embeddinggemma-300m-qat-q4_0-unquantized`. Google has **not** published QAT "unquantized" checkpoints for v2 on HF — [HF API search](https://huggingface.co/api/models?author=google&search=embeddinggemma)
- v1 `google/embeddinggemma-300m`: created 2025-07-17, `gated: manual`, `license:gemma`, 302,863,104 F32 params in safetensors, tag `arxiv:2509.20354` — [HF API v1](https://huggingface.co/api/models/google/embeddinggemma-300m)
- v1 was announced Sept 4, 2025 with 308M parameters ("roughly 100M model parameters and 200M embedding parameters") — [Google Developers Blog, Introducing EmbeddingGemma](https://developers.googleblog.com/en/introducing-embeddinggemma/)
- v1 had "more than 20 million downloads" at the v2 launch — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)
- A gating problem has been reported on v1: "Cannot use EmbeddingGemma, License Redirects to Kaggle 404" (open discussion #48) — [HF discussion list v1](https://huggingface.co/google/embeddinggemma-300m/discussions/48)
- Name collision: "Gemini Embedding 2" (arXiv 2605.27295) is a different Google model, an API-served Gemini embedder. It is not EmbeddingGemma 2 — [arXiv 2605.27295](https://arxiv.org/pdf/2605.27295)

### Inferences
- For an offline Mac launcher, the right identifier is `google/embeddinggemma-2`. Loading it text-only gives the "270M" model. A user who says "embeddinggemma-2" almost certainly means this repo, and the size variants (270m/440m/570m/740m) are load-time encoder selections of one checkpoint. LiteRT and Ollama package them as separate files or tags.
- The license change from Gemma Terms (gated, v1) to Apache-2.0 (ungated, v2) matters for a distributable app: v2 weights can be bundled or downloaded without an HF login or license click-through. The card still references the Gemma Prohibited Use Policy, so legal review should confirm how that policy combines with Apache-2.0.

### Gaps
- The exact Kaggle model slug for v2 was not verified; the blog only says "Kaggle".
- The full text of the v2 ai.google.dev card (`model_card_2`) was not fetched separately. The HF card was used as the canonical source.

## 2. Architecture & specs

### Takeaway
v2 is a Gemma-4-derived bidirectional encoder: 24 layers, d_model 512, a 262,144-token vocabulary, mean pooling and a 512→768 projection. It has an **8,192-token context** (v1: 2,048) and a 768-d output with MRL truncation to 512/256/128. The text path has 270M parameters (130M transformer + 140M embedding table). Language support is stated as "100+ languages" with no per-language list, so Korean is not explicitly guaranteed in the docs. Section 5 shows Korean results are strong in practice for v1.

### Cited Findings
- v2 model overview table: Backbone 130M, Embedder 140M, Vision 170M, Audio 300M. 24 layers, model dim 512, hidden (FFN) dim 2048, sliding window "1024 tokens", vocab 262,144, 4 heads, KV heads (local/global) 2/1, local:global attention ratio 5:1, GQA/MQA, gated FFN with GELU, mean pooling, projection 512→768. Context window 8,192 tokens, native output dim 768, MRL dims 128/256/512 — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- `config.json` gives `architectures: EmbeddingGemma2Model`, `text_config.model_type: embedding_gemma2_text`, `hidden_size 512`, `num_hidden_layers 24`, `embedding_dim 768`, `head_dim 256` (global layers 5/11/17/23 use head_dim 512 and 1 KV head), `vocab_size 262144`, `max_position_embeddings 262144`, `rope_theta` 1e6 (global) / 1e4 (sliding), and `dtype bfloat16`. It sets **`sliding_window: 512`**, which **conflicts** with the card's "1024 tokens". Vision is `gemma4_vision` (16 layers, hidden 768, patch 16, default 280 soft tokens/image). Audio is `gemma4_audio` (12 layers, hidden 1024) — [config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json)
- Dev guide: the text and code base is "an adapted Gemma 4 decoder with an 8,192-token context window", and it "shares the same text tokenizer and audio encoder architecture" with Gemma 4 — [Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)
- The 8K context is "4x larger than EmbeddingGemma 1". It covers up to 5.5 min of audio, 29 images or 58 video frames — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)
- Per-modality token costs in the shared 8,192 window: text 1 token/subword. An image costs 280 tokens by default (configurable 70–1,120 "soft tokens"). Video costs 140 tokens/frame at 1 fps by default. Audio costs 25 tokens/s and should be 16 kHz mono — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- Languages: "understands 100+ languages". Pre-training data includes "content in over 140 languages" with a data cutoff of January 2025. The card warns the model "may not exhibit equal performance across languages" — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- v1 specs: 300M parameters, "built from Gemma 3, with T5Gemma initialization", max input 2K, output 768 with MRL 512/256/128, trained on ~320B tokens covering "100+ spoken languages" — [ai.google.dev v1 model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)
- Google has declined to publish a language list for v1: "an exact, exhaustive list of all 100+ languages is not available", and "language support isn't binary" — [HF discussion #34 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/34)
- QAT for v1: Google released `google/embeddinggemma-300m-qat-q4_0-unquantized` and `-qat-q8_0-unquantized`. The v1 card reports QAT scores: Q8_0 60.93, Q4_0 60.62 and mixed precision 60.69 MTEB(Multilingual v2) Mean(Task), versus 61.15 full precision — [ai.google.dev v1 model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card); [HF API search](https://huggingface.co/api/models?author=google&search=embeddinggemma)
- QAT for v2: Google publishes QAT only inside the LiteRT-LM packages. The text transformer and embeddings are "int4 per-channel (QAT)", vision "int8 per-channel (QAT)", and audio "mixed int2/int4/int8 per-channel (QAT)" — [litert-community/embeddinggemma-2-text-270m-litert-lm](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm)

### Inferences
- About half of the 270M text-path parameters (~134M = 262,144 × 512) are the token-embedding lookup table. Actual compute per token is only about 130M parameters, so latency is low even though download size looks like a 270M model.
- `max_position_embeddings = 262144` is an architectural ceiling, not the trained context. The supported limit is 8,192 tokens, so apps should cap `max_seq_length` at 8192 or lower (see section 8).
- Korean is not named in either card. Korean-specific evidence must come from benchmarks (section 5).

### Gaps
- Whether the true sliding window is 512 (config) or 1024 (card) is unresolved. It only matters for inputs longer than 512 tokens.
- I found no published v2 training-token count or v2 training recipe (see section 4).

## 3. Required usage conventions (prompts, normalization, similarity, dtype, library versions)

### Takeaway
Use asymmetric prefixes: `task: search result | query: {q}` for queries and `title: {title|none} | text: {doc}` for documents. Use cosine similarity on L2-normalized vectors, and re-normalize after MRL truncation. Run in **bf16 or fp32, never fp16**. v2 needs **sentence-transformers ≥ 6.1.0** and a transformers build that supports `embedding_gemma2`. The repo was saved with `transformers 5.18.0.dev0`.

### Cited Findings
- Prefix table (v2): SearchQuery `task: search result | query: {query}` paired with document `title: {title} | text: {content}`. QuestionAnswering is `task: question answering | query:`, FactChecking `task: fact checking | query:`, CodeRetrieval `task: code retrieval | query:` (doc `title: {title or filename} | text: {code}`). Symmetric prefixes: Classification `task: classification | query:`, Clustering `task: clustering | query:`, SentenceSimilarity `task: sentence similarity | query:`. "Using the right prefix improves quality; omitting it still works but reduces precision." Prefixes apply to text only — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- "`prompt_name="Document"` applies `title: none`; titled documents must still be formatted manually" — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- `config_sentence_transformers.json` defines prompts including `query` = `task: search result | query: `, `document` = `title: none | text: `, `Retrieval-query`, `Retrieval-document`, `SearchQuery`, `Document`, `STS`, `BitextMining` = `task: search result | query: `, and others. It sets `default_prompt_name: null`, which means **no prefix is applied unless you pass `prompt_name`**. It sets `similarity_fn_name: cosine`. It requires `sentence-transformers >=6.1.0` because "Older versions ignore the order of multimodal dict inputs and cannot put several images or texts into a single embedding". Saved with pytorch 2.14.0, sentence_transformers 6.1.0, transformers 5.18.0.dev0 — [config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json)
- The pipeline modules are Transformer → Pooling (mean, `include_prompt: true`, dim 768) → Normalize, so sentence-transformers output is already unit-length — [modules.json](https://huggingface.co/google/embeddinggemma-2/blob/main/modules.json); [1_Pooling/config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/1_Pooling/config.json)
- On MRL: "Re-normalize after truncating ... Skipping this step degrades ranking quality silently". "Queries and documents must share a dimension." Use `model.encode(..., truncate_dim=..., normalize_embeddings=True)` — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- On dtype: "Run inference in `bfloat16` or `float32`. Do not use `float16`." The model's "activation range exceeds the dynamic range of float16. In float16 the model returns NaN or silently degraded embeddings rather than raising an error". bf16 is the recommended default where hardware supports it; "Use float32 elsewhere, including on most CPUs" — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- The v1 caveat is the same: "EmbeddingGemma activations do not support `fp16` or its derivatives. Please use `fp32`, `q8`, or `q4`" — [onnx-community/embeddinggemma-300m-ONNX](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX)
- Text-only loading in sentence-transformers uses `SentenceTransformer("google/embeddinggemma-2", config_kwargs={"vision_config": None, "audio_config": None})`. "Disabled encoders are never loaded, so the savings apply to both weights and peak memory." Install with `pip install -U sentence-transformers[image,audio,video] transformers` — [Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)
- Transformers version for v2: the MLX conversion card says multimodal preprocessing "requires a Transformers build that exposes `EmbeddingGemma2Processor` ... stock PyPI Transformers 5.18.0 does not yet expose this processor". The text-only path uses `AutoTokenizer` and does not need it. It also advises "Keep non-quantized weights and activations in BF16; do not cast this model to float16" — [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)
- v1 library requirement at launch: `pip install git+https://github.com/huggingface/transformers@v4.56.0-Embedding-Gemma-preview` and `sentence-transformers>=5.0.0` — [HF blog, Sept 4 2025](https://huggingface.co/blog/embeddinggemma)
- v1 prefix formats are the same as v2's (`task: search result | query: {content}`; `title: {title | "none"} | text: {content}` and so on) — [ai.google.dev v1 model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)

### Inferences
- For a Korean/English launcher, keep the English prefix strings exactly as given (`task: search result | query: 한국어 질의`). The prefixes are trained tokens and should not be translated. File or app names make natural `title:` values for documents, but test this against `title: none` (see the issue in section 8).
- On Apple Silicon with PyTorch MPS, bf16 support depends on the torch/macOS version. fp32 is the safe default; for a launcher, prefer Core ML, LiteRT, MLX bf16 or GGUF runtimes over PyTorch (sections 6–7).

### Gaps
- No primary source gives the first *stable* PyPI transformers release with `EmbeddingGemma2Model` text support. Only "5.18.0.dev0 used" and "PyPI 5.18.0 lacks the processor" are documented.
- I found no ablation quantifying how much quality is lost when prefixes are omitted on v2.

## 4. Published papers / technical reports / model cards

### Takeaway
There is one paper, for v1: **arXiv 2509.20354**, "EmbeddingGemma: Powerful and Lightweight Text Representations" (89 authors; v1 24 Sep 2025, v3 1 Nov 2025). **No arXiv paper or technical report for EmbeddingGemma 2 was found** as of 2026-10-13. v2 is documented only by the model card, the launch blog and the developer guide.

### Cited Findings
- arXiv 2509.20354. Authors (89 total) start with Henrique Schechter Vera, Sahil Dua, Biao Zhang, Daniel Salz, Ryan Mullins, Sindhu Raghuram Panyam, Sara Smoot, Iftekhar Naim, Joe Zou, Feiyang Chen and others. Submitted v1 24 Sep 2025, v2 28 Sep 2025, v3 1 Nov 2025. The model is described as "based on the Gemma 3 language model family" — [arXiv abs](https://arxiv.org/abs/2509.20354)
- Training techniques in the paper:
  - **Encoder-decoder initialization.** Gemma 3 is adapted to an encoder-decoder model following T5Gemma (UL2), and EmbeddingGemma is initialized "from the encoder of this encoder-decoder model".
  - **Geometric embedding distillation** from Gemini Embedding, using embedding matching on queries, passages and hard negatives.
  - **Spread-out regularizer**, based on a global orthogonal regularizer.
  - **Model souping**: "an unweighted average of checkpoints" from Bayesian-optimized data mixtures.
  - Evaluations are run in bfloat16. Most tasks use 512 tokens, rising to 1024/2048 for long tasks.

  — [arXiv HTML v3](https://arxiv.org/html/2509.20354v3)
- The abstract claims state-of-the-art MTEB results among models under 500M parameters, a lead that "persists when quantizing model weights or truncating embedding outputs" — [arXiv abs](https://arxiv.org/abs/2509.20354)
- No v2 report: a search found only the v1 paper and the developer guide, plus the unrelated "Gemini Embedding 2" (arXiv 2605.27295). The launch blog has "no paper or technical report link" — [search-derived: Google Developers Blog guide](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/); [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2); [HF model card, no arxiv tag](https://huggingface.co/api/models/google/embeddinggemma-2)

### Inferences
- The v2 card does not say whether v2's text path reuses the v1 recipe (T5Gemma-style encoder initialization, Gemini-Embedding distillation). The "built from the same technology as Gemini Embedding models" line suggests distillation lineage, but this is unconfirmed.

### Gaps
- There is no v2 paper, so no ablations, training-data mix or per-language breakdown exist for v2.

## 5. Benchmarks (MMTEB, English, code, Korean) and comparison with alternatives

### Takeaway
On **text**, v2 is essentially **equal to v1**: MTEB(Multilingual v2) 61.36 vs 61.15, and MTEB(eng v2) 68.46 for v2 vs 69.67 for v1, so slightly lower on English. The big gain is **code** (78.68 vs 68.76), along with multimodality and an 8K context. By 2026, sub-1B competitors post higher MMTEB means: harrier-oss-v1-270m reports 66.5 (MIT), jina-v5-text-nano 65.5 (CC-BY-NC), and Qwen3-Embedding-0.6B 64.34 (Apache-2.0). Their dims, licenses and modality support differ. For **Korean**, v1 has the **highest Belebele Korean and Korean↔English cross-lingual retrieval scores among the small models compared**. v1 and v2 lack official scores on the main Korean retrieval suite, MTEB(kor, v2).

### Cited Findings
**EmbeddingGemma v2 vs v1 (official):**
- v2 at 768d: MTEB(multilingual, v2) Mean(Task) **61.36** (v1 61.15), MTEB(code, v1) **78.68** (v1 68.76), MIEB lite 64.64, MMEB v2 Image 57.28, VisDoc 67.84, Video 50.67, MSEB retrieval 69.54, MAEB 49.39 — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- v2 MRL table:

  | Dims | MTEB(multi, v2) | MTEB(eng, v2) | MTEB(code) |
  | --- | --- | --- | --- |
  | 768 | 61.36 | 68.46 | 78.68 |
  | 512 | 61.17 | 68.41 | 77.24 |
  | 256 | 60.41 | 67.78 | 76.18 |
  | 128 | 57.89 | 65.68 | 71.41 |

  "Quality is close to lossless down to 256 dimensions" — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- v1 at 768d: MTEB(Multilingual v2) 61.15 / 54.31 (Task/TaskType), MTEB(Eng v2) 69.67 / 65.11, Code 68.76. At 256d: 59.68 / 68.37 / 66.74. At 128d: 58.23 / 66.66 / 62.96 — [ai.google.dev v1 model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)
- A Google staff reply confirms "general text performance remains consistent with version 1". Version 2's improvements are code (~14%) and multimodality — [HF discussion #5 (v2)](https://huggingface.co/google/embeddinggemma-2/discussions/5)
- Independent check: hotchpotch (author of HAKARI-Bench, 550 multilingual text-retrieval tasks) reports v1 and v2 "achieved very similar overall scores", with v2 improving on NanoCoIR (code). The author's view is that the 2K→8K context is the main text-only reason to upgrade — [HF discussion #5 (v2)](https://huggingface.co/google/embeddinggemma-2/discussions/5)

**Competitor comparison (EmbeddingGemma paper, Table 5, MTEB Mean(Task)):**
- MTEB(Multi, v2) / MTEB(Eng, v2) / MTEB(Code):
  - EmbeddingGemma 308M: 61.15 / 69.67 / 68.14
  - Qwen3-Embedding-0.6B (595M): 64.34 / 70.70 / 74.57
  - mE5-large-instruct (560M): 63.22 / 65.53 / 60.55
  - BGE-M3 (568M): 59.56 / – / –
  - jina-embeddings-v3 (572M): 58.37 / – / 58.03
  - GTE-multilingual-base (305M): 58.24 / – / 55.33

  Table 6 (sub-500M, MTEB(Multi, v2) Mean(Task)): multilingual-e5-base 278M 57.0; snowflake-arctic-embed-m-v2.0 305M 53.7; granite-embedding-278m-multilingual 53.7; KaLM mini-v1 494M 57.0 — [arXiv HTML v3](https://arxiv.org/html/2509.20354v3)

**2026 sub-1B releases (vendor model cards):**
- **microsoft/harrier-oss-v1-270m** (created 2026-03-30): 270M params, 640 dims, 32,768 tokens, "MTEB v2 Score" **66.5**, MIT. The 0.6b version has 1,024 dims and scores 69.0. Queries need an instruction prefix (`Instruct: ...\nQuery: `) and documents need none. Korean is in its language list — [HF card](https://huggingface.co/microsoft/harrier-oss-v1-270m); [HF API](https://huggingface.co/api/models/microsoft/harrier-oss-v1-270m)
- **jinaai/jina-embeddings-v5-text-nano**: 239M (EuroBERT-210M base), 768 dims (MRL 32–768), 8,192 context, MMTEB **65.5**, MTEB Eng v2 71.0, **CC BY-NC 4.0** (non-commercial). **jina-embeddings-v5-text-small** (released Feb 18, 2026): 677M (Qwen3-0.6B-Base), 1,024 dims, 32,768 context, MMTEB 67.7, CC BY-NC 4.0 — [jina v5 nano](https://huggingface.co/jinaai/jina-embeddings-v5-text-nano); [jina v5 small](https://huggingface.co/jinaai/jina-embeddings-v5-text-small)
- **ibm-granite/granite-embedding-311m-multilingual-r2** (2026-04-20): 311M, 768 dims (MRL 768/512/384/256/128), 32,768 context, 200+ languages, Apache-2.0. It scores 65.2 on Multilingual MTEB **Retrieval (18 tasks)**, a retrieval-only average that is not comparable to full MMTEB. The 97M R2 version has 384 dims and scores 60.3 on the same retrieval average — [granite 311m R2](https://huggingface.co/ibm-granite/granite-embedding-311m-multilingual-r2); [granite 97m R2](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2)
- **LiquidAI/LFM2.5-Embedding-350M** (2026-05-05): ~354M, 1,024-d CLS vector, `max_seq_length 512`, 11 languages including Korean, **LFM Open License v1.0**. Prefixes are `query: ` and `document: `. On its own multilingual retrieval table (exact benchmark names were not captured), Korean scores were 0.563 vs 0.530 for Qwen3-Embedding-0.6B — [HF card](https://huggingface.co/LiquidAI/LFM2.5-Embedding-350M)
- **Qwen/Qwen3-Embedding-0.6B**: 0.6B, 28 layers, 32K context, 1,024 dims with MRL, instruction-aware, Apache-2.0 — [HF card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)

**Comparison table** (MMTEB = MTEB(Multilingual, v2) Mean(Task) unless noted):

| Model | Params | Dims (MRL) | Context | MMTEB | License | Source |
| --- | --- | --- | --- | --- | --- | --- |
| google/embeddinggemma-2 | 740M total / **270M text** | 768 (512/256/128) | 8,192 | **61.36** | Apache-2.0 | [card](https://huggingface.co/google/embeddinggemma-2) |
| google/embeddinggemma-300m (v1) | 308M | 768 (512/256/128) | 2,048 | 61.15 | Gemma Terms (gated) | [v1 card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card) |
| Qwen/Qwen3-Embedding-0.6B | 595M | 1024 (MRL) | 32K | 64.34 | Apache-2.0 | [paper T5](https://arxiv.org/html/2509.20354v3), [card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) |
| microsoft/harrier-oss-v1-270m | 270M | 640 | 32,768 | 66.5 (vendor, "MTEB v2") | MIT | [card](https://huggingface.co/microsoft/harrier-oss-v1-270m) |
| microsoft/harrier-oss-v1-0.6b | 0.6B | 1024 | 32,768 | 69.0 (vendor) | MIT | [card](https://huggingface.co/microsoft/harrier-oss-v1-270m) |
| jinaai/jina-embeddings-v5-text-nano | 239M | 768 (32–768) | 8,192 | 65.5 (vendor) | CC BY-NC 4.0 | [card](https://huggingface.co/jinaai/jina-embeddings-v5-text-nano) |
| jinaai/jina-embeddings-v5-text-small | 677M | 1024 (32–1024) | 32,768 | 67.7 (vendor) | CC BY-NC 4.0 | [card](https://huggingface.co/jinaai/jina-embeddings-v5-text-small) |
| intfloat/multilingual-e5-large-instruct | 560M | 1024 (not re-verified) | not re-verified | 63.22 | not re-verified | [paper T5](https://arxiv.org/html/2509.20354v3) |
| intfloat/multilingual-e5-base | 278M | – | – | 57.0 | – | [paper T6](https://arxiv.org/html/2509.20354v3) |
| BAAI/bge-m3 | 568M | 1024 (not re-verified) | not re-verified | 59.56 | not re-verified | [paper T5](https://arxiv.org/html/2509.20354v3) |
| jinaai/jina-embeddings-v3 | 572M | – | – | 58.37 | – | [paper T5](https://arxiv.org/html/2509.20354v3) |
| Alibaba gte-multilingual-base | 305M | – | – | 58.24 | – | [paper T5](https://arxiv.org/html/2509.20354v3) |
| Snowflake/snowflake-arctic-embed-m-v2.0 | 305M | – | – | 53.7 | – | [paper T6](https://arxiv.org/html/2509.20354v3) |
| ibm-granite/granite-embedding-278m-multilingual (R1) | 278M | – | – | 53.7 | – | [paper T6](https://arxiv.org/html/2509.20354v3) |
| ibm-granite/granite-embedding-311m-multilingual-r2 | 311M | 768 (768–128) | 32,768 | n/a (ML Retrieval-18: 65.2) | Apache-2.0 | [card](https://huggingface.co/ibm-granite/granite-embedding-311m-multilingual-r2) |
| LiquidAI/LFM2.5-Embedding-350M | 354M | 1024 | 512 | not reported | LFM Open v1.0 | [card](https://huggingface.co/LiquidAI/LFM2.5-Embedding-350M) |

**Korean-specific evidence:**
- MTEB(kor, v2) Retrieval, nine tasks (AutoRAG, PubHealthQA, Ko-StrategyQA, LawIRKo, SQuADKorV1, Belebele ko-ko, MrTidy, MLDR, MIRACL), average nDCG@10:
  - nlpai-lab/KURE-v2 (154M, ColBERT multi-vector, Apache-2.0): **0.8160**
  - Qwen3-Embedding-8B: 0.7826
  - Qwen3-Embedding-4B: 0.7737
  - dragonkue/snowflake-arctic-embed-l-v2.0-ko (568M): 0.7653
  - KURE-v1 (568M): 0.7616
  - dragonkue/BGE-m3-ko: 0.7547
  - BAAI/bge-m3: 0.7509
  - KoE5: 0.7337

  **EmbeddingGemma (v1 or v2) is not listed** in that table — [nlpai-lab/KURE-v2 card](https://huggingface.co/nlpai-lab/KURE-v2)
- The official MTEB results repo has **no Korean MTEB(kor) retrieval-suite results for embeddinggemma-300m** (no AutoRAG, Ko-StrategyQA, MIRACL-ko and so on) and **no results directory at all for google__embeddinggemma-2** (computed from raw data) — [results/google__embeddinggemma-300m](https://github.com/embeddings-benchmark/results/tree/main/results/google__embeddinggemma-300m); [GitHub API 404 for google__embeddinggemma-2](https://api.github.com/repos/embeddings-benchmark/results/contents/results/google__embeddinggemma-2)
- Korean-only MMTEB subtasks that do exist for v1, compared on the same tasks (computed from raw data, main_score):

  | Model | Belebele ko-ko (nDCG@10) | STS17 ko-ko | PawsX ko (test) | SIB200 clustering ko |
  | --- | --- | --- | --- | --- |
  | embeddinggemma-300m | **0.9414** | 0.8155 | 0.5329 | 0.4509 |
  | Qwen3-Embedding-0.6B | 0.9222 | 0.8536 | 0.5512 | 0.5226 |
  | harrier-oss-v1-270m | 0.8388 | 0.8029 | 0.5066 | 0.5442 |
  | harrier-oss-v1-0.6b | 0.9032 | 0.8222 | 0.5353 | 0.5638 |
  | multilingual-e5-large-instruct | 0.9361 | 0.8431 | 0.5174 | 0.5612 |
  | multilingual-e5-small | 0.9053 | 0.7673 | 0.5138 | 0.3998 |
  | bge-m3 | 0.9315 | 0.8143 | 0.5233 | 0.3762 |
  | granite-embedding-311m-multilingual-r2 | 0.8857 | 0.7731 | 0.5499 | 0.4502 |
  | jina-embeddings-v5-text-nano | 0.9350 | **0.8832** | 0.5493 | 0.5443 |
  | snowflake-arctic-embed-m-v2.0 | 0.8746 | – | 0.5118 | 0.3162 |

  Source files: `results/<model>/<rev>/{BelebeleRetrieval,STS17,PawsXPairClassification,SIB200ClusteringS2S}.json` — [MTEB results repo](https://github.com/embeddings-benchmark/results/tree/main/results)
- Korean↔English cross-lingual retrieval on Belebele, subsets `kor_Hang-eng_Latn` / `eng_Latn-kor_Hang`, nDCG@10 (computed from raw data):
  - **embeddinggemma-300m: 0.9513 / 0.9293**
  - jina-v5-text-nano: 0.9468 / 0.9175
  - harrier-0.6b: 0.9235 / 0.8337
  - me5-large-instruct: 0.9243 / 0.8622
  - Qwen3-0.6B: 0.913 / 0.8618
  - bge-m3: 0.9032 / 0.8832
  - granite-311m-r2: 0.8887 / 0.827
  - harrier-270m: 0.8519 / 0.7752
  - arctic-m-v2.0: 0.8122 / 0.7054
  - me5-small: 0.7778 / 0.6833

  — [BelebeleRetrieval.json for embeddinggemma-300m](https://github.com/embeddings-benchmark/results/blob/main/results/google__embeddinggemma-300m/64614b0b8b64f0c6c1e52b07e4e9a4e8fe4d2da2/BelebeleRetrieval.json) (other models: same path pattern)
- EmbeddingGemma paper, per-language XOR-Retrieve, Korean: R@5kt 83.86, R@2kt 78.25. Overall XOR-Retrieve 84.14 vs Gemini Embedding 90.42 and text-embedding-3-large 68.76 — [arXiv HTML v3](https://arxiv.org/html/2509.20354v3)
- Qwen3-Embedding-0.6B's Korean retrieval scores from the results repo (computed from raw data, nDCG@10): AutoRAG 0.8292, PublicHealthQA-ko 0.8049, Ko-StrategyQA 0.7655, LawIRKo 0.7247, SQuADKorV1 0.8503. bge-m3: AutoRAG 0.8301, Ko-StrategyQA 0.7941, LawIRKo 0.7174, SQuADKorV1 0.9038 — [results repo Qwen3-0.6B](https://github.com/embeddings-benchmark/results/tree/main/results/Qwen__Qwen3-Embedding-0.6B); [bge-m3](https://github.com/embeddings-benchmark/results/tree/main/results/BAAI__bge-m3)
- A third-party Korean fine-tune of v1 exists: `deepmodal/embeddinggemma-300m-ko` (created 2025-10-27; not evaluated here) — [HF API search](https://huggingface.co/api/models?search=embeddinggemma)

### Inferences
- For a Korean+English launcher, the most relevant public signal is the Belebele **cross-lingual** subsets: a Korean query against English content, and the reverse. There v1 leads every small open model checked. v2 claims parity with v1 on multilingual text, so similar behavior is likely but **unverified for v2**.
- On aggregate MMTEB, v2 (61.36) is now mid-pack among 2026 sub-1B models. harrier-270m (66.5, MIT, 640-d) and jina-v5-nano (65.5, non-commercial) score higher on paper. harrier-270m is weaker than EmbeddingGemma on Belebele Korean (0.8388 vs 0.9414) and on cross-lingual ko↔en. Korean retrieval quality and MMTEB averages diverge, so a small in-house Korean eval set is strongly advisable before choosing.
- If the launcher is **text-only**, v2's advantages over v1 are the 8K context, much better code/filename search (+~10 MTEB-Code points) and the Apache-2.0 license. Raw Korean/English prose retrieval should be about the same as v1.
- Specialized Korean models such as KURE-v2 (ColBERT, 154M, MTEB(kor) 0.816) clearly beat general dense models on Korean-only retrieval. They need multi-vector indexing (PLAID/MaxSim), which complicates a lightweight launcher, and are bilingual ko/en only.

### Gaps
- No official MTEB(kor, v2) retrieval average exists for EmbeddingGemma v1 or v2, and no Ko-StrategyQA, MIRACL-ko or AutoRAG scores for either. No KorMTEB numbers for v2 were found.
- No independent full-MMTEB rerun of v2 was found; the 61.36 is Google's own figure.
- nomic-embed-text-v1.5/v2-moe, jina-embeddings-v4 and granite R2's full MMTEB means were not verified in this pass. Licenses and contexts for me5-large-instruct, bge-m3 and jina-v3 are from memory and marked "not re-verified".
- Belebele subset naming (which side is query vs passage) follows mteb convention and was not re-checked against mteb source.

## 6. Officially provided and community converted formats (exact repo ids)

### Takeaway
v2 had broad day-one ecosystem support: an official HF repo, ONNX/Transformers.js (onnx-community), GGUF (ggml-org, unsloth), MLX (mlx-community, via **mlx-vlm**), LiteRT-LM (litert-community, QAT int4), and an Ollama `embeddinggemma-2` tag family. Core ML exists only as a **third-party** conversion (FluidInference) that runs the text path 100% on the Apple Neural Engine.

### Cited Findings
**v2 (`google/embeddinggemma-2`):**
- **ONNX / Transformers.js**: `onnx-community/embeddinggemma-2-ONNX` (created 2026-10-04, `library_name: transformers.js`, Apache-2.0). Text model sizes: fp32 1085 MB, fp16 543 MB, q8 314 MB, q4 175 MB, q4f16 157 MB. Worst-case cosine to fp32: fp16 0.9998, q8 0.9997, q4 0.975 (text 0.988). Recommended "q4 on WebGPU"; use q8 or fp16 when quality matters. Text-only use is done by removing the vision/audio configs before loading. Install with `npm i @huggingface/transformers` — [HF repo](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX)
- **GGUF**:
  - `ggml-org/embeddinggemma-2-GGUF`: `embeddinggemma-2-BF16.gguf` 558 MB and `-Q8_0.gguf` 310 MB, plus `mmproj-embeddinggemma-2-{BF16,Q8_0}.gguf` (982/555 MB) for vision/audio. Run with `llama serve -hf ggml-org/embeddinggemma-2-GGUF`; "automatically converted".
  - `unsloth/embeddinggemma-2-GGUF`: BF16/F16 558 MB, Q8_0 310 MB, UD-Q6_K_XL 249 MB, UD-Q5_K_XL 210 MB, UD-Q4_K_XL 176 MB, plus mmproj files.

  — [ggml-org](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF); [unsloth](https://huggingface.co/unsloth/embeddinggemma-2-GGUF); [HF API blobs](https://huggingface.co/api/models/unsloth/embeddinggemma-2-GGUF?blobs=true)
- **MLX**: `mlx-community/embeddinggemma-2-bf16` (1.489 GB), plus `-8bit` (1.234 GB), `-6bit`, `-5bit`, `-4bit` (1.098 GB), `-mxfp8`, `-mxfp4` and `-nvfp4`, all tagged `mlx-vlm`. They require `pip install "git+https://github.com/Blaizzy/mlx-vlm.git@3d87e884..."` (branch `pc/embeddinggemma-2`), `mlx>=0.32.3` and `transformers>=5.18.0`. Load with `mlx_vlm.embedding_loader.load_embedding_model`. Conversion checks showed minimum cosine vs PyTorch FP32 of 0.999937 (text). The conversions retain **all** encoders — [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16); [HF API search](https://huggingface.co/api/models?search=embeddinggemma)
- **LiteRT-LM** (QAT int4, official Google AI Edge community org):
  - `litert-community/embeddinggemma-2-text-270m-litert-lm`: 165 MB CPU/GPU file
  - `litert-community/embeddinggemma-2-text-vision-440m-litert-lm`: 388 MB
  - `litert-community/embeddinggemma-2-740m-litert-lm`: 485 MB

  There are also NPU-specific files for Tensor G5/G6, Qualcomm, MediaTek and Intel PTL. Supported text input sizes are 128/256/512/1024/2048/8192 tokens and output sizes 128/256/512/768. Demo apps exist for Android, iOS, macOS ("Foresight") and Web — [LiteRT text-270m card](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm)
- **Core ML (third-party)**: `FluidInference/embeddinggemma-2-coreml` (created 2026-10-09).
  - Files: `EmbeddingGemma2Text.mlpackage` (fp16, 7 fixed-shape functions `embed_32`…`embed_512` and `pack_256`; 271 MB), `embeddings.bf16` token table (256 MB), and audio/vision mlpackages.
  - Requires macOS 15 / iOS 18. Inputs over 512 tokens must be truncated. The first load compiles for the ANE, which takes "several minutes once".
  - A Swift implementation is provided in `FluidInference/FluidUse` (`EmbeddingGemma2Manager`).

  — [HF repo](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- **Ollama**: `ollama pull embeddinggemma-2`. Tags:
  - `embeddinggemma-2:270m` (378 MB, Text)
  - `:440m` (714 MB, Text+Image)
  - `:570m` (990 MB)
  - `:740m` = `:latest` (1.3 GB)
  - quantization variants `:270m-bf16-text`, `:270m-mxfp8-text` and `:270m-nvfp4-text`, with equivalents for 440m/570m/740m

  The page lists every tag with a "256K context window" — [Ollama library](https://ollama.com/library/embeddinggemma-2); [tags](https://ollama.com/library/embeddinggemma-2/tags)
- The official blog lists MediaPipe (Decision Task API), LiteRT, transformers.js, WebGPU, transformers, sentence-transformers, MLX, vLLM, llama.cpp (GGUF), SGLang, Ollama, LM Studio, Qdrant and Unsloth. It does **not** mention ONNX or Core ML — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)

**v1 (`google/embeddinggemma-300m`) converted repos:**
- `onnx-community/embeddinggemma-300m-ONNX`
- `ggml-org/embeddinggemma-300M-GGUF`, `ggml-org/embeddinggemma-300m-qat-q8_0-GGUF`, `ggml-org/embeddinggemma-300M-qat-q4_0-GGUF`
- `unsloth/embeddinggemma-300m-GGUF`
- `lmstudio-community/embeddinggemma-300m-qat-GGUF`
- `mlx-community/embeddinggemma-300m-{bf16,8bit,6bit,5bit,4bit}` and `mlx-community/embeddinggemma-300m-qat-q{4,8}_0-unquantized-bf16`
- `litert-community/embeddinggemma-300m`
- Google's QAT checkpoints `google/embeddinggemma-300m-qat-q4_0-unquantized` and `-qat-q8_0-unquantized`

— [HF API search](https://huggingface.co/api/models?search=embeddinggemma&sort=downloads)
- Ollama v1 tag: `embeddinggemma` / `embeddinggemma:300m` (622 MB, 2K context, Text) — [Ollama v1](https://ollama.com/library/embeddinggemma)

### Inferences
- **For a Mac launcher, the text-only footprints are:**
  - LiteRT text-270m: 165 MB
  - Core ML text: ~271 MB package + 256 MB table
  - GGUF Q8_0: 310 MB; UD-Q4_K_XL: 176 MB
  - ONNX q4: 175 MB; q8: 314 MB
  - Ollama `:270m`: 378 MB

  The current MLX conversions bundle all encoders (≥1.1 GB even at 4-bit), which is a poor fit for a text-only launcher unless re-converted text-only.
- GGUF text models load without the mmproj file, which is needed only for image/audio. That makes llama.cpp-family runtimes a natural text-only path. Exact llama.cpp build requirements were not documented.

### Gaps
- No `lmstudio-community/embeddinggemma-2-GGUF` repo was found (API error). LM Studio support is claimed in the blog, but its exact repo id is unverified.
- No Google-official Core ML conversion. No minimum llama.cpp build or Ollama version for v2 was published in the sources reviewed.
- No `mlx-embeddings` (Blaizzy) support statement for v2 was found; the community MLX path uses `mlx-vlm`.

## 7. Reported on-device latency/memory (Google figures and Apple Silicon)

### Takeaway
Google's own LiteRT-LM figures for the v2 text-270m QAT model on a **MacBook Pro M5** (128-token input) are **9.5 ms on GPU / 31.3 ms on CPU**, with **233 MB / 165 MB** memory. A third-party Core ML build reaches **2.6–27.4 ms (32–512 tokens) on the M5 Pro Neural Engine**, or ~644 short texts/s. For v1, Google cited "<15 ms (256 tokens) on EdgeTPU" and "<200 MB RAM with quantization".

### Cited Findings
- LiteRT-LM, v2 text-270m (int4 QAT), "128 text signature", average of 5 runs. Memory on macOS/iOS is measured with `task_vm_info::phys_footprint`.

  | Device | Backend | Latency | Memory |
  | --- | --- | --- | --- |
  | **MacBook Pro M5** | CPU | **31.3 ms** | 165 MB |
  | **MacBook Pro M5** | GPU | **9.5 ms** | 233 MB |
  | MacBook Pro M5 | Web GPU | 21.8 ms | – |
  | iPhone 18 Pro | CPU | 41.8 ms | 84 MB |
  | iPhone 18 Pro | GPU | 11.6 ms | 85 MB |
  | Pixel 11 Pro | TPU | 8.3 ms | 112 MB |
  | S26 Ultra | CPU | 27.1 ms | – |
  | S26 Ultra | GPU | 25.9 ms | – |
  | RTX 4090 | GPU | 7.6 ms | – |

  — [litert-community/embeddinggemma-2-text-270m-litert-lm](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm)
- Launch blog: on a Pixel 11 Pro with quantization, "as little as ~191MB active RAM" for text-only and "~567MB" for the full multimodal model. No Mac or EdgeTPU latency is given — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)
- Third-party Core ML (FluidInference) on **M5 Pro, macOS 27**:
  - 3,862/3,862 ops (100%) placed on the Neural Engine
  - Single-text latency: 32 tok 2.6 ms, 64 tok 3.2 ms, 128 tok 5.6 ms, 256 tok 11.3 ms, 512 tok 27.4 ms
  - Throughput: 644 texts/s packed (`pack_256`) or 307/s one per call
  - Cosine vs PyTorch fp32 ≥ 0.9984 (mean 0.99996 over 562 posts)
  - Demo: 5,617 functions indexed in 16 s at ~700 searches/s

  The vision encoder is faster on the GPU than the ANE (70 tokens: 14.6 ms GPU vs 37 ms ANE) — [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- Storage planning: one million 768-d bf16 vectors is ~1.5 GB, and ~250 MB at 128-d — [Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)
- v1: "<15ms embedding inference time (256 input tokens) on EdgeTPU" and "less than 200MB of RAM with quantization" — [Google Developers Blog v1](https://developers.googleblog.com/en/introducing-embeddinggemma/). This conflicts with the ai.google.dev overview's "less than 22ms on EdgeTPU" — [ai.google.dev](https://ai.google.dev/gemma/docs/embeddinggemma)

### Inferences
- Interactive launcher search embeds a single short query (<32 tokens). Expected per-query embedding cost on M-series is roughly 3–10 ms on ANE or GPU, and about 30 ms on CPU, which is well under a keystroke budget. Bulk indexing throughput (hundreds of docs/s on ANE) is the bigger design driver.
- No published figures exist for M1–M4. M5 and M5 Pro numbers should be treated as upper-end; older chips have smaller ANE and GPU budgets.

### Gaps
- No Google-published Apple Silicon numbers for v1, and none for v2 beyond the M5 LiteRT table.
- No independent M1–M4 benchmarks for v2 via MLX, llama.cpp, ONNX Runtime CoreML EP or Ollama were found.
- Core ML numbers are from a single third-party vendor and were not reproduced.

## 8. Known issues / gotchas (HF discussions, model-card warnings)

### Takeaway
The main pitfalls are:
- **fp16 NaNs / silent degradation**. The model card forbids fp16, and v1 hit NaNs on PyTorch MPS.
- **Old transformers builds using causal instead of bidirectional attention**, which caused v1's "broken model" reports.
- **Forgetting prefixes**: `default_prompt_name` is null.
- **Not re-normalizing after MRL truncation.**
- **Context confusion**: Ollama advertises 256K, but the trained context is 8K.
- **v2 text quality ≈ v1** despite the version bump.

### Cited Findings
- fp16: in "float16 the model returns NaN or silently degraded embeddings rather than raising an error" — [HF model card v2](https://huggingface.co/google/embeddinggemma-2)
- Core ML converters found activations reach ~2,000, so squaring them inside RMSNorm overflows fp16. Plain fp16 RMSNorm gave cosine 0.95 to the reference; the max-abs-rescaled version gave 0.9996 — [FluidInference Core ML](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
- v1 on Apple **MPS** returned `[nan, nan, ...]` for batches, but worked on CPU. Tom Aarsen pointed to "an issue with torch 2.8.0 and MPS", and the problem was also batch-size dependent — [HF discussion #15 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/15)
- v1 "Seems to prefer shorter content?" (24 comments). Users found poor retrieval and mismatched example outputs. Root cause per Tom Aarsen: without the required transformers version, "the model will use causal attention instead of bidirectional attention". With the right version, outputs matched the card — [HF discussion #8 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/8)
- A bidirectional mask is required via the config flag. Use a recent transformers version — [HF discussion #36 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/36)
- A batch-dependent embedding (~1% difference) was reported for sequences of 129/193/257 tokens (2^i+1) when batched with shorter ones. Google could not reproduce it — [HF discussion #28 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/28)
- The `title: … | text: …` format scored worse than a plain `{title} | {content}` on one user's data. Google's reply: use whichever "consistently improves NDCG on your dataset" — [HF discussion #35 (v1)](https://huggingface.co/google/embeddinggemma-300m/discussions/35)
- Prompts are not automatic: `default_prompt_name: null` in the sentence-transformers config. The card warns that omitting the task prefix "may lead to sub-optimal embedding quality" — [config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json); [HF model card](https://huggingface.co/google/embeddinggemma-2)
- MRL: slicing without re-normalizing "degrades ranking quality silently". At 128d, multimodal quality drops a lot (MMEB 59.01→45.65); text drops less (61.36→57.89) — [HF model card](https://huggingface.co/google/embeddinggemma-2)
- Context mismatch: Ollama lists "256K context window" for all v2 tags, which matches `max_position_embeddings: 262144` in config.json. The model card states an 8,192-token context. `tokenizer_config.json` leaves `model_max_length` unset (≈1e30), so truncation must be set explicitly — [Ollama](https://ollama.com/library/embeddinggemma-2); [config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json); [tokenizer_config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/tokenizer_config.json)
- The sliding window is 1024 per the card and 512 per config.json (unresolved discrepancy) — [HF model card](https://huggingface.co/google/embeddinggemma-2); [config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json)
- v2 is not a text upgrade: a Google reply confirms text performance is "consistent with version 1" — [HF discussion #5 (v2)](https://huggingface.co/google/embeddinggemma-2/discussions/5)
- Library churn: v2 requires sentence-transformers ≥ 6.1.0. Multimodal preprocessing needs a transformers build with `EmbeddingGemma2Processor`, absent from PyPI 5.18.0 per the MLX card. MLX support currently comes from an mlx-vlm git branch — [config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json); [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)
- Embeddings are not cross-compatible between versions: the v2 vector space is new. The v2 developer guide's compatibility claim covers only v2 encoder configurations among themselves — [Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)
- A macOS local semantic-search layer (with an MCP interface) built on v2 has been shared by the community: `github.com/Podcast72/local-knowledge-layer` — [HF discussion #6 (v2)](https://huggingface.co/google/embeddinggemma-2/discussions/6)

### Inferences
- Switching v1→v2 requires a full re-index, because v1 and v2 vectors are not comparable. This is an inference: no source states it explicitly, but they are different models with different projection heads.
- Mitigations for a Mac launcher:
  - Run bf16/fp32 or a vetted quantized runtime (LiteRT QAT, GGUF Q8_0, ONNX q8, or Core ML with rescaled RMSNorm).
  - Always pass the query/document prompt.
  - Cap input at ≤ 2,048 or 8,192 tokens, and chunk longer files.
  - L2-normalize after truncation.
  - Pin library versions.

### Gaps
- No v2-specific bug reports on fp16, MPS or tokenizer issues were found yet (the release is ~1 week old). The v2 discussions so far are mostly feature or general threads.
- No GitHub issues in llama.cpp, mlx-vlm or sentence-transformers trackers specific to v2 were reviewed; GitHub MCP was unavailable and the search budget was limited.
