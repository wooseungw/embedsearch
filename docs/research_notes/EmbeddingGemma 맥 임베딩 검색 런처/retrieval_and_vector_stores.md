# Retrieval Techniques and Embeddable Vector Search Libraries for a Local macOS Semantic Launcher (EmbeddingGemma-300M, MRL 768→128)

Research date: 2026-10-13. GitHub figures (stars, last push, latest release, license) were pulled live with the GitHub API (`gh`) on 2026-10-13. Corpus assumption: 10k–500k chunks, Apple Silicon, fully offline, mixed Korean/English short queries.

---

## Q1. Dense vs. sparse vs. hybrid retrieval (BM25 + dense fusion, RRF, SPLADE), including Korean lexical matching

### Takeaway
The evidence consistently favors **hybrid (BM25 + dense) over dense-only**, especially for entity-heavy, rare-term and out-of-domain queries, which describes launcher queries such as app names, file names and "rust async". RRF (k=60) is a good zero-training default. A tuned convex (weighted-score) combination beats RRF and needs only about 40 labelled queries. For Korean, the BM25 side needs morphological tokenization: plain whitespace/unicode61 tokenization loses roughly a third of recall.

### Cited Findings
**Hybrid vs. dense-only**
- BEIR (18 datasets, 10 systems): "BM25 is a robust baseline"; dense and sparse retrievers "often underperform other approaches" zero-shot, while re-ranking and late-interaction models do best at high compute cost. Thakur et al., NeurIPS 2021 Datasets & Benchmarks, arXiv:2104.08663. — [arXiv](https://arxiv.org/abs/2104.08663)
- EntityQuestions: on simple entity-rich questions (e.g., "Where was Arve Furset born?") "dense retrievers drastically underperform sparse methods", and generalize only to common entities. Sciavolino et al., EMNLP 2021, arXiv:2109.08535. — [arXiv](https://arxiv.org/abs/2109.08535)
- Dense retrievers "still lag behind sparse methods such as BM25 in their ability to reliably match salient phrases and rare entities", per Chen et al. (SPAR), arXiv:2110.06918. Their remedy is to add a dense lexical model that imitates BM25. — [arXiv](https://arxiv.org/abs/2110.06918)
- The DPR replication found that the original authors "under-report the effectiveness of the BM25 baseline and hence also dense–sparse hybrid retrieval results". Ma, Sun, Pradeep, Lin, arXiv:2104.05740. — [arXiv](https://arxiv.org/abs/2104.05740)
- A hybrid of semantic and lexical first-stage retrieval improves recall on a TREC collection. Kuzi et al. (Google), arXiv:2010.01195. — [arXiv](https://arxiv.org/abs/2010.01195)
- Results with modern embedding models (Anthropic, Sep 19 2024): "Embeddings+BM25 is better than embeddings on their own". Measured as top-20 retrieval failure rate (1 − recall@20): contextual embeddings cut failures by 35% (5.7%→3.7%), adding contextual BM25 cut them by 49% (→2.9%), and adding a reranker cut them by 67% (→1.9%). — [Anthropic: Contextual Retrieval](https://www.anthropic.com/news/contextual-retrieval)
- Elastic search-labs measured RRF fusion of BM25 with its learned sparse encoder (ELSER) on a BEIR subset. Average NDCG@10 rose 1.4% over ELSER alone and 18% over BM25 alone, and the fused result was "better or similar to BM25 alone for all test data sets". — [Elastic blog: hybrid retrieval](https://www.elastic.co/search-labs/blog/improving-information-retrieval-elastic-stack-hybrid)

**Fusion methods**
- RRF: score(d) = Σ_r 1/(k + r(d)) with **k = 60**, "fixed during a pilot investigation and not altered during subsequent validation". RRF "consistently yields better results than any individual system" and beats Condorcet Fuse and CombMNZ on TREC runs and LETOR 3. Cormack, Clarke, Büttcher, SIGIR 2009 (short paper, Boston). — [PDF](http://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf)
- Bruch, Gai, Ingber, "An Analysis of Fusion Functions for Hybrid Retrieval" (ACM TOIS; arXiv:2210.11934): RRF is "sensitive to its parameters". A convex combination (CC) of lexical and semantic scores "outperforms RRF in in-domain and out-of-domain settings", is largely agnostic to the normalization used, and is "sample efficient, requiring only a small set of training examples to tune its only parameter". — [arXiv](https://arxiv.org/abs/2210.11934)
- Elastic found a linear combination could outperform RRF with "approximately 40 annotated queries", but the best weight "varies significantly both across different data sets and across retrieval models". Its best RRF settings for a dense model were k=20 with top-N=1000, and the best-to-worst RRF parameter spread was only about 5%. — [Elastic blog](https://www.elastic.co/search-labs/blog/improving-information-retrieval-elastic-stack-hybrid)
- In one SQLite file, Alex Garcia (Oct 2 2024) shows three FTS5 + sqlite-vec hybrid patterns: (1) keyword-first `UNION ALL`, (2) RRF via a `FULL OUTER JOIN` of two CTEs with `coalesce(1.0/(:rrf_k + fts_rank),0)*:weight_fts + coalesce(1.0/(:rrf_k + vec_rank),0)*:weight_vec` and rrf_k=60, and (3) FTS5 candidates re-ranked by vector distance. FTS5's `rank` is the negated BM25, so lower is better. — [alexgarcia.xyz hybrid search](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/index.html)

**Learned sparse (SPLADE / BGE-M3)**
- SPLADE (Formal et al., SIGIR 2021 short, arXiv:2107.05720) learns sparse lexical-expansion representations with a sparsity regularizer. It keeps exact term matching and inverted-index efficiency while staying competitive with dense models. — [arXiv](https://arxiv.org/abs/2107.05720)
- SPLADE++ ("From Distillation to Hard Negative Sampling", SIGIR 2022 short, arXiv:2205.04733) reaches state-of-the-art in-domain and zero-shot results with distillation and hard negatives. — [arXiv](https://arxiv.org/abs/2205.04733)
- BGE-M3 (arXiv:2402.03216) produces dense, multi-vector and sparse outputs from one model for 100+ languages and up to 8,192 tokens. Its self-knowledge distillation integrates scores from all three modes. — [arXiv](https://arxiv.org/abs/2402.03216)

**Korean lexical matching (critical for the BM25 leg)**
- On Mr.TyDi Korean, BM25 scored MRR@100 / Recall@100 of **0.221 / 0.396 with whitespace tokenization**, **0.285 / 0.619 with Lucene's KoreanAnalyzer**, and 0.169 / 0.367 with mBERT WordPiece. Fusing the Lucene and mBERT runs gave 0.284 / 0.589. — ["Better Than Whitespace", arXiv:2210.05481](https://arxiv.org/html/2210.05481)
- SQLite FTS5 `unicode61` (the default tokenizer) treats Unicode categories L*/N*/Co as token characters and space/punctuation as separators, so a token is any contiguous run of letters. Hangul words with attached particles (e.g., "설정을") become single tokens, which is effectively whitespace tokenization. — [SQLite FTS5 docs](https://www.sqlite.org/fts5.html)
- The FTS5 `trigram` tokenizer allows substring matching and indexed LIKE/GLOB, but "substrings consisting of fewer than 3 unicode characters do not match any rows when used with a full-text query". FTS5 BM25 hard-codes k1=1.2 and b=0.75 and supports per-column weights through `bm25(tbl, w1, w2, …)`. — [SQLite FTS5 docs](https://www.sqlite.org/fts5.html)
- FTS5 supports custom tokenizers through the C API (`fts5_tokenizer_v2`, `xCreateTokenizer_v2`; `xCreate`/`xDelete`/`xTokenize`). — [SQLite FTS5 docs](https://www.sqlite.org/fts5.html). GRDB.swift lets you write FTS5 tokenizers in Swift via `FTS5CustomTokenizer` / `FTS5WrapperTokenizer`. — [GRDB FTS5Tokenizers.md](https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md)
- Kiwi is an Apache-2.0 C++ Korean morphological analyzer with prebuilt macOS libraries: 795★, v0.24.0 released 2026-09-13. Its README reports LM size 34.19 MB and memory use of 278 MB in one configuration and 694 MB in another. — [GitHub bab2min/Kiwi](https://github.com/bab2min/Kiwi)
- Tantivy offers Korean tokenization through lindera + lindera-ko-dic. — [Tantivy README](https://github.com/quickwit-oss/tantivy)

### Inferences
- **Use hybrid by default.** EmbeddingGemma covers cross-lingual and paraphrase intent (e.g., "invoice pdf from march" ↔ a Korean "청구서"). BM25/FTS5 covers exact names, rare tokens, code identifiers, file names and URLs, which is where dense models fail per Sciavolino, SPAR and BEIR.
- **Start with RRF k=60.** Once ~40–100 labelled personal queries exist, switch to a tuned convex combination, possibly with per-source weights (apps vs. documents vs. clipboard). Bruch et al. and the Elastic data both show CC overtakes RRF with few labels.
- **Korean BM25 needs better tokenization than unicode61.** The Mr.TyDi numbers suggest a ~56% relative Recall@100 gain from morphological analysis. Trigram alone is not enough because many Korean content words are 2 syllables (e.g., "설정", "지난"), below the 3-character trigram minimum. Options:
  - (a) A Kiwi-based FTS5 custom tokenizer that emits morpheme stems, though its ~280 MB memory is heavy for a resident launcher.
  - (b) A cheap custom tokenizer that emits Hangul character bigrams plus whitespace tokens, the CJK-bigram style.
  - (c) FTS5 prefix queries (`설정*`) to absorb attached particles.
  
  Benchmark these on the personal eval set (Q8).
- **Skip SPLADE.** Public SPLADE checkpoints are English-centric. BGE-M3 sparse is multilingual, but it would add a second ~568M-parameter encoder alongside EmbeddingGemma. For an on-device launcher, BM25 with good Korean tokenization is the pragmatic sparse leg.

### Gaps
- No published study measures hybrid vs. dense on *launcher-style* 1–3-word mixed Korean/English queries. All cited evidence comes from web/QA/BEIR-style corpora.
- No Korean-specific comparison of character-bigram vs. morphological tokenization for BM25 was found. The Mr.TyDi table does not say whether "KoreanAnalyzer" is Nori or CJK-bigram.
- I did not fetch the BGE-M3 paper's numbers for dense+sparse combination gains.

---

## Q2. Matryoshka Representation Learning: quality vs. dimension, and adaptive (shortlist → rerank) retrieval

### Takeaway
MRL lets a single EmbeddingGemma vector be truncated to 512/256/128 dims at a modest quality cost: about 97.6% of the 768-d multilingual MTEB score at 256-d and about 95% at 128-d, with code retrieval degrading faster. MRL's "adaptive retrieval" (shortlist with low dims, re-rank with full dims) matched full-dim accuracy with ~14× wall-clock speed-ups in the original paper. At ≤500k chunks this mainly buys **memory** savings rather than necessary speed.

### Cited Findings
- MRL (Kusupati et al., arXiv:2205.13147; published at NeurIPS 2022) reports "up to 14× smaller embedding size for ImageNet-1K classification at the same level of accuracy" and "up to 14× real-world speed-ups for large-scale retrieval on ImageNet-1K and 4K". — [arXiv](https://arxiv.org/abs/2205.13147)
- Adaptive Retrieval (Sec. 4.3.1) shortlists K=200 candidates with D_s=16, then re-ranks with D_r=2048. On ImageNet-1K this is "as accurate as single-shot retrieval with d=2048" while "∼128× more efficient in theory and ∼14× faster in practice", with wall-clock measured on HNSW. ImageNet-4K needed D_s=64, giving ~32× theoretical and ~6× real speed-ups. "Funnel retrieval" halves the shortlist and doubles the dims at each step (200→100→50→25→10; 16→…→2048). — [arXiv HTML](https://arxiv.org/html/2205.13147v4)
- EmbeddingGemma-300M MTEB scores (task mean), from the model card:

  | Dims | Multilingual v2 | English v2 | Code v1 |
  |---|---|---|---|
  | 768 | 61.15 | 69.67 | 68.76 |
  | 512 | 60.71 | 69.18 | 68.48 |
  | 256 | 59.68 | 68.37 | 66.74 |
  | 128 | 58.23 | 66.66 | 62.96 |

  Truncated embeddings are re-normalized. — [HF model card google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
- From the EmbeddingGemma paper (arXiv:2509.20354): "this lead persists when quantizing model weights or truncating embedding outputs", which makes it "particularly well-suited for … on-device applications". — [arXiv](https://arxiv.org/abs/2509.20354)
- sqlite-vec supports Matryoshka truncation in SQL via `vec_slice()` + `vec_normalize()`. — [sqlite-vec v0.1.0 release blog](https://alexgarcia.xyz/blog/2024/sqlite-vec-stable-release/index.html)

### Inferences
- Retention ratios computed from the model card: 256-d keeps 97.6% (multilingual), 98.1% (English) and 97.1% (code) of the 768-d score. 128-d keeps 95.2%, 95.7% and **91.6%**. Code/technical content suffers most at 128-d, which matters for "rust async"-type queries over code files.
- Memory at 500k chunks, float32: 768-d ≈ 1.54 GB, 256-d ≈ 512 MB, 128-d ≈ 256 MB. (Arithmetic: N × d × 4 bytes.)
- Suggested pattern:
  - Keep a resident 256-d (or 128-d int8) matrix for full-corpus brute-force shortlisting (top ~200–500).
  - Re-score the shortlist with full 768-d vectors stored on disk or memory-mapped.
  - This matches MRL adaptive retrieval and the HF "rescoring" pipeline (Q3), keeping RAM low while recovering most of the 768-d quality.

### Gaps
- EmbeddingGemma's model card reports MTEB aggregates, not retrieval-only per-dim numbers or shortlist-and-rerank recall. The actual loss of 128-d shortlist + 768-d rerank on Korean must be measured locally.

---

## Q3. Embedding quantization (int8 / binary) with rescoring

### Takeaway
int8 cuts vector memory 4× with roughly 97–99% retrieval quality retained (with rescoring). Binary cuts it 32× with ~92–96% retained, but only for some models: retention ranges from 75% to 96% across models. Binary is best used as a first-pass filter followed by float/int8 rescoring. EmbeddingGemma's binary retention is unpublished and must be measured.

### Cited Findings
- HF blog "Binary and Scalar Embedding Quantization" (Shakir, Aarsen, Lee; Mar 22 2024) reports exact 32× (binary) and 4× (int8) memory reduction.
  - **Speed-ups** (exact CPU search): int8 averaged 3.66× (2.99–4.8×), binary 24.76× (15.05–45.8×).
  - **Retention** (NDCG@10 on 15 MTEB retrieval tasks, rescore multiplier 4): mxbai-embed-large-v1 kept 97% with int8 and 96.45% with binary. Binary retention was 74.77% for e5-base-v2, 87.7% for nomic-embed-v1.5, 93.79% for all-MiniLM-L6-v2 and 94.6% for Cohere-v3.
  - Binary without rescoring is about 92.53% (mxbai). For int8, a rescore multiplier of 4–5 gives about 99%.
  - Recommended pipeline: binary index in RAM → top-40 → load int8 vectors from disk → rescore with the float32 query.
  
  — [HF blog](https://huggingface.co/blog/embedding-quantization)
- Binary Passage Retriever (Yamada, Asai, Hajishirzi, ACL 2021, arXiv:2106.00882) does binary-code candidate generation followed by continuous-vector reranking. It cut index memory from 65 GB to 2 GB "without a loss of accuracy" on NQ and TriviaQA. This is the origin of the "binary + rescore" recipe. — [arXiv](https://arxiv.org/abs/2106.00882)
- sqlite-vector benchmark: Apple M5 Pro, 1M × 768 uniform-random vectors, cosine, k=20, file-backed DB.

  | Mode | Size | ms/query | Recall@20 |
  |---|---|---|---|
  | FLOAT32 exact | 2,930 MB | 484 | 100% |
  | INT8 preloaded | 740 MB | 37.6 | 99.5% |
  | 1BIT | 99 MB | 2.5 | 10% |
  | TURBO4 | 378 MB | 151.5 | 81.8% |

  The authors stress that uniform random data is "the worst case for every quantizer" and say "1BIT is a filter, not an answer". UINT8 with cosine collapses to 33.8% recall, so use signed INT8 for cosine. — [sqliteai/sqlite-vector README](https://github.com/sqliteai/sqlite-vector)
- Alex Garcia anecdotally reported "roughly 95% accuracy after binary quantization" on OpenAI embeddings (sqlite-vec, 2024). — [sqlite-vec release blog](https://alexgarcia.xyz/blog/2024/sqlite-vec-stable-release/index.html)
- Azure AI Search guidance, via search snippet and not fetched in full: when combining MRL truncation with binary quantization, keep truncationDimension ≥ 1,024, because <1,000 dims degrades quality. — [Azure docs: truncate dimensions](https://docs.azure.cn/en-us/search/vector-search-how-to-truncate-dimensions)
- EmbeddingGemma's QAT *weight* quantization (Q4_0 / Q8_0 / mixed) keeps multilingual MTEB at 60.62 / 60.93 / 60.69 vs. 61.15 for full precision. This is model-weight quantization, distinct from embedding quantization. — [HF model card](https://huggingface.co/google/embeddinggemma-300m)

### Inferences
- At 10k–500k chunks, float32 768-d is only ≤1.5 GB and int8 768-d ≤384 MB. **int8 (signed, cosine) of the 256- or 768-d vector with float rescoring of the top ~100** is the safe default.
- Binary at 768-d (48 MB for 500k) is attractive for RAM but risky: retention is model-dependent (75–96%), and Azure's guidance suggests MRL-truncated (<1,000-d) vectors binarize poorly. Use it only as a pre-filter with a large rescore multiplier, after measuring on the personal eval set.

### Gaps
- No published binary or int8 retention numbers exist for EmbeddingGemma embeddings specifically, including the 128/256-d truncations.
- The Mixedbread "binary MRL" blog post could not be located in this session.

---

## Q4. ANN vs. brute-force exact search for 10k–1M vectors on Apple Silicon

### Takeaway
For ≤500k chunks, **exact brute-force search is fast enough on Apple Silicon**: roughly single-digit to low-tens of ms per query at full precision, and a few ms at 256-d or int8. It avoids HNSW's build time, deletion complexity and recall loss. HNSW/IVF becomes worthwhile around 1M+ high-dim float vectors or when many queries per second are needed. In a launcher, the query embedding forward pass is likely the bigger latency term.

### Cited Findings
- Doug Turnbull ("Just brute force your embeddings", Jul 29 2026), M4 MacBook Pro, NumPy `doc_vectors @ query` over 1M × 384 float32: **12 ms average latency, 79.7 QPS single-thread**. 8.84M docs took 106 ms. He recommends brute force "until you can't bear to". — [softwaredoug.com](https://softwaredoug.com/blog/2026/07/29/just-brute-force-embeddings)
- sqlite-vec v0.1.0 benchmarks (Mac M1 mini 8 GB, in-memory, k=20):

  | Dataset | faiss | sqlite-vec static | vec0 | usearch exact | numpy |
  |---|---|---|---|---|---|
  | SIFT1M (1M × 128) | 10 ms | 17 ms | 33–35 ms | 56 ms | 136 ms |
  | GIST (500k × 960) | 50 ms | 41 ms | 87 ms | 46 ms | 581 ms |

  Disk-based 100k vectors at ≤1,024 dims took <75 ms. At 1M vectors on disk, float vectors were too slow, from 192 ms at 192-d up to 8.5 s at 3,072-d. — [sqlite-vec release blog (2024; stale hardware/version)](https://alexgarcia.xyz/blog/2024/sqlite-vec-stable-release/index.html)
- A brute-force benchmark article (via search snippet, not fully fetched) reports exact NumPy search over 100k embeddings at 3.5 ms on 2 vCPUs, and 1M vectors at 62 ms (384-d) and 114 ms (768-d). It states latency scales linearly with n×d, i.e., memory-bandwidth bound. — [dev.to brute-force benchmark](https://dev.to/recallrundev/do-you-need-a-vector-database-brute-force-search-benchmarked-from-10k-to-1m-vectors-6fk)
- Faiss guidelines:
  - For few queries, "Flat" is most efficient because build time isn't recovered. `IndexFlatL2`/`IndexFlatIP` are the only exact indexes.
  - HNSW memory is ≈ d×4 + M×8 bytes per vector (M 4–64). Faiss HNSW "cannot remove vectors".
  - For <1M vectors, IVF with K = 4√N to 16√N clusters.
  
  — [Faiss wiki: Guidelines to choose an index](https://github.com/facebookresearch/faiss/wiki/Guidelines-to-choose-an-index)
- HNSW (Malkov & Yashunin, arXiv:1603.09320; IEEE TPAMI) is an incremental multi-layer proximity-graph ANN with logarithmic complexity scaling. — [arXiv](https://arxiv.org/abs/1603.09320)
- Faiss library paper (Douze et al., arXiv:2401.08281) covers the trade-off space of vector search. — [arXiv](https://arxiv.org/abs/2401.08281)
- USearch claims a "10x faster HNSW implementation than FAISS". It also reports exact search at 2.54 ms vs. 55.3 ms for `faiss.IndexFlatL2` in a Colab. These are vendor claims on Intel hardware. — [USearch README](https://github.com/unum-cloud/USearch)

### Inferences
- Bandwidth scaling from Turnbull's M4 figure (1M×384 f32 ≈ 1.5 GB → 12 ms): 500k×768 f32 (same 1.5 GB) ≈ 12 ms, 500k×256 f32 (~0.5 GB) ≈ 4 ms, 500k×256 int8 ≈ 1–2 ms. At 10k chunks, search is sub-millisecond. An Accelerate `cblas_sgemv` or vDSP kernel in Swift should be in the same range as NumPy, which itself calls BLAS. This is an inference that should be benchmarked.
- HNSW's graph overhead at 500k × (256-d, M=16) ≈ 500k × (1,024 + 128) B ≈ 576 MB, about 12.5% over the flat float matrix. It also adds non-trivial insert/delete handling for a constantly changing clipboard/browser-history corpus. Brute force over a contiguous `[Float]`/`[Int8]` buffer is simpler and exact.
- GPU (Metal/MLX) brute force is unlikely to be needed at this scale. CPU BLAS/AMX is already bandwidth-bound in single-digit ms, and GPU dispatch overhead would dominate.

### Gaps
- No published Apple-Silicon benchmark of Swift Accelerate/vDSP or Metal/MLX brute-force top-k for 100k–1M embeddings was found. The numbers above are NumPy/C on M1/M4/M5. A micro-benchmark on the target Mac is required.
- No direct HNSW-vs-flat latency comparison at 500k × 256-d on Apple Silicon was found.

---

## Q5. Chunking strategies and representing non-document items as text

### Takeaway
Simple fixed-size or sentence-group chunks are as good as "semantic" chunking at a fraction of the cost. Adding document context to each chunk, via title/path prefixes or generated context, measurably improves retrieval. EmbeddingGemma's document template has an explicit `title:` slot that should carry the file name, path or page title. Late chunking gives +1.5–1.9 nDCG@10 on average, but it needs a long-context mean-pooling model, and EmbeddingGemma's 2,048-token window limits it.

### Cited Findings
- "Is Semantic Chunking Worth the Computational Cost?" (Qu, Tu, Bao, arXiv:2410.13070) evaluated document retrieval, evidence retrieval and answer generation. It concludes "the computational costs associated with semantic chunking are not justified by consistent performance gains". — [arXiv](https://arxiv.org/abs/2410.13070)
- Late chunking (Günther et al., Jina AI, arXiv:2409.04701) embeds the whole text and then mean-pools per chunk.
  - Averages over 3 models × 4 BEIR sets, nDCG@10: fixed 256-token 52.2→54.0, sentence 52.4→54.3, semantic 52.4→53.8.
  - Example (jina-v2-small, fixed 256): NFCorpus 23.5→30.0.
  - It helps most for small chunks. Overlapping chunks showed "no clear advantage". It applies to "any long-context text embedding model that uses mean pooling".
  
  — [arXiv HTML](https://arxiv.org/html/2409.04701v3)
- Anthropic's Contextual Retrieval prepends 50–100 tokens of chunk-specific context before embedding and BM25 indexing. This cut retrieval failures by 35% (embeddings only) and 49% (with contextual BM25). — [Anthropic](https://www.anthropic.com/news/contextual-retrieval)
- EmbeddingGemma prompt formats are `task: search result | query: {content}` for queries and `title: {title | "none"} | text: {content}` for documents. "Providing a real title improves performance". The maximum input is 2,048 tokens. — [HF model card](https://huggingface.co/google/embeddinggemma-300m)
- Apple's Core Spotlight semantic index processes `title` and `textContent` of a `CSSearchableItemAttributeSet`. Apple says semantic search "works best on text or media assets". — [WWDC24 "Support semantic search with Core Spotlight"](https://developer.apple.com/videos/play/wwdc2024/10131/)

### Inferences
- **Documents (PDF/MD/txt/docx/code):** chunk at roughly 256–512 tokens on paragraph, heading or function boundaries with little or no overlap. Late-chunking results show overlap gives no clear gain. Put `"{filename} — {parent folder path} — {nearest heading}"` into EmbeddingGemma's `title:` slot. Also index one document-level vector per file (title + first chunk) so file-level queries ("invoice pdf from march") hit the file, not a random chunk.
- **Non-document items** need a synthetic text "card". These are design suggestions, not sourced best practice:
  - Apps: `title: {localized name} | text: {English name} {Korean name} {bundle id} {category} {short description}`.
  - System Settings panes: pane title in both languages plus keywords (e.g., "Bluetooth 블루투스 무선 기기 AirPods 연결").
  - Browser history/bookmarks: page title + domain + URL path tokens.
  - Clipboard entries: content truncated, plus source app.
- Keep date and type out of the embedded text. Treat them as structured filters and features (Q6), because the date phrases in "지난주"/"march" are better handled by query parsing than by embedding similarity.
- Late chunking is optional. Its gain is modest, and EmbeddingGemma's 2,048-token limit means long PDFs need multi-window "long late chunking" anyway.

### Gaps
- No academic or engineering study on embedding representations for apps, settings panes or clipboard entries in launchers was found.
- Not verified whether EmbeddingGemma's pooling head (mean pooling followed by dense projections) is compatible with late chunking without modification.

---

## Q6. Launcher-specific concerns: fuzzy/prefix matching, frecency boosting, intent/type routing, desktop-search literature

### Takeaway
Personal-search research shows that re-finding dominates: queries are very short, people's names and dates are key memory cues, and users strongly preferred date-sorted results over relevance-ranked ones. This implies a **multi-signal ranker**: lexical/fuzzy score + semantic score + recency/frequency ("frecency") + item-type prior, with type/intent prediction for heterogeneous sources. Proven frecency formulas exist (Firefox, zoxide), and Apple's own Core Spotlight API feeds engagement signals into ranking.

### Cited Findings
**Desktop / personal information retrieval**
- Stuff I've Seen (Dumais et al., SIGIR 2003, pp. 72–79, DOI 10.1145/860435.860451), a unified index over email, web, files and appointments deployed to 234 users:
  - Queries were short, averaging **1.59 words**, and only 7.5% used Boolean or field operators.
  - **25% of queries involved people's names.**
  - Opened items: 76% email, 14% web, 10% files. 6.6% had been first seen that day, 21.9% within a week, 45.9% within a month and 89.4% within a year.
  - In sort usage, **Date was used for 5,037 queries vs. Rank for 2,038** (of 8,254). Even users whose default was Rank sorted by Date more often (1,975 vs. 1,530).
  
  — [SIS paper PDF](https://www.cs.odu.edu/~sampath/courses/w17/cs599/papers/SISCore-SIGIR2003-Final.pdf); [bibliographic record](https://ir.webis.de/anthology/2003.sigirconf_conference-2003.12)
- Teevan, Adar, Jones, Potts, "Information Re-Retrieval: Repeat Queries in Yahoo's Logs" (SIGIR 2007, pp. 151–158): up to **40%** of queries are re-finding queries. That figure is an upper bound. The authors argue search engines should explicitly support re-finding. — [MSR page](https://www.microsoft.com/en-us/research/publication/information-re-retrieval-repeat-queries-yahoos-logs/); [PDF](https://people.csail.mit.edu/teevan/work/publications/papers/sigir07.pdf)
- Kim & Croft, "Ranking using Multiple Document Types in Desktop Search" (SIGIR 2010): **predicting the document type a user wants is central** to desktop search over email, web pages, PDFs and so on with type-specific metadata. Type prediction using type-specific metadata, and combining prediction methods, improves the merged ranking. — [CIIR PDF](https://ciir-publications.cs.umass.edu/getpdf.php?id=915); [DOI via unpaywall](https://unpaywall.org/10.1145%2F1835449.1835461)

**Frecency formulas in production**
- Firefox frecency:
  - Each sampled visit gets weight × e^(−λ·age) with λ = ln2/30, a **30-day half-life**.
  - Visit buckets are Very High / High (typed or bookmarked) / Medium (link click) / Low (redirect, reload), with "interesting interaction" (view time, keypresses) promoting a visit one bucket.
  - Total = (Σ visit scores / sample count) × visit count, stored as t_ref + ln(score)/λ.
  - Adaptive input history (what the user picked for a given typed string) is ranked before frecency.
  
  — [Firefox source docs: urlbar ranking](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html)
- zoxide (40k★): +1 per access, then at query time ×4 if accessed in the last hour, ×2 in the last day, ÷2 in the last week, ÷4 if older. Aging rescales totals to ~90% of `_ZO_MAXAGE` and drops entries <1. Matching is case-insensitive with ordered terms. — [zoxide wiki: Algorithm](https://github.com/ajeetdsouza/zoxide/wiki/Algorithm)
- Core Spotlight lets apps set `attributeSet.lastUsedDate` on engagement and report `query.userEngaged(item, visibleItems:, interaction: .select)`. Ranked results go in a "Top Hits" section and sort via `compareByRank`. — [WWDC24 session 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)

### Inferences
- **Proposed scoring.** `final = w_sem·sem_norm + w_lex·lex_norm + w_fuzzy·fuzzy_prefix + w_fre·log(1+frecency) + type_prior(query)`, or RRF across these ranked lists, with weights tuned on the personal eval set (Q8).
- **Apps and settings panes** (a small set, a few hundred items): run per-keystroke fuzzy/prefix matching (fzf-style subsequence scoring with word-boundary bonuses) plus Korean-specific matching:
  - initial-consonant (초성, chosung) search, e.g. "ㅂㄹㅌㅅ" → 블루투스;
  - jamo decomposition for partial-syllable input;
  - Korean↔English name aliases.
  
  These are standard Korean-UI practices, not sourced here. Semantic scoring can run on Enter, or after a debounce, for longer queries.
- **Query-intent routing** is a lightweight version of Kim & Croft's type prediction. Use rules or a tiny classifier on the query:
  - file-type words ("pdf", "문서") boost files;
  - "설정"/"settings" boosts settings panes;
  - temporal phrases ("지난주", "last week", "march") become date-range filters on visit/modified time rather than embedded text;
  - URL- or site-like tokens boost browser history.
- **Weight recency heavily**, because SIS showed users preferred date ordering. Use a Firefox-style exponential decay with a half-life per source (short for clipboard, about 30 days for browser history). Feed the launcher's own selection history back in, like Firefox adaptive history and Core Spotlight `userEngaged`.

### Gaps
- No recent (2023–2026) academic paper or engineering write-up on *semantic* (embedding-based) ranking inside desktop launchers (Raycast, Alfred, Spotlight) was found. The evidence base is classic PIM/desktop-search research plus browser/CLI frecency.
- fzf's exact scoring algorithm was not fetched. The fzf repo (83.6k★, active Oct 2026) is a reference implementation: [junegunn/fzf](https://github.com/junegunn/fzf).
- No published study on Korean 초성 search effectiveness was retrieved.

---

## Q7. Optional reranking with small local cross-encoders

### Takeaway
Rerankers give a sizeable quality boost: Anthropic's failure rate fell from 2.9% to 1.9% after adding one on top of hybrid. Among small multilingual rerankers, Qwen3-Reranker-0.6B has the strongest published scores and an Apache-2.0 license. jina-reranker-v2 is CC-BY-NC and so unsuitable for a commercial app. No trustworthy Apple-Silicon latency numbers were found, so reranking should be optional and limited to the top ~20–50 candidates on Enter.

### Cited Findings
- Qwen3-Reranker-0.6B model card (vendor-reported), reranking the top-100 candidates from Qwen3-Embedding-0.6B:

  | Model | MTEB-R | CMTEB-R | MMTEB-R | MLDR | MTEB-Code |
  |---|---|---|---|---|---|
  | Qwen3-Reranker-0.6B | 65.80 | 71.31 | 66.36 | 67.28 | 73.42 |
  | bge-reranker-v2-m3 (0.6B) | 57.03 | 72.16 | 58.36 | 59.51 | 41.38 |
  | jina-multilingual-reranker-v2-base (0.3B) | 58.22 | 63.37 | 63.73 | 39.66 | 58.98 |
  | gte-multilingual-reranker-base (0.3B) | 59.51 | 74.08 | 59.44 | 66.33 | 54.18 |

  The retriever alone (Qwen3-Embedding-0.6B) scored MMTEB-R 64.64. Qwen3-Reranker has a 32K context and an Apache-2.0 license, and scores relevance as P("yes") with an instruction-style chat prompt. — [HF Qwen/Qwen3-Reranker-0.6B](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B); [Qwen3 Embedding paper arXiv:2506.05176](https://arxiv.org/abs/2506.05176)
- jina-reranker-v2-base-multilingual: 278M params, 1,024-token max (sliding window beyond), **CC-BY-NC-4.0** ("research and evaluation purposes"). BEIR nDCG@10 is 53.17 vs. 53.65 for bge-reranker-v2-m3, MKQA 54.83 vs. 54.17, and MLDR recall@10 68.95 vs. 59.73. ONNX variants are listed. — [HF jinaai/jina-reranker-v2-base-multilingual](https://huggingface.co/jinaai/jina-reranker-v2-base-multilingual)
- An ONNX export of bge-reranker-v2-m3 exists. — [HF onnx-community/bge-reranker-v2-m3-ONNX](https://huggingface.co/onnx-community/bge-reranker-v2-m3-ONNX)
- bge-reranker-v2-m3 is tagged `license:apache-2.0` on Hugging Face; the model was last modified 2024-06-24, so it is older and possibly stale. — [HF BAAI/bge-reranker-v2-m3](https://huggingface.co/BAAI/bge-reranker-v2-m3)
- In Anthropic's setup, reranking retrieved the top 150 and kept the top 20. Failure rate went 2.9% → 1.9% on top of contextual embeddings + BM25. — [Anthropic](https://www.anthropic.com/news/contextual-retrieval)
- BEIR found re-ranking and late-interaction models achieve the best zero-shot performance "at high computational costs". — [arXiv:2104.08663](https://arxiv.org/abs/2104.08663)

### Inferences
- Cross-encoder cost scales with candidates × (query + doc tokens). With a 0.3–0.6B model on an M-series GPU, reranking 20–50 short candidates (≤256 tokens each) is plausibly tens to a few hundred ms. That is acceptable after Enter, but not per keystroke. This is an unverified estimate.
- Reranking is most valuable for document/chunk results. It is pointless for apps and settings (exact-name matching plus frecency dominates) and for clipboard items, where recency dominates.
- Qwen3-Reranker-0.6B's quality lead comes from vendor-run benchmarks on candidates from the vendor's own embedder. Re-verify it on the personal eval set against EmbeddingGemma candidates.

### Gaps
- **No reliable per-pair latency measurements on Apple Silicon** (MLX, Core ML or ONNX Runtime) were found for bge-reranker-v2-m3, jina-reranker-v2 or Qwen3-Reranker-0.6B. A local benchmark is required.

---

## Q8. Evaluation: building a small personal eval set (recall@k, MRR, nDCG)

### Takeaway
Launcher queries are mostly *known-item re-finding*, so **MRR / success@1 / success@5** should be the primary metrics. **Recall@k (k=50–200)** measures the first-stage candidate generator, and **nDCG@10** is for graded document queries. A few dozen to a couple hundred labelled queries is enough to compare configurations and tune fusion weights. LLM-generated queries and LLM relevance labels can scale the set.

### Cited Findings
- Tuning a convex hybrid weight is "sample efficient, requiring only a small set of training examples". — [Bruch et al., arXiv:2210.11934](https://arxiv.org/abs/2210.11934). Elastic beat RRF with "approximately 40 annotated queries". — [Elastic blog](https://www.elastic.co/search-labs/blog/improving-information-retrieval-elastic-stack-hybrid)
- InPars: LLMs used few-shot as synthetic query generators for IR produce training data that beats BM25 and self-supervised dense baselines. This supports LLM-generated queries from one's own documents. — [arXiv:2202.05144](https://arxiv.org/abs/2202.05144)
- Thomas, Spielman, Craswell, Mitra (Bing; arXiv:2309.10621): LLM relevance labelling, calibrated against first-party user feedback, reached "accuracy as good as human labellers". — [arXiv](https://arxiv.org/abs/2309.10621)
- MIRACL provides 18-language ad hoc retrieval with native-speaker judgments, which is useful as a public Korean sanity check alongside the personal set. — [arXiv:2210.09984](https://arxiv.org/abs/2210.09984)
- Stuff I've Seen evaluated a deployed desktop-search system with usage logs plus questionnaires across randomized interface conditions (Date vs. Rank default, Top vs. Side view). This is a model for in-situ A/B evaluation of a personal search tool. — [SIS paper PDF](https://www.cs.odu.edu/~sampath/courses/w17/cs599/papers/SISCore-SIGIR2003-Final.pdf)
- Tooling:
  - ranx (Python ranking evaluation and fusion library): 702★, last push 2025-08-07, so slightly stale. — [GitHub AmenRa/ranx](https://github.com/AmenRa/ranx)
  - ir_measures: 103★, last push 2026-09-30. — [GitHub terrierteam/ir_measures](https://github.com/terrierteam/ir_measures)

### Inferences
- **Eval-set recipe:**
  1. Log real launcher queries locally, opt-in, together with the item eventually opened. Every query → selected item pair is a free known-item label.
  2. Seed 50–150 hand-written queries stratified by source (apps/settings, files, browser, clipboard), by language (Korean, English, mixed), and by type (exact name, partial or typo, paraphrase, temporal like "지난주…", cross-lingual).
  3. Add LLM-generated queries from sampled personal documents (InPars-style), labelled with their source doc.
  4. Optionally have an LLM grade top-10 results for nDCG.
- Compare configurations: dense-only vs. BM25-only vs. RRF vs. CC; dims 768/256/128; int8/binary; with or without title prefixes; Korean tokenizers; with or without reranker. Report MRR@10, success@1/5, recall@100 and p50/p95 latency. Re-run whenever the model or tokenizer changes.

### Gaps
- No published personal or launcher eval benchmark with Korean queries exists. The eval set must be built locally.

---

## Q9. Library landscape: SQLite-based options (sqlite-vec + FTS5, sqlite-vector, GRDB/SQLiteVec)

### Takeaway
**SQLite + FTS5 + a vector extension in one file** is the most natural fit. It gives transactional incremental updates and deletes, metadata filtering, BM25 and vectors in one database, with Swift access via GRDB or SQLiteVec. sqlite-vec is the most popular choice but is pre-v1, brute-force in its stable release, with ANN only in alpha, and it has had no commits since May 2026. sqlite-vector (sqliteai) is an actively maintained alternative with strong int8 quantized-scan performance on Apple Silicon and a Swift package.

### Cited Findings
| Library | Stars / last push / latest release (2026-10-13) | License | Key facts |
|---|---|---|---|
| **asg017/sqlite-vec** | 8,184★; push 2026-05-18; stable v0.1.9 (2026-03-31), v0.1.10-alpha.4 (2026-05-18) | MIT / Apache-2.0 | `vec0` virtual table. float, int8 and bit vectors. Metadata, auxiliary and partition-key columns. Pre-v1, "expect breaking changes". Single C file with no dependencies. v0.1.10-alpha adds ANN: "rescore", DiskANN, and IVF ("experimental, not enabled"). DiskANN deletes are "quite expensive". Official bindings cover Python, Node, Ruby, Go and Rust, but not Swift. Sponsors: Mozilla Builders, Fly.io, Turso, SQLite Cloud. — [GitHub](https://github.com/asg017/sqlite-vec); [release notes via GitHub API](https://github.com/asg017/sqlite-vec/releases); [v0.1.0 blog](https://alexgarcia.xyz/blog/2024/sqlite-vec-stable-release/index.html) |
| **jkrukowski/SQLiteVec** (Swift wrapper) | 50★; push/release 0.0.15 on 2026-09-22 | MIT | SPM package. `SQLiteVec.initialize()`, async `Database.execute/query`, `vec0` usage from Swift. — [GitHub](https://github.com/jkrukowski/SQLiteVec) |
| **sqliteai/sqlite-vector** | 1,180★; release 1.1.2 on 2026-09-11 | Apache-2.0 (per README) | Regular BLOB columns with no virtual table and "zero preindexing". Float32/F16/BF16/Int8/UInt8/1-bit/TurboQuant 2–4-bit. 30 MB default memory. Has Swift, Android, Python and Flutter packages. On M5 Pro, 1M×768 INT8 runs at 37.6 ms/query preloaded and 114 ms streamed in 30 MB, with 99.5% recall@20. Filters work by joining with normal SQL `WHERE`. Its managed counterpart is SQLite Cloud. — [GitHub README](https://github.com/sqliteai/sqlite-vector) |
| **groue/GRDB.swift** | 8,686★; v7.11.1 (2026-06-18); push 2026-09-29 | MIT | SQLite toolkit for Swift with FTS5 support and **Swift-implemented custom FTS5 tokenizers** (`FTS5CustomTokenizer`, `FTS5WrapperTokenizer`). — [GitHub](https://github.com/groue/GRDB.swift); [FTS5Tokenizers.md](https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md) |
| **SQLite FTS5** (built-in) | n/a | Public domain | BM25 ranking with column weights. unicode61, porter, ascii and trigram tokenizers. Custom tokenizers via the C API. The trigram tokenizer cannot match queries shorter than 3 characters. — [sqlite.org/fts5](https://www.sqlite.org/fts5.html) |
| **tursodatabase/libsql** | 17,267★; push 2026-10-01 | MIT (GitHub API) | SQLite fork; vector features not evaluated in this session. — [GitHub](https://github.com/tursodatabase/libsql) |

- In the 2024 post, sqlite-vec's `vec0` had no metadata filtering. The current README lists metadata, auxiliary and partition-key columns. — [GitHub](https://github.com/asg017/sqlite-vec)
- FTS5 + sqlite-vec RRF hybrid can be written in pure SQL (CTE + `FULL OUTER JOIN`). — [alexgarcia.xyz hybrid search](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/index.html)

### Inferences
- Recommended baseline schema: one SQLite file holding:
  - an `items` table (id, source type, path/URL, title, timestamps, frecency counters);
  - a `chunks` table;
  - an FTS5 table over title + text, with a Korean-aware custom tokenizer through GRDB;
  - a vector store, either sqlite-vec `vec0` with int8 or 256-d float, or sqlite-vector BLOBs.
  
  Upserts and deletes stay transactional with the item metadata, which suits clipboard and browser-history churn.
- Alternative: keep vectors in a custom contiguous memory-mapped `[Int8]`/`[Float]` file, brute-forced with Accelerate, keyed by SQLite rowids. This gives the fastest scan and the fewest dependencies. SQLite then holds only metadata and FTS5.
- sqlite-vec risk: there has been no push for ~5 months, the ANN work is still alpha, and it is pre-v1. That is acceptable at this scale because its stable brute-force path is enough, but pin a version.
- Check whether macOS's system `libsqlite3` permits loading extensions (it reportedly does not). Bundling SQLite statically (as GRDB/SQLiteVec builds can) avoids the issue. This needs verification.

### Gaps
- The sqlite-vec v0.1.10 ANN (DiskANN/rescore) documentation was "coming soon" per the release notes. No benchmarks of it were found.
- sqlite-vector's licensing history was not checked (only the current README states Apache-2.0).
- libsql's vector feature set was not examined.

---

## Q10. Library landscape: dedicated ANN libraries and embedded databases (USearch, FAISS, hnswlib, ObjectBox, LanceDB, DuckDB vss, Tantivy)

### Takeaway
**USearch** is the strongest standalone ANN/exact library for Swift. It has a first-party SPM package, int8/bf16/f16 quantization, deletes, memory-mapped `view`, filter predicates, and very active maintenance. FAISS and hnswlib are mature but lack Swift bindings. ObjectBox Swift is the only Swift-native embedded DB with built-in HNSW plus query filters. LanceDB has no Swift SDK, and DuckDB vss persistence is explicitly not production-ready. Tantivy is the best Rust BM25 engine, with Korean via lindera, but needs FFI.

### Cited Findings
| Library | Stars / last push / latest release (2026-10-13) | License | Swift? | Notes |
|---|---|---|---|---|
| **unum-cloud/USearch** | 4,333★; push 2026-10-05; v2.26.4 (2026-10-05) | Apache-2.0 | **Yes, SPM.** `USearchIndex.make(metric:dimensions:connectivity:quantization:)`, `add`, `search`, `get`, `remove`, `save/load/view`. | Quantization f64/f32/bf16/f16/e5m2/e4m3/…/u8/i8/b1; "i8 only valid for cosine-like metrics". "On-the-fly deletions". Filter predicates applied during graph traversal (Swift ✅). Memory-mapped view from disk. Example app: [ashvardanian/SwiftSemanticSearch](https://github.com/ashvardanian/SwiftSemanticSearch) (162★, last push 2024-12, stale). — [GitHub](https://github.com/unum-cloud/USearch); [swift/README](https://github.com/unum-cloud/USearch/tree/main/swift) |
| **facebookresearch/faiss** | 41,140★; push 2026-10-13; v1.15.1 (2026-09-16) | MIT | No official Swift binding (C++/Python) | Flat (exact), IVF, HNSW, PQ. HNSW cannot remove vectors. — [GitHub](https://github.com/facebookresearch/faiss); [index guidelines](https://github.com/facebookresearch/faiss/wiki/Guidelines-to-choose-an-index) |
| **nmslib/hnswlib** | 5,349★; push 2026-09-15; v0.9.0 (2026-03-28) | Apache-2.0 | No (header-only C++/Python; usable via C++ interop) | Reference HNSW implementation. — [GitHub](https://github.com/nmslib/hnswlib) |
| **objectbox/objectbox-swift** | 619★; v5.3.0 (2026-05-19) | Apache-2.0 (Swift binding) | **Yes** | HNSW vector index via `// objectbox:hnswIndex: dimensions=…, distanceType="cosine"`. Queries via `.nearestNeighbors(queryVector:maxCount:)` combinable with other conditions (`.and(...)`). Params: neighborsPerNode=30, indexingSearchCount=100, vectorCacheHintSizeKB=2 GB default. Persists deltas on add/modify/delete and repairs neighborhoods on removal. — [ObjectBox vector search docs](https://docs.objectbox.io/on-device-vector-search); [GitHub](https://github.com/objectbox/objectbox-swift) |
| **lancedb/lancedb** | 11,656★; push 2026-10-13; v0.40.0 (2026-10-07) | Apache-2.0 | **No** (Python, TypeScript and Rust SDKs only) | Embedded columnar Lance format with vector, full-text and SQL search. — [GitHub](https://github.com/lancedb/lancedb) |
| **duckdb/duckdb-vss** | 269★; push 2026-10-12; no GitHub releases | MIT | No | "Experimental". HNSW persistence needs `hnsw_enable_experimental_persistence`, and WAL recovery for custom indexes is "not yet properly implemented". The index is serialized whole on each checkpoint and must fit in RAM. FLOAT only. Deletes are only marked until `PRAGMA hnsw_compact_index`. The docs say "do not use this feature in production". — [DuckDB vss docs](https://duckdb.org/docs/current/core_extensions/vss.html) |
| **quickwit-oss/tantivy** | 16,207★; push 2026-10-13; 0.26.1 (2026-05-10) | MIT | No (Rust; needs FFI such as uniffi) | Lucene-style BM25, incremental indexing, mmap directory, "tiny startup time (<10ms)". Updates are delete + reindex. Korean via lindera + lindera-ko-dic. — [GitHub](https://github.com/quickwit-oss/tantivy); [lindera](https://github.com/lindera/lindera) (692★, push 2026-10-12) |

### Inferences
- If ANN is ever needed, for example beyond ~1M chunks or for an image-embedding extension, USearch is the drop-in Swift choice. It supports deletes (needed for clipboard/history expiry), predicate filters (source type, date range) and mmap views, keeping RAM low.
- ObjectBox suits teams that want an object DB with vector + filter queries in pure Swift. It has no built-in BM25/FTS, so hybrid would need a second index.
- Tantivy + lindera-ko-dic would give the best Korean BM25 quality and features, at the cost of a Rust FFI layer and a separate index file. SQLite FTS5 with a custom tokenizer keeps everything in one transactional file.

### Gaps
- Whether the ObjectBox core library (as opposed to the Swift binding) is open source, and its HNSW recall/latency on Apple Silicon, were not verified.
- USearch's performance claims are vendor-run on Intel. No independent Apple-Silicon USearch benchmark at 100k–1M was found.

---

## Q11. Apple platform capabilities: Core Spotlight, NaturalLanguage, Accelerate brute force

### Takeaway
Apple's own semantic APIs do **not** replace a custom pipeline for this launcher:
- Core Spotlight semantic search only searches content the app itself donates, with unspecified languages and models.
- `NLContextualEmbedding` gives per-token BERT-style vectors that Apple itself steers away from for semantic similarity.

Accelerate-based brute force (as VecturaKit does) is a proven, dependency-free Swift approach.

### Cited Findings
- Core Spotlight semantic search (WWDC24 session 10131):
  - Apps donate `CSSearchableItem`s with `title` and `textContent` processed into a "private, entirely local index". `CSUserQuery` with `CSUserQueryContext` returns ranked items and suggestions.
  - "Semantic search requires machine learning models that must be downloaded to the device, and will be run in your app's process". Call `CSUserQuery.prepare()` before showing the search UI.
  - Engagement signals are `lastUsedDate` and `userEngaged`. Searches cover only the app's own donated content: "no other apps will be able to see the data".
  - Supported languages are not listed.
  
  — [Apple WWDC24 video page](https://developer.apple.com/videos/play/wwdc2024/10131/)
- `NLContextualEmbedding` (macOS 14+/iOS 17+):
  - It "computes sequences of embedding vectors" (per token). Models are selected by language or script, and some models cover several languages. Assets are downloaded via `requestAssets`. Properties include `dimension` and `maximumSequenceLength`.
  - Apple's documentation note: "For semantic similarity tasks, consider using NLEmbedding."
  
  — [Apple docs: NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- An Apple Developer Forums thread reports that `NLEmbedding.wordEmbedding` lacked Korean support. — [Apple Developer Forums thread 749109](https://developer.apple.com/forums/thread/749109)
- VecturaKit's `VectorSearchEngine` is "Accelerate-based similarity computation" with a `TopKSelector`, i.e., in-memory brute force. Its "indexed" storage mode, with `candidateMultiplier`, is recommended for 100K+ documents and loads candidates on demand. — [VecturaKit source: VectorSearchEngine.swift](https://github.com/rryam/VecturaKit/blob/main/Sources/VecturaKit/SearchEngine/VectorSearchEngine.swift); [README](https://github.com/rryam/VecturaKit)

### Inferences
- Core Spotlight could serve as a *complementary* channel: donating launcher items makes them findable from system Spotlight. It cannot query other apps' or the system's file index semantically, and it gives no control over the embedding model, Korean quality or fusion. So it is not a substitute for EmbeddingGemma + a custom index.
- `NLContextualEmbedding` is not a retrieval-trained sentence embedder, so EmbeddingGemma should be used for both queries and documents.
- A Swift brute-force kernel works like this: keep the corpus matrix contiguous (N × d, Float32 or Int8), compute scores with `cblas_sgemv` or vDSP dot products, then take top-k with a partial heap. Per Q4, this should be ~1–15 ms at ≤500k chunks.

### Gaps
- Core Spotlight semantic search's supported languages (Korean?), hardware requirements, and whether it needs Apple Intelligence were not confirmed.
- Whether `NLContextualEmbedding` ships a Korean/Hangul-script model was not confirmed. Query `contextualEmbeddings(forValues:)` at runtime to check.
- No information on WWDC25/WWDC26 changes to Core Spotlight semantic search was retrieved.

---

## Q12. Swift packages offering hybrid search out of the box

### Takeaway
**VecturaKit** is the only actively maintained Swift package found that ships BM25 + vector hybrid search out of the box. It uses a weighted linear score combination, Accelerate brute force, and pluggable embedders (MLX, swift-embeddings, NLContextualEmbedding, OpenAI-compatible). Older Swift semantic-search packages are stale. A SQLite (GRDB + FTS5 + sqlite-vec/sqlite-vector) composition gives more control, notably over Korean tokenization and metadata filters.

### Cited Findings
- **rryam/VecturaKit**: 324★, MIT, release 6.3.0 (2026-08-05), last push 2026-08-31, macOS 15+/iOS 18+, Swift 6.
  - Hybrid search "combines vector similarity with BM25 text search". The config has `hybridWeight`/`vectorWeight` (text weight = 1 − vectorWeight), BM25 `k1`, `b` and `bm25NormalizationFactor` ("normalize BM25 scores into 0-1 range"). This is a **convex combination, not RRF**.
  - Memory modes are automatic, full-memory and indexed. APIs include `updateDocument`, `deleteDocuments` and `getDocument`, with persistent storage behind a pluggable `VecturaStorage` protocol. CLIs are included.
  - Embedders: `NLContextualEmbedder`, `SwiftEmbedder` (swift-embeddings), `MLXEmbedder` and `OpenAICompatibleEmbedder`.
  - Metadata filtering is not mentioned.
  
  — [GitHub README](https://github.com/rryam/VecturaKit); [HybridSearchEngine.swift](https://github.com/rryam/VecturaKit/blob/main/Sources/VecturaKit/SearchEngine/HybridSearchEngine.swift)
- **jkrukowski/swift-embeddings** ("Run embedding models locally in Swift using MLTensor"): 155★, last push 2026-09-21. — [GitHub](https://github.com/jkrukowski/swift-embeddings)
- **ml-explore/mlx-swift-examples** (which includes MLX embedders): 2,678★, last push 2026-07-20. — [GitHub](https://github.com/ml-explore/mlx-swift-examples)
- **ZachNagengast/similarity-search-kit**: 536★, last push **2024-06-04, stale**. — [GitHub](https://github.com/ZachNagengast/similarity-search-kit)
- **ashvardanian/SwiftSemanticSearch** (USearch demo): 162★, last push **2024-12-20, stale**. — [GitHub](https://github.com/ashvardanian/SwiftSemanticSearch)

### Inferences
- VecturaKit is a good prototype or reference implementation. For production in this launcher, its likely limitations are:
  - an unknown BM25 tokenizer, so Korean particle handling is probably whitespace-level;
  - no documented metadata/date/type filtering;
  - no frecency signal;
  - min-max-normalized convex fusion with a single global weight.
  
  Its pluggable `VecturaSearchEngine` and `VecturaStorage` protocols could host a custom Korean-aware BM25 and frecency.
- A SQLite composition gives full control and one-file transactional persistence: GRDB (FTS5 + Swift custom Korean tokenizer) + SQLiteVec/sqlite-vector or an Accelerate brute-force matrix + RRF/CC fusion in Swift.

### Gaps
- VecturaKit's BM25 tokenizer implementation (Korean handling) and on-disk format were not inspected.
- Whether swift-embeddings or MLX embedders support EmbeddingGemma-300M was not checked. That is likely covered by the model-runtime research track.
