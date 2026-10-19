"""Write tools/parity/reference.json: fp32 CPU sentence-transformers vectors for google/embeddinggemma-2.

Run from this directory (Apple Silicon, native arm64):

    arch -arm64 uv run python make_reference.py

The Swift `embedsearch-cli parity` command embeds the same inputs with MLX and compares.
Prompt strings MUST match `EmbeddingPrompt.format` in Sources/EmbedCore/Embedding.swift.
"""

from __future__ import annotations

import argparse
import json
import platform
import time
from pathlib import Path

import numpy as np
import sentence_transformers
import torch
import transformers
from huggingface_hub import model_info
from sentence_transformers import SentenceTransformer

MODEL_ID = "google/embeddinggemma-2"
PROMPT_VERSION = "eg2-1"  # EmbeddingPrompt.version
FULL_DIMS = 768
MRL_DIMS = [256]
MAX_SEQ_LENGTH = 8192  # model context; nothing in the main set is truncated
TRUNCATION_MAX_TOKENS = 256  # second set: checks that MLXEmbedderConfiguration.maxTokens truncates like HF


# Mirrors EmbeddingPrompt.format (Swift). Only ASCII whitespace is used in titles below,
# so str.strip() and Swift's trimmingCharacters(in: .whitespacesAndNewlines) agree.
def format_prompt(kind: str, text: str, title: str | None) -> str:
    if kind == "query":
        return f"task: search result | query: {text}"
    t = title.strip() if title is not None else None
    return f"title: {t if t else 'none'} | text: {text}"


KO_PARAGRAPH = (
    "macOS의 시스템 설정 앱에서는 블루투스, Wi-Fi, 디스플레이, 사운드, 알림, 개인정보 보호 및 보안 같은 항목을 "
    "한곳에서 관리할 수 있다. 예를 들어 화면 밝기를 조절하려면 디스플레이 패널을 열고, 밤에 눈의 피로를 줄이려면 "
    "Night Shift 일정을 설정하면 된다. 키보드 단축키를 바꾸고 싶다면 키보드 패널의 단축키 항목에서 원하는 동작을 "
    "선택해 새로운 조합을 지정한다. 배터리 사용 시간이 짧게 느껴진다면 저전력 모드를 켜거나 백그라운드에서 많은 "
    "에너지를 쓰는 앱을 확인해 보는 것이 좋다. "
)
EN_PARAGRAPH = (
    "A launcher on the Mac should open applications, jump to the right System Settings pane, and run small "
    "commands such as locking the screen or emptying the trash without forcing the user to remember exact names. "
    "Semantic search helps when the user types a description instead of a title, for example 'make the screen "
    "warmer at night' should still find Night Shift, and 'connect my headphones' should surface Bluetooth. "
    "Lexical matching remains important for short prefixes and acronyms, so both signals are fused. "
)
MIXED_PARAGRAPH = (
    "Spotlight 대신 쓸 launcher를 만들 때 가장 중요한 것은 latency다. 사용자가 ⌥Space를 누르고 '사파리'나 "
    "'safari'를 입력하면 100ms 안에 결과가 보여야 한다. EmbeddingGemma 2 모델은 768차원 vector를 만들고, "
    "Matryoshka truncation으로 256차원까지 줄여도 검색 품질이 크게 떨어지지 않는다. "
)


def long_text(paragraphs: list[str], tokenizer, target_tokens: int) -> str:
    """Repeat paragraphs until the text is ~target_tokens tokens long (deterministic)."""
    out = ""
    i = 0
    while len(tokenizer(out, add_special_tokens=False)["input_ids"]) < target_tokens:
        out += paragraphs[i % len(paragraphs)]
        i += 1
    return out.strip()


