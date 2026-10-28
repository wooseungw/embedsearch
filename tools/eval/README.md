# Retrieval regression fixtures

`make-fixtures.swift` generates 30 original PDFs and 10 original OCR cards, plus 111 labelled queries (72 development, 39 validation). The generated content is CC0-1.0. It is a synthetic smoke/regression corpus, not a representative natural-image benchmark. Query variants of the same file always stay in one split. The validation split includes a negative query; a false positive is counted separately from execution errors.

```sh
arch -arm64 swift tools/eval/make-fixtures.swift build/eval-fixtures
```

Use the same generated folder for both sides of a comparison: regenerating PDFs can change their metadata and file-version hashes. `manifest.json` records actual SHA-256 hashes. Keep the model checkpoint, dimensions, PDF reader, index database and corpus fixed. Use an isolated test database, never the user's live index.

With a local checkpoint in `EMBEDSEARCH_EVAL_MODEL` and the current CLI built:

```sh
.build/debug/embedsearch-cli eval --db build/eval.sqlite --model "$EMBEDSEARCH_EVAL_MODEL" --folder build/eval-fixtures/files --no-odl --no-shortcuts --file build/eval-fixtures/development.jsonl --fixed-fusion --json build/development-fixed.json
.build/debug/embedsearch-cli eval --db build/eval.sqlite --model "$EMBEDSEARCH_EVAL_MODEL" --folder build/eval-fixtures/files --no-odl --no-shortcuts --file build/eval-fixtures/development.jsonl --json build/development-candidate.json
python3 tools/eval/compare.py build/development-fixed.json build/development-candidate.json
```

After choosing configuration on development queries, run the same pair with `validation.jsonl` and new output paths. Preserve the full per-query results, unmatched labels and execution errors. Do not tune on those results and continue to call the same data held out.

The comparison rejects different corpus/query/model fingerprints, any execution errors, lower aggregate MRR, and loss of previously correct exact/initials queries. It reports all other top-1 regressions; a passing comparison does not assert that every subtype improved. Review negative-query false positives and each subtype's sample count.

All modes in an eval run share the RAM query cache in sequence. In `all` mode the semantic pass populates vectors subsequently used by hybrid, so those latencies are not directly comparable as uncached embedding timings. Measure UI commit-to-result latency separately, including its debounce, and separate loaded-model, unloaded-model and cached-query runs.

File content/keyword lists are fused by the hybrid path. The `semantic` mode evaluates item-card vectors alone; use the hybrid report to assess file retrieval. A degraded engine in a semantic/hybrid evaluation is recorded as an execution failure, so lexical fallback cannot be mistaken for a successful model evaluation.
