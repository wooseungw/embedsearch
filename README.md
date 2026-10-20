# EmbedSearch

맥에서 오프라인으로 동작하는 의미 검색 런처입니다. `⌥Space`로 노치에서 펼쳐지는 검색창을 열고 앱, 시스템 설정, 내장 명령, 단축어, 파일(PDF 본문과 이미지)을 찾습니다. 글자 매칭(한글 초성 포함)과 EmbeddingGemma 2 임베딩 검색을 섞어서, "계산기"로 Calculator를, 내용을 설명하는 말로 PDF를 찾을 수 있습니다. 모델은 MLX로 기기 안에서 돌고, 검색어나 파일 내용이 밖으로 나가지 않습니다.

## 요구 사항

- Apple Silicon Mac (arm64 전용)
- macOS 15 이상
- 선택: Java 11 이상 — 있으면 PDF를 [opendataloader-pdf](https://github.com/opendataloader-project/opendataloader-pdf)로 읽어 읽기 순서, 제목, 표 구조를 살립니다. 없으면 PDFKit으로 읽습니다.

## 설치 (빌드된 앱)

1. [Releases](https://github.com/wooseungw/embedsearch/releases)에서 `EmbedSearch-<버전>-arm64.zip`을 받아 풀고, `EmbedSearch.app`을 `/Applications`나 `~/Applications`로 옮깁니다.
2. 처음 열면 macOS가 실행을 막습니다. 앱이 Apple 공증을 받지 않았기 때문입니다. 한 번만 풀어주면 됩니다:
   - **시스템 설정 → 개인정보 보호 및 보안**에서 맨 아래 EmbedSearch 항목의 **그래도 열기**를 누릅니다. (macOS 15부터는 Finder에서 우클릭 → 열기로는 통과되지 않습니다.)
   - 또는 터미널에서:
     ```sh
     xattr -dr com.apple.quarantine /Applications/EmbedSearch.app
     ```

## 처음 실행할 때

- 메뉴 막대 앱입니다. Dock에는 아이콘이 없고, `⌥Space`로 검색창을 엽니다. 단축키는 설정(`⌘,`)에서 바꿀 수 있습니다.
- 임베딩 모델 [`mlx-community/embeddinggemma-2-bf16`](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)(약 1.4GB)을 처음 한 번 HuggingFace에서 받아 `~/.cache/huggingface/hub`에 둡니다. 계정이나 토큰은 필요 없습니다. 받는 동안에도 글자 매칭 검색은 됩니다.
- 파일 검색은 설정에서 폴더를 추가해야 켜집니다. 문서·데스크탑·다운로드 폴더를 추가하면 macOS가 접근 권한을 묻습니다.
- 다크 모드 전환, 휴지통 비우기 같은 시스템 명령은 처음 쓸 때 System Events/Finder 제어 권한을 묻습니다.

## 소스에서 빌드

Xcode가 필요합니다(MLX의 Metal 셰이더 때문에 Command Line Tools만으로는 안 됩니다).

```sh
brew install xcodegen
git clone https://github.com/wooseungw/embedsearch.git
cd embedsearch
scripts/build-app.sh     # → build/EmbedSearch.app
scripts/install.sh       # ~/Applications에 설치하고 실행
```

- 키체인에 Apple Development 인증서가 있으면 그걸로 서명하고, 없으면 ad hoc으로 서명합니다. ad hoc 서명은 빌드할 때마다 macOS가 권한을 다시 묻습니다. `ADHOC=1`을 주면 인증서가 있어도 ad hoc으로 서명합니다.
- `scripts/package-release.sh`는 Releases에 올릴 zip을 만듭니다.
- 설계와 모듈 구조는 [`docs/DESIGN.md`](docs/DESIGN.md)에 있습니다.

## 라이선스

[MIT](LICENSE). 함께 쓰는 것들:

- [EmbeddingGemma 2](https://huggingface.co/mlx-community/embeddinggemma-2-bf16) — Apache-2.0. 앱에 들어 있지 않고, 실행할 때 받습니다.
- [opendataloader-pdf](https://github.com/opendataloader-project/opendataloader-pdf) — Apache-2.0. 앱에 JAR가 들어 있고, `LICENSE`, `NOTICE`, `THIRD_PARTY`를 함께 넣습니다.
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), [GRDB.swift](https://github.com/groue/GRDB.swift), [swift-transformers](https://github.com/huggingface/swift-transformers), [swift-huggingface](https://github.com/huggingface/swift-huggingface), [swift-argument-parser](https://github.com/apple/swift-argument-parser) — 각 저장소의 라이선스를 따릅니다.