def build_inputs(tokenizer) -> list[dict]:
    q = lambda id_, text: {"id": id_, "kind": "query", "title": None, "text": text}
    d = lambda id_, title, text: {"id": id_, "kind": "document", "title": title, "text": text}
    long_ko = long_text([KO_PARAGRAPH], tokenizer, 1000)
    long_en = long_text([EN_PARAGRAPH], tokenizer, 1000)
    long_mixed = long_text([MIXED_PARAGRAPH, EN_PARAGRAPH, KO_PARAGRAPH], tokenizer, 1000)
    return [
        # Very short queries (1-3 words)
        q("q-ko-1w", "블루투스"),
        q("q-ko-2w", "화면 밝기"),
        q("q-ko-3w", "다크 모드 켜기"),
        q("q-en-1w", "calculator"),
        q("q-en-2w", "wifi settings"),
        q("q-en-3w", "lock the screen"),
        q("q-mixed-2w", "Safari 열기"),
        q("q-mixed-3w", "night shift 설정"),
        q("q-single-char", "a"),
        q("q-jamo", "ㅂㄹㅌㅅ"),
        q("q-empty", ""),
        # Sentence-length queries
        q("q-ko-sentence", "맥북 배터리가 너무 빨리 닳는데 어떻게 해야 하나요?"),
        q("q-en-sentence", "How do I take a screenshot of a single window on macOS?"),
        q("q-mixed-sentence", "VS Code에서 최근에 연 project 폴더 다시 열기"),
        q("q-symbols", "C++ / Swift 6 concurrency: @MainActor vs actor?"),
        q("q-emoji", "🎵 음악 재생 ▶️ play music"),
        q("q-whitespace", "  leading and trailing spaces  "),
        # Documents with titles (launcher item cards)
        d("d-app-calculator", "계산기", "Calculator 계산기 앱. 사칙연산, 공학용 계산, 프로그래머 모드를 지원한다."),
        d("d-app-safari", "Safari", "Safari 웹 브라우저. Open websites, bookmarks, tabs, private browsing. 사파리 인터넷"),
        d("d-setting-bluetooth", "Bluetooth", "시스템 설정 › 블루투스. 무선 헤드폰, 키보드, 마우스 연결 및 해제. connect headphones"),
        d("d-setting-display", "디스플레이", "System Settings › Displays. 밝기, 해상도, Night Shift, True Tone, 외장 모니터 배열"),
        d("d-setting-battery", "배터리", "저전력 모드, 배터리 상태, 충전 최적화. Battery health and Low Power Mode."),
        d("d-cmd-lock", "Lock Screen", "화면 잠금. Immediately lock the Mac and show the login window. 자리 비움"),
        d("d-cmd-empty-trash", "휴지통 비우기", "Empty Trash: permanently delete all items in the Trash. 휴지통에 있는 모든 항목을 영구 삭제"),
        d("d-shortcut", "아침 루틴", "Shortcuts automation: 날씨 확인, 캘린더 일정 읽기, 음악 재생 start playlist"),
        d("d-title-short-text", "Terminal", "터미널"),
        d("d-title-whitespace", "   ", "제목이 공백뿐인 문서는 none으로 처리된다."),
        # Documents without titles
        d("d-notitle-ko", None, "키보드 단축키를 변경하려면 시스템 설정의 키보드 패널을 연다."),
        d("d-notitle-en", None, "The northern lights are caused by charged particles from the sun."),
        d("d-notitle-mixed", None, "README.md 파일에 build 방법과 test 명령어를 정리했다: swift test --filter EmbedCoreTests"),
        d("d-notitle-1w", None, "설정"),
        d("d-notitle-code", None, "func dot(_ a: [Float], _ b: [Float]) -> Float { vDSP.dot(a, b) }"),
        d("d-notitle-multiline", None, "첫째 줄\n둘째 줄\n\nthird line with a tab\tand trailing newline\n"),
        # Long (~1000 tokens)
        d("d-long-ko", "macOS 시스템 설정 안내", long_ko),
        d("d-long-en", "Launcher design notes", long_en),
        d("d-long-mixed", None, long_mixed),
        q("q-long-en", long_en),
        q("q-long-mixed", long_mixed),
        # Medium-length documents (~100-300 tokens)
        d("d-medium-ko", "개인정보 보호", (KO_PARAGRAPH * 2).strip()),
        d("d-medium-en", None, (EN_PARAGRAPH * 2).strip()),
    ]


def build_truncation_inputs(tokenizer) -> list[dict]:
    long_en = long_text([EN_PARAGRAPH], tokenizer, 600)
    long_ko = long_text([KO_PARAGRAPH], tokenizer, 600)
    return [
        {"id": "t-doc-en", "kind": "document", "title": "Launcher design notes", "text": long_en},
        {"id": "t-doc-ko", "kind": "document", "title": None, "text": long_ko},
        {"id": "t-query-mixed", "kind": "query", "title": None, "text": long_text([MIXED_PARAGRAPH], tokenizer, 400)},
        {"id": "t-short", "kind": "query", "title": None, "text": "블루투스"},  # shorter than the limit: unchanged
    ]


def embed_rows(model: SentenceTransformer, items: list[dict], max_seq_length: int) -> list[dict]:
    model.max_seq_length = max_seq_length
    tok = model.tokenizer
    rows = []
    for item in items:
        prompt = format_prompt(item["kind"], item["text"], item["title"])
        ids = tok(prompt, add_special_tokens=True, truncation=True, max_length=max_seq_length)["input_ids"]
        # batch_size=1: no padding at all in the reference.
        v = model.encode([prompt], batch_size=1, convert_to_numpy=True, normalize_embeddings=True)[0]
        v = v.astype(np.float64)
        row = dict(item)
        row["prompt"] = prompt
        row["token_ids"] = [int(x) for x in ids]
        row["n_tokens"] = len(ids)
        row["embedding"] = {str(FULL_DIMS): [float(x) for x in (v / np.linalg.norm(v)).astype(np.float32)]}
        for dims in MRL_DIMS:
            t = v[:dims]
            row["embedding"][str(dims)] = [float(x) for x in (t / np.linalg.norm(t)).astype(np.float32)]
        rows.append(row)
        print(f"  {row['id']:<22} tokens={row['n_tokens']:<5} norm={np.linalg.norm(v):.6f}")
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(Path(__file__).with_name("reference.json")))
    parser.add_argument("--revision", default="main")
    parser.add_argument("--attn", default="sdpa", choices=["sdpa", "eager"])
    args = parser.parse_args()

    torch.manual_seed(0)
    sha = model_info(MODEL_ID, revision=args.revision).sha
    t0 = time.time()
    model = SentenceTransformer(
        MODEL_ID,
        revision=sha,
        device="cpu",
        model_kwargs={"dtype": torch.float32, "attn_implementation": args.attn},
        config_kwargs={"vision_config": None, "audio_config": None},
    )
    model.eval()
    params = {str(p.dtype) for p in model.parameters()}
    assert params == {"torch.float32"}, f"reference must run in fp32, got {params}"
    print(f"loaded {MODEL_ID}@{sha} in {time.time() - t0:.1f}s, params dtype {params}")

    with torch.inference_mode():
        print("main set:")
        main_rows = embed_rows(model, build_inputs(model.tokenizer), MAX_SEQ_LENGTH)
        print(f"truncation set (max_tokens={TRUNCATION_MAX_TOKENS}):")
        trunc_rows = embed_rows(model, build_truncation_inputs(model.tokenizer), TRUNCATION_MAX_TOKENS)

    out = {
        "model_id": MODEL_ID,
        "revision": sha,
        "prompt_version": PROMPT_VERSION,
        "dtype": "float32",
        "device": "cpu",
        "attn_implementation": args.attn,
        "text_only": True,
        "dimensions": [FULL_DIMS, *MRL_DIMS],
        "mrl": "first-k then L2 re-normalize",
        "versions": {
            "python": platform.python_version(),
            "torch": torch.__version__,
            "transformers": transformers.__version__,
            "sentence_transformers": sentence_transformers.__version__,
            "numpy": np.__version__,
        },
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "max_tokens": MAX_SEQ_LENGTH,
        "items": main_rows,
        "truncation": {"max_tokens": TRUNCATION_MAX_TOKENS, "items": trunc_rows},
    }
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {args.out}: {len(main_rows)} + {len(trunc_rows)} rows")


if __name__ == "__main__":
    main()
