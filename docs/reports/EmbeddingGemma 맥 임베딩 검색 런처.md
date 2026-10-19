# 네이티브 Swift와 하이브리드 검색으로 EmbeddingGemma 2 런처 만들기

`google/embeddinggemma-2`는 2026년 10월 6일 공개된 **Apache-2.0·비게이트** 모델이다. 740M 멀티모달 체크포인트에서 **270M 텍스트 경로만 로드해 8,192 토큰 입력과 768차원 출력(MRL 512/256/128)의 임베딩**을 만들 수 있으므로, 완전 로컬 맥 런처의 엔진으로 적합하다. 다만 텍스트 검색 품질은 v1과 사실상 같고(MMTEB 61.36 대 61.15), 한국어 근거라고는 v1이 Belebele 한↔영 교차언어 검색에서 소형 모델 중 1위를 했다는 기록이 전부다. 그래서 문헌조사의 결론은 런처 품질이 모델보다 **한국어 토크나이저를 갖춘 BM25와 dense의 하이브리드, 최근성(frecency) 가중, 소스별 텍스트 카드 설계**에서 결정된다는 것이다. 권장 스택은 non-activating `NSPanel`에 SwiftUI를 얹은 **네이티브 Swift 셸**이다. 단축키는 `sindresorhus/KeyboardShortcuts`(Carbon 기반, 권한 프롬프트 없음)로 ⌥Space를 등록한다. 추론은 `ml-explore/mlx-swift-lm`의 **MLXEmbedders**(v2 지원 PR #684가 10월 12일 main에 병합, 태그 없음)를 1순위로 두고, FluidInference Core ML(ANE)과 llama.cpp XCFramework를 교체 가능한 후보로 둔다. 저장은 **GRDB, FTS5, 256차원 int8 brute-force 벡터를 묶은 단일 SQLite 파일**로 한다. GitHub 조사에서 Tinycast, Sol, Vicinae 같은 성숙한 오픈소스 런처는 많았지만 **로컬 임베딩 검색을 내장한 런처는 하나도 없었다**. 반면 데이터 수집에는 Maccy(클립보드), raycast/extensions(브라우저 기록), 시스템 설정의 한·영 `.searchTerms` 키워드 파일처럼 재사용할 코드와 데이터가 충분하다. 가장 큰 위험은 런타임 성숙도다. v2 통합은 모두 생긴 지 일주일이 안 됐고, v1 때 MLX·GGUF·mlx-embeddings에서 **조용히 틀린 벡터**를 내는 버그가 반복됐다. 따라서 sentence-transformers fp32 대비 패리티 테스트와 모델 버전을 기록한 인덱스가 필수다. 제품 차원의 함정도 네 가지 있다. ChatGPT/Codex 앱이 ⌥Space를 끌 수 없게 점유하는 충돌, 한글 IME 조합 처리, macOS 15.4 이후의 클립보드 접근 경고, Safari 기록에 필요한 전체 디스크 접근 권한이다.

## EmbeddingGemma 2는 라이선스·컨텍스트·코드 성능을 바꿨지만 텍스트 품질은 v1 그대로다

### 체크포인트 하나에서 270M 텍스트 경로만 꺼내 쓴다

`google/embeddinggemma-2`는 실재하는 저장소다. **게이트 없는 Apache-2.0**이며 2026년 10월 6일 공개됐다 ([HF API](https://huggingface.co/api/models/google/embeddinggemma-2); [Google 블로그](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2)).

크기별 체크포인트 묶음이 아니라 **740M 멀티모달 체크포인트 하나**다. 텍스트 경로는 270M(트랜스포머 130M, 임베딩 테이블 140M)이고, 비전(170M)과 오디오(300M) 인코더는 로드할 때 붙일지 고른다. 구글 개발자 가이드에 따르면 텍스트/코드 전용 270M, 텍스트+비전 440M, 텍스트+오디오 570M, 전체 740M 네 구성은 모두 같은 벡터 공간을 쓴다. 그래서 나중에 인코더를 추가해도 기존 임베딩을 다시 계산할 필요가 없다 ([Google Developers Blog](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/)). `google/embeddinggemma-2-300m` 같은 저장소는 없다. 전작 `google/embeddinggemma-300m`은 여전히 Gemma Terms 수동 게이트 아래 있다 ([HF API v1](https://huggingface.co/api/models/google/embeddinggemma-300m)).

런처에는 이 구성이 유리하다. 텍스트 전용 270M만 메모리에 올리면 되고, HF 로그인이나 약관 동의 없이 가중치를 앱에 번들하거나 첫 실행 때 내려받을 수 있다. 다만 모델 카드가 Gemma Prohibited Use Policy 준수도 함께 요구한다. 상용 배포라면 Apache-2.0과 이 정책이 어떻게 결합되는지 법무 검토로 확인해야 한다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2)).

### 8K 컨텍스트, 그러나 256K 표기는 함정이다

구조는 Gemma 4에서 파생된 양방향 인코더다. 24층, 모델 차원 512, 어휘 262,144개에 평균 풀링과 512→768 투영을 쓴다. **컨텍스트는 8,192 토큰**으로 v1의 4배이고, 768차원 출력을 MRL로 512/256/128차원까지 자를 수 있다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2)).

첫 번째 함정은 컨텍스트 표기다. `config.json`의 `max_position_embeddings`는 262,144이고 Ollama는 모든 v2 태그에 "256K context window"를 표시하지만, 학습된 지원 한도는 8,192 토큰이다. 게다가 `tokenizer_config.json`은 `model_max_length`를 비워 둔다 ([config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config.json); [Ollama](https://ollama.com/library/embeddinggemma-2); [tokenizer_config.json](https://huggingface.co/google/embeddinggemma-2/blob/main/tokenizer_config.json)). 실제로 LM Studio는 기본 설정에서 128 GB 버퍼를 잡으려다 실패했고, `--context-length 8192`를 줘야 동작했다 ([lmstudio-bug-tracker #2486](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2486)). 그러니 어떤 런타임을 쓰든 앱이 입력 상한을 8,192 이하로 직접 고정해야 한다.

슬라이딩 윈도 크기는 카드에 1,024, config에 512로 서로 어긋나며 아직 해명되지 않았다. 다만 512 토큰 이하 청크에는 영향이 없다.

### 접두어·정밀도·재정규화를 어기면 오류 없이 품질이 떨어진다

품질은 사용 규약을 지키느냐에 달려 있다. 정석은 비대칭 프롬프트다. 검색 쿼리 앞에는 `task: search result | query: {q}`를, 문서 앞에는 `title: {제목 또는 none} | text: {본문}`을 붙인다. 그런데 sentence-transformers 설정의 `default_prompt_name`이 `null`이라서, `prompt_name`을 넘기지 않으면 접두어가 전혀 붙지 않는다 ([config_sentence_transformers.json](https://huggingface.co/google/embeddinggemma-2/blob/main/config_sentence_transformers.json)). 접두어 문자열은 학습된 토큰이다. 한국어 질의라도 접두어는 영어 그대로 두고 질의 부분만 한국어로 넣는다.

정밀도는 **bf16 또는 fp32만 허용되고 fp16은 금지**다. 카드는 fp16에서 오류 없이 NaN이나 품질이 떨어진 임베딩이 나온다고 경고한다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2)). Core ML 포팅팀이 원인을 확인했다. 활성값이 약 2,000까지 올라가 RMSNorm 내부의 제곱이 fp16 범위를 넘는다. 단순 fp16 변환은 기준 대비 코사인 0.95에 그쳤고, 행별 최대 절댓값으로 먼저 나누는 우회로 0.9996을 회복했다 ([FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)).

MRL로 차원을 자른 뒤에는 반드시 다시 L2 정규화해야 한다. 이를 빠뜨리면 경고 없이 순위 품질이 떨어진다. 라이브러리는 sentence-transformers ≥ 6.1.0과 `embedding_gemma2`를 지원하는 transformers 빌드(저장소는 5.18.0.dev0으로 저장됨)가 필요하다. 버전 고정이 왜 중요한지는 v1 때 드러났다. 출시 초기 "짧은 내용을 선호하는 것 같다"는 스레드에 댓글 24개가 달렸는데, 원인은 구버전 transformers가 양방향 대신 인과(causal) 어텐션을 쓴 것이었다 ([HF discussion #8](https://huggingface.co/google/embeddinggemma-300m/discussions/8)).

### 개선은 코드에 몰렸고, 256차원 절단은 거의 공짜다

v2의 개선은 텍스트가 아니라 코드와 멀티모달에 몰려 있다. MTEB(Multilingual, v2) 평균은 **61.36으로 v1의 61.15와 사실상 같다**. MTEB(eng, v2)는 68.46으로 v1(69.67)보다 약간 낮다. MTEB(Code)만 **78.68 대 68.76**으로 크게 올랐다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2); [ai.google.dev v1 카드](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)). 구글 직원도 일반 텍스트 성능이 버전 1과 일관된다고 답했다. 다국어 검색 과제 550개짜리 HAKARI-Bench의 작성자 역시 두 버전 점수가 매우 비슷하다고 보고하며, 텍스트만 쓴다면 업그레이드 이유는 2K→8K 컨텍스트라고 평가했다 ([HF discussion #5](https://huggingface.co/google/embeddinggemma-2/discussions/5)).

MRL 절단의 비용은 작다. v2 카드 수치로 계산하면 256차원은 다국어 점수의 **98.5%**, 영어의 99.0%, 코드의 96.8%를 유지한다. 128차원에서는 각각 94.3%, 95.9%, 90.8%로 떨어지고, 코드가 가장 민감하다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2)). 파일명과 코드 식별자를 많이 검색하는 런처라면 상주 인덱스는 256차원을 하한으로 잡는다.

### 한국어에서는 MMTEB 순위와 검색 품질이 따로 움직인다

| 모델 | 텍스트 파라미터 | 차원 | 컨텍스트 | MMTEB | Belebele ko-ko | ko↔en 교차언어 | 라이선스 |
|---|---|---|---|---|---|---|---|
| google/embeddinggemma-2 | 270M (전체 740M) | 768 (MRL) | 8,192 | 61.36 | 미측정 | 미측정 | Apache-2.0 |
| google/embeddinggemma-300m (v1) | 308M | 768 (MRL) | 2,048 | 61.15 | **0.9414** | **0.9513 / 0.9293** | Gemma Terms(게이트) |
| Qwen/Qwen3-Embedding-0.6B | 595M | 1,024 (MRL) | 32K | 64.34 | 0.9222 | 0.913 / 0.8618 | Apache-2.0 |
| microsoft/harrier-oss-v1-270m | 270M | 640 | 32,768 | 66.5 (벤더) | 0.8388 | 0.8519 / 0.7752 | MIT |
| jinaai/jina-embeddings-v5-text-nano | 239M | 768 (MRL) | 8,192 | 65.5 (벤더) | 0.9350 | 0.9468 / 0.9175 | CC BY-NC 4.0 |
| intfloat/multilingual-e5-large-instruct | 560M | 1,024 | – | 63.22 | 0.9361 | 0.9243 / 0.8622 | – |
| BAAI/bge-m3 | 568M | 1,024 | – | 59.56 | 0.9315 | 0.9032 / 0.8832 | – |
| ibm-granite/granite-embedding-311m-multilingual-r2 | 311M | 768 (MRL) | 32,768 | 미보고 | 0.8857 | 0.8887 / 0.827 | Apache-2.0 |

교차언어 열은 `kor_Hang-eng_Latn` / `eng_Latn-kor_Hang` 부분집합의 nDCG@10이다. 수치는 각 모델 카드, EmbeddingGemma 논문의 Table 5, 공식 MTEB 결과 저장소의 원자료에서 가져왔다 ([HF 모델 카드](https://huggingface.co/google/embeddinggemma-2); [harrier 카드](https://huggingface.co/microsoft/harrier-oss-v1-270m); [jina v5 nano 카드](https://huggingface.co/jinaai/jina-embeddings-v5-text-nano); [arXiv 2509.20354 HTML](https://arxiv.org/html/2509.20354v3); [MTEB results 저장소](https://github.com/embeddings-benchmark/results/tree/main/results); [BelebeleRetrieval.json](https://github.com/embeddings-benchmark/results/blob/main/results/google__embeddinggemma-300m/64614b0b8b64f0c6c1e52b07e4e9a4e8fe4d2da2/BelebeleRetrieval.json)).

2026년 기준 1B 미만 모델 사이에서 v2의 MMTEB 61.36은 중위권이다. harrier-270m(MIT)과 jina v5 nano(비상업)는 평균에서 4~5점 앞선다. 그러나 한국어 신호는 다른 그림을 그린다. Belebele 한국어 단일언어 검색과 한↔영 교차언어 검색 모두에서 v1이 1위였다. 반면 MMTEB 상위권인 harrier-270m은 두 지표에서 뚜렷하게 약하다. 한국어 질의로 영어 문서를 찾고 그 반대도 해야 하는 런처에 가장 가까운 공개 지표가 바로 이 교차언어 부분집합이다.

한계도 분명하다. 한국어 검색의 주력 스위트인 MTEB(kor, v2)의 9개 과제 표에 EmbeddingGemma는 v1과 v2 모두 없다. 공식 결과 저장소에는 v2 디렉터리 자체가 없다 ([KURE-v2 카드](https://huggingface.co/nlpai-lab/KURE-v2); [GitHub API 404](https://api.github.com/repos/embeddings-benchmark/results/contents/results/google__embeddinggemma-2)). 그 표의 1위는 `nlpai-lab/KURE-v2`(0.8160, 154M, ColBERT 다중 벡터, Apache-2.0)다. 하지만 다중 벡터 인덱싱이 필요해서 가벼운 런처에 넣기에는 무겁다. 결국 v2의 한국어 품질은 "v1과 같다"는 구글의 진술과 v1 수치에 기댄 **간접 증거**일 뿐이다. 출시 전에 자체 한국어 평가셋에서 harrier와 Qwen3를 도전자로 두고 확인해야 한다.

### 논문은 v1 한 편뿐이고, v2 기술 보고서는 없다

모델 문헌은 v1 논문 한 편이 전부다. arXiv 2509.20354 "EmbeddingGemma: Powerful and Lightweight Text Representations"(저자 89명, 2025년 9월)가 쓴 기법은 네 가지다. Gemma 3를 T5Gemma 방식의 인코더-디코더로 바꾼 뒤 그 인코더로 초기화하고, Gemini Embedding의 질의·문단·하드 네거티브 임베딩을 맞추는 기하학적 증류를 하며, 전역 직교 정규화 기반의 spread-out 정규화를 걸고, 베이지안 최적화로 고른 데이터 혼합별 체크포인트를 평균하는 model souping을 한다. 논문은 이 결합으로 500M 미만 모델 중 MTEB 최고를 달성했고, 가중치를 양자화하거나 출력을 절단해도 그 우위가 유지된다고 보고한다 ([arXiv abs](https://arxiv.org/abs/2509.20354); [arXiv HTML v3](https://arxiv.org/html/2509.20354v3)). 같은 논문의 XOR-Retrieve 한국어 R@5kt는 83.86이다.

**v2의 논문이나 기술 보고서는 2026년 10월 13일 현재 없다.** 모델 카드, 출시 블로그, 개발자 가이드가 문서의 전부다. "Gemini Embedding 2"(arXiv 2605.27295)는 API로 제공되는 다른 모델이므로 혼동하지 않아야 한다 ([arXiv 2605.27295](https://arxiv.org/pdf/2605.27295)). 끝으로, v1과 v2는 투영 헤드와 벡터 공간이 다르다. 모델을 바꾸면 전체를 재색인해야 하므로, 인덱스의 모든 벡터에 모델 ID, 차원, 프롬프트 버전을 기록해 둔다.

## 검색 문헌은 dense 단독이 아닌 한국어 BM25·최근성 하이브리드를 가리킨다

런처 쿼리는 웹 검색과 성격이 다르다. Microsoft의 Stuff I've Seen은 파일·메일·웹·일정을 하나로 색인해 234명에게 배포했다. 쿼리는 평균 **1.59단어**였고 **25%가 사람 이름**을 포함했으며, 정렬은 날짜 기준(5,037회)이 관련도 기준(2,038회)의 두 배를 넘었다 ([SIS 논문](https://www.cs.odu.edu/~sampath/courses/w17/cs599/papers/SISCore-SIGIR2003-Final.pdf)). Yahoo 로그에서는 최대 40%가 이미 본 것을 다시 찾는 질의였다 ([Teevan et al. 2007](https://people.csail.mit.edu/teevan/work/publications/papers/sigir07.pdf)). 짧고, 고유명사 중심이고, 다시 찾기가 주가 되는 쿼리는 dense 검색이 가장 약한 영역이다. 아래 문헌들이 그 근거와 처방을 준다.

### 문헌 열여섯 편이 가리키는 설계 결정

| 문헌 | 핵심 결과 | 런처 설계 함의 |
|---|---|---|
| BEIR ([arXiv 2104.08663](https://arxiv.org/abs/2104.08663)) | 제로샷에서 BM25가 강건한 기준선, dense는 자주 뒤처짐 | dense 단독 금지 |
| EntityQuestions ([arXiv 2109.08535](https://arxiv.org/abs/2109.08535)) | 엔티티 중심 질의에서 dense가 sparse에 "크게" 열세 | 앱·파일·사람 이름은 어휘 매칭이 담당 |
| SPAR ([arXiv 2110.06918](https://arxiv.org/abs/2110.06918)) | dense가 핵심 구문·희귀 엔티티 매칭에서 BM25에 뒤처짐 | 코드 식별자·URL은 BM25 경로 |
| RRF, Cormack et al. SIGIR 2009 ([PDF](http://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf)) | k=60 고정으로 개별 시스템보다 일관되게 우수 | 학습 없는 기본 융합 |
| Bruch et al. ([arXiv 2210.11934](https://arxiv.org/abs/2210.11934)) | 볼록 결합(CC)이 RRF보다 우수하고 적은 예제로 튜닝 가능 | 라벨이 쌓이면 CC로 전환 |
| Better Than Whitespace ([arXiv 2210.05481](https://arxiv.org/html/2210.05481)) | Mr.TyDi 한국어 BM25 Recall@100이 공백 토큰화 0.396 → 형태소 분석기 0.619 | 한국어 토크나이저 필수 |
| SPLADE·SPLADE++·BGE-M3 ([2107.05720](https://arxiv.org/abs/2107.05720), [2205.04733](https://arxiv.org/abs/2205.04733), [2402.03216](https://arxiv.org/abs/2402.03216)) | 학습형 sparse 표현 | 영어 중심이거나 두 번째 568M 인코더가 필요해 생략 |
| MRL, Kusupati et al. ([arXiv 2205.13147](https://arxiv.org/abs/2205.13147)) | 저차원 후보 선별 → 고차원 재순위화로 단일 검색과 같은 정확도, 실측 약 14배 가속 | 256차원 상주, 768차원 재채점 |
| Embedding Quantization ([HF 블로그](https://huggingface.co/blog/embedding-quantization)), BPR ([arXiv 2106.00882](https://arxiv.org/abs/2106.00882)) | int8은 4배 절감에 약 97~99% 유지, binary는 32배 절감에 75~96%(모델 의존) | int8이 기본, binary는 사전 필터 |
| HNSW ([arXiv 1603.09320](https://arxiv.org/abs/1603.09320)), Faiss 가이드 | 질의가 적으면 Flat(정확 검색)이 가장 효율적 | 50만 청크 이하는 brute force |
| 의미 기반 청킹 비용 연구 ([arXiv 2410.13070](https://arxiv.org/abs/2410.13070)) | 의미 기반 청킹의 비용이 성능으로 정당화되지 않음 | 문단·제목 경계 고정 크기 청크 |
| Late chunking ([arXiv 2409.04701](https://arxiv.org/html/2409.04701v3)) | 평균 nDCG@10 +1.5~1.9 | 선택 사항, v2의 8K로 적용 범위 확대 |
| Contextual Retrieval ([Anthropic](https://www.anthropic.com/news/contextual-retrieval)) | 맥락 추가로 실패율 35% 감소, BM25 추가 시 49%, 재순위화 추가 시 67% 감소 | `title:` 슬롯에 파일명·경로·제목 |
| Kim & Croft SIGIR 2010 ([PDF](https://ciir-publications.cs.umass.edu/getpdf.php?id=915)) | 원하는 문서 유형 예측이 데스크톱 검색의 핵심 | 쿼리 의도·유형 라우팅 |
| Qwen3 Embedding ([arXiv 2506.05176](https://arxiv.org/abs/2506.05176)) | Qwen3-Reranker-0.6B MMTEB-R 66.36 | Enter 시 선택적 재순위화 |
| InPars ([arXiv 2202.05144](https://arxiv.org/abs/2202.05144)), Thomas et al. ([arXiv 2309.10621](https://arxiv.org/abs/2309.10621)) | LLM이 생성한 질의와 LLM 관련성 라벨이 인간 라벨러 수준 | 개인 평가셋을 빠르게 확장 |

### RRF로 시작해 개인 라벨 40개가 쌓이면 볼록 결합으로 옮긴다

하이브리드가 dense 단독보다 낫다는 증거는 최신 임베딩에서도 같다. Anthropic의 측정에서 top-20 검색 실패율은 기본 임베딩 5.7%에서 맥락 임베딩 3.7%, 맥락 BM25 추가 시 2.9%, 재순위화 추가 시 1.9%로 줄었다 ([Anthropic](https://www.anthropic.com/news/contextual-retrieval)).

융합 방식은 단계적으로 고른다. 처음에는 파라미터 튜닝이 필요 없는 RRF(k=60)를 쓴다 ([Cormack et al.](http://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf)). 개인 질의 라벨이 쌓이면 볼록 결합(CC)으로 옮긴다. Bruch 등은 CC가 도메인 안팎 모두에서 RRF를 이기고 적은 예제로 튜닝된다는 것을 보였다. Elastic은 약 40개 질의로 CC가 RRF를 앞섰지만, 최적 가중치가 데이터셋마다 크게 달랐다고 보고했다 ([Bruch et al.](https://arxiv.org/abs/2210.11934); [Elastic](https://www.elastic.co/search-labs/blog/improving-information-retrieval-elastic-stack-hybrid)). 두 결과 모두 "사용자 본인의 라벨로 튜닝하라"로 수렴한다.

구현도 단순하다. Alex Garcia는 FTS5와 sqlite-vec의 RRF를 CTE 두 개를 `FULL OUTER JOIN`하는 SQL 하나로 작성하는 방법을 공개했다 ([alexgarcia.xyz](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/index.html)).

### 한국어 BM25는 공백 토큰화를 버리면 재현율이 56% 오른다

한국어에서는 BM25의 토크나이저가 성패를 가른다. Mr.TyDi 한국어에서 공백 토큰화 BM25의 Recall@100은 0.396이었고, Lucene KoreanAnalyzer로 바꾸자 0.619로 **상대 56% 올랐다** ([arXiv 2210.05481](https://arxiv.org/html/2210.05481)).

SQLite FTS5의 기본 `unicode61` 토크나이저는 연속된 문자를 한 토큰으로 묶는다. 그래서 "설정을"처럼 조사가 붙은 어절이 통째로 토큰이 되고, 사실상 공백 토큰화와 같다. `trigram` 토크나이저는 3글자 미만 질의와 매칭되지 않는다. "설정", "지난" 같은 두 음절 핵심어가 많은 한국어에는 치명적이다 ([SQLite FTS5](https://www.sqlite.org/fts5.html)).

대안은 세 가지다. 첫째, Kiwi는 Apache-2.0 C++ 형태소 분석기이고 macOS 빌드를 제공하지만, README 기준 메모리 사용량이 278~694 MB다 ([bab2min/Kiwi](https://github.com/bab2min/Kiwi)). 둘째, 한글 음절 bigram과 공백 토큰을 함께 내보내는 가벼운 커스텀 토크나이저를 GRDB의 `FTS5CustomTokenizer`로 Swift에서 직접 구현할 수 있다 ([GRDB FTS5Tokenizers](https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md)). 셋째, `설정*` 같은 FTS5 접두 질의로 조사를 흡수한다.

상주 런처의 메모리 예산을 생각하면 둘째와 셋째를 함께 쓰는 것이 출발점이다. Kiwi는 평가셋에서 재현율 차이가 확인될 때만 도입한다. 학습형 sparse 방식은 제외한다. SPLADE의 공개 체크포인트는 영어 중심이고, BGE-M3 sparse는 EmbeddingGemma 옆에 568M 인코더를 하나 더 얹어야 하기 때문이다.

### 50만 청크까지는 int8 256차원 brute force가 수 ms다

메모리와 속도는 MRL, 양자화, brute force의 조합으로 해결된다. MRL 원논문의 적응형 검색은 16차원으로 후보 200개를 고른 뒤 2,048차원으로 재순위화했다. 그 결과 단일 검색과 같은 정확도로 실측 약 14배 빨랐다 ([arXiv 2205.13147 HTML](https://arxiv.org/html/2205.13147v4)). HF의 임베딩 양자화 연구에서 int8은 재채점과 함께 약 97~99% 품질을 유지했다. binary는 모델에 따라 74.77%(e5-base-v2)에서 96.45%(mxbai)까지 편차가 컸고, EmbeddingGemma의 binary 보존율은 공개되지 않았다 ([HF 블로그](https://huggingface.co/blog/embedding-quantization)).

규모를 계산하면 50만 청크는 float32 768차원 1.54 GB, int8 768차원 384 MB, int8 256차원 128 MB다. Doug Turnbull은 M4 MacBook Pro에서 NumPy 행렬곱으로 100만×384 float32(약 1.5 GB)를 평균 **12 ms**에 정확 검색했다 ([softwaredoug.com](https://softwaredoug.com/blog/2026/07/29/just-brute-force-embeddings)). 메모리 대역폭에 비례한다고 보면 50만×256 int8은 수 ms 이하다. 이는 환산 추정이므로 대상 Mac에서 측정해야 한다.

Faiss 가이드는 질의가 적은 환경에서 Flat 인덱스가 가장 효율적이라고 하며, Faiss HNSW는 벡터를 삭제할 수 없다 ([Faiss wiki](https://github.com/facebookresearch/faiss/wiki/Guidelines-to-choose-an-index)). 클립보드와 브라우저 기록처럼 계속 추가되고 지워지는 코퍼스에는 HNSW 그래프 유지보다 연속 메모리 brute force가 더 단순하고 정확하다.

### 청크는 단순하게 자르고 맥락은 `title:` 슬롯에 담는다

청킹은 단순한 방식이 이긴다. 의미 기반 청킹은 비용만큼의 성능을 내지 못했다 ([arXiv 2410.13070](https://arxiv.org/abs/2410.13070)). late chunking은 nDCG@10을 평균 1.5~1.9점 올렸고, 청크 겹침은 뚜렷한 이득이 없었다 ([arXiv 2409.04701](https://arxiv.org/html/2409.04701v3)). 따라서 문서는 문단, 제목, 함수 경계 기준으로 256~512 토큰씩 겹침 없이 자르고, 파일마다 문서 수준 벡터를 하나 더 둔다. 그래야 "3월 청구서 pdf" 같은 파일 단위 질의가 엉뚱한 청크가 아니라 파일에 걸린다.

EmbeddingGemma의 `title:` 슬롯에는 "파일명 — 상위 폴더 — 가장 가까운 제목"을 넣는다. Anthropic이 보인 맥락 추가 효과를 거의 비용 없이 얻는 방법이다. 다만 v1 사용자 한 명은 `title: … | text: …` 형식보다 단순 연결이 더 나았다고 보고했다. 구글은 자기 데이터에서 nDCG가 일관되게 높은 쪽을 쓰라고 답했으므로, 이것도 평가셋으로 검증한다 ([HF discussion #35](https://huggingface.co/google/embeddinggemma-300m/discussions/35)). 날짜와 유형은 임베딩 텍스트가 아니라 구조화 필터로 다룬다. "지난주", "march" 같은 시간 표현은 임베딩 유사도보다 질의 파싱으로 처리하는 편이 정확하다.

### 순위는 최근성이 결정하고, 재순위화는 Enter 뒤에만 쓴다

SIS 사용자가 날짜 정렬을 선호했으므로, 최근성 신호는 검증된 공식을 빌려 쓴다. Firefox의 frecency는 방문 유형별 가중치에 반감기 30일의 지수 감쇠를 곱하고, 사용자가 같은 입력 문자열에서 실제로 고른 항목을 frecency보다 먼저 올린다 ([Firefox 문서](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html)). zoxide는 접근할 때마다 점수를 1 더하고, 질의 시점에 최근 1시간이면 ×4, 1일이면 ×2, 1주 이내면 ÷2, 그보다 오래됐으면 ÷4를 적용한다 ([zoxide wiki](https://github.com/ajeetdsouza/zoxide/wiki/Algorithm)). Kim & Croft의 유형 예측은 가벼운 규칙으로 구현할 수 있다. "pdf"나 "문서"는 파일을, "설정"이나 "settings"는 설정 패널을, URL처럼 생긴 토큰은 브라우저 기록을 부스트한다.

재순위화는 Enter 뒤 문서 결과에만 선택적으로 적용한다. `Qwen/Qwen3-Reranker-0.6B`(Apache-2.0)는 벤더 수치로 MMTEB-R 66.36을 기록해, 1차 검색기 단독(64.64)과 `bge-reranker-v2-m3`(58.36)를 넘었다. `jina-reranker-v2-base-multilingual`은 CC-BY-NC라 상용에 쓸 수 없다 ([Qwen3-Reranker-0.6B](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B); [jina-reranker-v2](https://huggingface.co/jinaai/jina-reranker-v2-base-multilingual)). Apple Silicon에서 이들의 지연을 잰 공개 수치는 찾지 못했다.

### 평가는 다시 찾기 지표와 개인 질의 50~150개로 한다

평가 지표는 다시 찾기 성격에 맞춘다. MRR@10과 success@1/5를 1차 지표로 삼고, recall@100은 후보 생성기 점검에, nDCG@10은 문서 질의에 쓴다.

질의는 손으로 쓴 50~150개로 시작한다. 소스(앱·설정, 파일, 브라우저, 클립보드), 언어(한국어, 영어, 혼합), 유형(정확한 이름, 오타, 바꿔 말하기, 시간 표현, 교차언어)을 고르게 섞는다. 여기에 InPars 방식으로 개인 문서에서 LLM이 생성한 질의를 더한다 ([arXiv 2202.05144](https://arxiv.org/abs/2202.05144)). 공개 기준점으로는 한국어 원어민 판정이 들어간 MIRACL을 함께 본다 ([arXiv 2210.09984](https://arxiv.org/abs/2210.09984)).

### 50만 청크 이하에서는 ANN 라이브러리보다 SQLite와 brute force가 맞다

| 라이브러리 | 상태 (2026-10-13) | 라이선스 | Swift 지원 | 런처 적합성 |
|---|---|---|---|---|
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | 8,686★, v7.11.1 | MIT | 네이티브 | FTS5와 Swift 커스텀 토크나이저. 메타데이터·FTS의 중심 |
| [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) | 8,184★, 안정판 v0.1.9, 2026-05 이후 푸시 없음 | MIT/Apache-2.0 | [jkrukowski/SQLiteVec](https://github.com/jkrukowski/SQLiteVec) (50★) | `vec0`, int8/bit, 메타데이터 컬럼. 아직 v1 이전이고 ANN은 알파 |
| [sqliteai/sqlite-vector](https://github.com/sqliteai/sqlite-vector) | 1,180★, 1.1.2 | Apache-2.0 (README) | 공식 패키지 | 일반 BLOB 컬럼. M5 Pro에서 100만×768 INT8이 37.6 ms, recall@20 99.5% |
| [rryam/VecturaKit](https://github.com/rryam/VecturaKit) | 324★, 6.3.0 | MIT | 네이티브 | BM25+벡터 하이브리드 내장(볼록 결합), Accelerate brute force, MLX 임베더. 프로토타입용 |
| [unum-cloud/USearch](https://github.com/unum-cloud/USearch) | 4,333★, v2.26.4 | Apache-2.0 | 공식 SPM | HNSW에 삭제·필터·mmap 지원. 100만 개 이상이나 이미지 확장에 대비 |
| [objectbox/objectbox-swift](https://github.com/objectbox/objectbox-swift) | 619★, v5.3.0 | Apache-2.0 | 네이티브 | HNSW와 조건 질의. FTS 없음 |
| [lancedb](https://github.com/lancedb/lancedb), [DuckDB vss](https://duckdb.org/docs/current/core_extensions/vss.html), [faiss](https://github.com/facebookresearch/faiss), [Tantivy](https://github.com/quickwit-oss/tantivy) | 활발 | 다양 | 없음 | Swift SDK가 없거나, 실험 단계이거나, FFI가 필요 |

권장 구성은 SQLite 한 파일에 메타데이터, 청크, FTS5를 두고, 벡터는 별도의 연속 mmap 파일에 두어 Accelerate로 brute force하는 것이다. 두 저장소는 rowid로 연결한다. 의존성이 가장 적고 스캔이 가장 빠르다. VecturaKit의 `VectorSearchEngine`도 Accelerate로 유사도를 계산하고 `TopKSelector`로 상위 결과를 고르는 같은 방식을 쓴다 ([VectorSearchEngine.swift](https://github.com/rryam/VecturaKit/blob/main/Sources/VecturaKit/SearchEngine/VectorSearchEngine.swift)).

벡터까지 SQL 트랜잭션에 넣고 싶다면, 활발히 유지되고 Apple Silicon int8 성능이 공개된 sqlite-vector가 낫다. sqlite-vec는 가장 대중적이지만 v1 이전 버전이고 5개월째 커밋이 없으므로, 쓴다면 버전을 고정한다. macOS 시스템 `libsqlite3`가 확장 로딩을 막는다는 보고도 있다. 확인되지 않은 정보이지만, SQLite를 정적으로 번들하면 피할 수 있다.

VecturaKit은 하이브리드 검색이 바로 동작하는 유일한 Swift 패키지다. 다만 한국어 토크나이저 처리, 메타데이터 필터, frecency가 문서화돼 있지 않다. 프로덕션 엔진보다는 참고 구현으로 적합하다 ([VecturaKit](https://github.com/rryam/VecturaKit)).

## 추론 런타임 후보 셋 모두 v2 지원이 생긴 지 일주일이 안 됐다

### v1의 역사가 보여주듯, 가장 큰 위험은 조용히 틀린 벡터다

v1 시절 사례가 이 위험을 보여준다. MLXEmbedders는 v1의 `use_bidirectional_attention` 설정을 무시하고 인과 마스크를 썼다. 독일어 질의 20개에서 hit@1이 75%였고, 수정한 뒤에야 100%가 됐다 ([mlx-swift-lm #638](https://github.com/ml-explore/mlx-swift-lm/issues/638)). 수정 전 최종 코사인은 transformers 대비 0.452~0.701에 그쳤다 ([PR #654](https://github.com/ml-explore/mlx-swift-lm/pull/654)). Python `mlx-embeddings`는 양자화 체크포인트에서 어텐션 마스크를 uint32로 캐스팅했다. 그 결과 패딩 토큰이 어텐션에 섞여 배치 코사인이 0.884까지 떨어졌고, 이 이슈는 아직 열려 있다 ([mlx-embeddings #72](https://github.com/Blaizzy/mlx-embeddings/issues/72)). llama.cpp에서는 PR #16367 이전에 변환된 GGUF에 v1의 Dense 두 층이 빠져 있었다 ([PR #16367](https://github.com/ggml-org/llama.cpp/pull/16367); [cduk 저장소](https://huggingface.co/cduk/embeddinggemma-300m-GGUF-with-dense-modules)).

어느 경우에도 예외는 발생하지 않았다. 그래서 어떤 런타임이든 양방향 어텐션과 대칭 슬라이딩 윈도, 패딩 마스크를 반영한 평균 풀링, v2의 모델 내부 투영(v1이라면 Dense 두 층), L2 정규화와 절단 후 재정규화, 앱이 직접 붙이는 접두어, fp32 또는 bf16 정밀도, 배치 패딩 처리의 일곱 가지를 확인해야 한다. 그리고 한·영 문장 세트에서 sentence-transformers fp32 결과와 코사인 0.999 이상인지 검사하는 패리티 테스트를 CI에 넣는다.

| 런타임 | v2 지원 | 텍스트 전용 크기 | 공개된 Apple Silicon 수치 | 통합 형태 | 핵심 위험 |
|---|---|---|---|---|---|
| **MLXEmbedders** ([ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)) | main 전용, PR #684 (10-12), 최신 태그 3.32.3 이후 | 4bit 텍스트 전용 약 176 MB, 8bit 실사용 메모리 288 MB | Mac 수치 없음 (iPhone 14 Pro, 512토큰 기준 약 4.8문서/s) | Swift 프로세스 내, MIT | 태그 없는 커밋 고정, Xcode 빌드 필수 |
| **Core ML / ANE** ([FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml) + [FluidUse](https://github.com/FluidInference/FluidUse)) | 10-09 공개 | 패키지 271 MB + 토큰 테이블 256 MB | M5 Pro ANE에서 32토큰 2.6 ms ~ 512토큰 27.4 ms, 초당 644텍스트 | Core ML, Apache-2.0 | 512토큰 상한, 첫 ANE 컴파일에 수 분, 서드파티 단일 출처 |
| **llama.cpp** ([PR #30054](https://github.com/ggml-org/llama.cpp/pull/30054)) | 10-06 | Q8_0 310 MB, UD-Q4_K_XL 176 MB | Metal 수치 없음 | XCFramework C API, MIT | 접두어·MRL을 클라이언트가 구현, 서버의 `dimensions` 미지원 |
| **LiteRT-LM** ([litert-community](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm)) | 구글 공식 QAT int4 | 165 MB | MacBook Pro M5, 128토큰 기준 GPU 9.5 ms / CPU 31.3 ms | Google AI Edge | macOS Swift 통합 성숙도 미조사 |
| ONNX Runtime ([onnx-community](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX)) | 10-04 | q8 314 MB (코사인 0.9997), q4 175 MB (0.988) | 없음 | ORT | Swift 패키지가 1.24.2에 머묾, CoreML EP 그래프 분할 |
| Ollama / LM Studio | 0.40.x / 0.4.26 | `:270m` 378 MB | 없음 | 외부 데몬 HTTP | 사용자 측 버전 차이, 256K 컨텍스트 함정 |
| sentence-transformers | ≥ 6.1.0 | – | – | Python 기준 구현 | 번들이 무거움. 평가와 패리티 오라클 전용 |

### MLXEmbedders: 검증된 1순위, 단 main 커밋 고정이 필요하다

MLXEmbedders는 이제 mlx-swift-examples가 아니라 **`ml-explore/mlx-swift-lm`에 있다**. v2 지원 PR #684는 10월 12일 병합됐다. transformers SDPA 대비 코사인 0.9999 이상의 패리티가 보고됐고, 비전·오디오를 지연 로딩하면 8bit 모델의 실사용 메모리는 1.23 GB가 아니라 288 MB다 ([PR #684](https://github.com/ml-explore/mlx-swift-lm/pull/684)).

비전·오디오 텐서를 걷어낸 서드파티 4bit 텍스트 전용 모델(약 176 MB)도 시험됐다. 짧은 텍스트부터 4K 토큰까지 코사인이 0.9998 이상이었고, 배치 결과도 개별 실행과 일치했다. 다만 세 가지 함정이 함께 보고됐다. 가중치 없이 `vision_config`만 남아 있으면 로드에 실패하고, `hiddenStates`가 항상 nil이며, 입력이 8,192 토큰에서 고정 절단된다.

README에 따르면 모델은 `EmbedderRegistry.embeddinggemma2`로 로드한다. `dimensions` 인자(128~768)를 주면 재정규화까지 처리하지만, 접두어는 붙여 주지 않는다 ([MLXEmbedders README](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/README.md)).

문제는 배포 단위다. 최신 태그 3.32.3(9월 30일)은 v1 수정(#654)과 v2 지원(#684)보다 앞선다. 태그 버전을 쓰면 v1은 틀린 결과를 내고 v2는 아예 없다. 따라서 **#684 병합 이후의 커밋에 고정**해야 한다 ([릴리스 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3)). SwiftPM 명령줄로는 Metal 셰이더를 빌드할 수 없으므로 Xcode나 xcodebuild가 필요하다 ([mlx-swift README](https://github.com/ml-explore/mlx-swift)). mlx-community의 v2 변환본은 모든 인코더를 포함해 4bit도 1.1 GB가 넘는다. 텍스트 전용으로 다시 변환하거나 텐서를 걷어내야 한다 ([mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16)).

### Core ML ANE: 공개 수치는 최고지만 나흘 된 단일 벤더 변환이다

Core ML 경로는 공개된 Apple Silicon 수치가 가장 좋다. FluidInference 변환본은 M5 Pro에서 연산 3,862개를 **100% Neural Engine에 배치**했다. 질의 하나(32토큰)를 2.6 ms에, 묶은 짧은 텍스트를 초당 644개 처리했고, 함수 5,617개를 16초에 색인한 데모도 있다 ([FluidInference](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)).

대가도 있다. 고정 형상 함수(`embed_32`~`embed_512`, `pack_256`)만 ANE에 올라가고, 가변 형상은 그래프 전체를 CPU로 보낸다. 그래서 512토큰을 넘는 입력은 잘린다. 기기마다 첫 로드 때 ANE 컴파일에 몇 분이 걸리고, 공개된 지 나흘밖에 안 된 단일 벤더 변환이다(다운로드 약 547회). Swift 구현은 `FluidInference/FluidUse`(약 506★, Apache-2.0)의 `EmbeddingGemma2Manager`에 있다 ([FluidUse](https://github.com/FluidInference/FluidUse)).

토크나이저도 확인해야 한다. swift-transformers에는 추가 토큰 수에 비례해 시간이 이차로 늘어나는 이슈가 열려 있다. Gemma 3 토크나이저에서 개행으로 구분한 40줄 처리에 1,148 ms가 걸렸다 ([swift-transformers #383](https://github.com/huggingface/swift-transformers/issues/383)). v2의 Gemma 4 토크나이저에서도 재현되는지 확인해야 한다.

청크를 512토큰 이하로 자르는 설계에서는 Core ML의 길이 상한이 문제가 되지 않는다. 그래서 이 경로는 **배경 색인용 저전력 엔진**으로 평가할 가치가 크다.

### llama.cpp는 넓은 생태계, LiteRT-LM은 구글 공식 수치를 갖췄다

llama.cpp는 10월 6일 PR #30054로 v2의 텍스트·비전·오디오를 지원했다. 빌드마다 macOS XCFramework(b11583 기준 64 MB zip)를 배포하므로 앱에 바로 링크할 수 있다 ([llama.cpp b11583](https://github.com/ggml-org/llama.cpp/releases/tag/b11583); [xcframework 문서](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)). 텍스트만 쓰면 mmproj 없이 GGUF 하나로 충분하다. 대신 접두어, MRL 절단, 재정규화는 앱이 직접 해야 하고, OpenAI 호환 서버는 `dimensions` 인자를 아직 받지 않는다 ([issue #25210](https://github.com/ggml-org/llama.cpp/issues/25210)). Swift 래퍼인 `mattt/llama.swift`는 C API를 다시 내보내는 얇은 층이다 ([mattt/llama.swift](https://github.com/mattt/llama.swift)). 출시 직후 보고된 성능 버그는 CUDA 쪽이었고, Metal 수치는 없다.

LiteRT-LM은 구글이 직접 낸 QAT int4 텍스트 모델(165 MB)이다. MacBook Pro M5에서 128토큰 입력 기준 GPU 9.5 ms, CPU 31.3 ms였고, 메모리는 각각 233 MB와 165 MB를 썼다. Mac 데모 앱 "Foresight"도 있다 ([litert-community 카드](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm); [Google AI Edge 블로그](https://developers.googleblog.com/en/google-ai-edge-with-embeddinggemma-2/)). 다만 macOS 네이티브 앱에 통합하는 경로는 이번 조사에서 검증하지 못했다.

### ONNX·Rust·데몬·Apple 내장 API는 이번 목적에 맞지 않는다

나머지 경로는 각각 결격 사유가 있다. ONNX Runtime의 공식 Swift 패키지는 1.24.2로, 코어(1.31.0)보다 마이너 버전 7개가 뒤처져 있다. CoreML EP는 ANE 실행을 보장하지 않는다 ([ORT Swift 패키지](https://github.com/microsoft/onnxruntime-swift-package-manager); [CoreML EP 문서](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)). fastembed-rs는 v1만 지원하고, TEI는 v2를 지원하지 않는다. candle에는 병합된 EmbeddingGemma가 없고, `jkrukowski/swift-embeddings`는 Gemma 계열을 지원하지 않는다 ([fastembed-rs](https://github.com/Anush008/fastembed-rs); [TEI #947](https://github.com/huggingface/text-embeddings-inference/issues/947); [swift-embeddings](https://github.com/jkrukowski/swift-embeddings)).

Ollama와 LM Studio는 사용자가 데몬을 따로 설치해야 하고, 버전·컨텍스트·keep-alive를 앱이 통제할 수 없다. Ollama의 일부 v2 태그는 MLX 전용이라 리눅스에서 오류가 나고 ([ollama #18971](https://github.com/ollama/ollama/issues/18971)), 공백이 과도한 텍스트에서 164배 느려지는 이슈가 열려 있다 ([ollama #12508](https://github.com/ollama/ollama/issues/12508)). 그래서 사용자가 직접 지정하는 선택형 백엔드로만 둔다.

Apple의 `NLContextualEmbedding`은 토큰별 벡터를 내는 입력층이라, Apple 문서도 의미 유사도에는 다른 API를 권한다 ([Apple 문서](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)). Core Spotlight 시맨틱 검색은 앱이 기증한 콘텐츠만 검색하므로 ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)), 둘 다 EmbeddingGemma를 대체하지 못한다.

결론적으로 `Embedder` 프로토콜 뒤에 **MLXEmbedders(커밋 고정)와 텍스트 전용 v2 가중치**를 기본 구현으로 둔다. Core ML ANE는 배경 색인의 전력·속도 대안으로, llama.cpp는 대체 경로로 같은 프로토콜에 연결한다. M1~M4에서 측정된 런타임 수치는 어디에도 공개되지 않았다. 따라서 16/64토큰 질의 지연, 256/512토큰 문서 처리량, RSS, 콜드 로드 시간을 대상 Mac에서 직접 측정해 기본값을 정한다.

## 수집 대상마다 API와 권한 장벽이 다르고, 재사용할 코드는 충분하다

| 소스 | 수집 방법 | 변경 감지 | 필요 권한 | 재사용할 코드·자료 |
|---|---|---|---|---|
| 로컬 문서 | 사용자가 지정한 폴더를 크롤. PDFKit, `NSAttributedString`(doc/docx/rtf/html/odt), ZIP+XML(pptx/xlsx), 스캔본은 Vision `.accurate` | FSEvents (이벤트 ID와 장치 UUID 저장) | 사용자 선택 (보안 범위 북마크) | [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), [Tinycast file-search](https://github.com/abue-ammar/tinycast/blob/main/docs/features/file-search.md) |
| 클립보드 | `changeCount`를 0.5초마다 폴링, nspasteboard 마커로 필터 | 폴링 | macOS 15.4 이후 "Paste from Other Apps" 허용 (기본 시행 여부 불명확) | [Maccy](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) (MIT, 21.9k★) |
| 브라우저 기록·북마크 | Chromium `History`·`Bookmarks`, Firefox `places.sqlite`, Safari `History.db`를 임시 폴더로 복사해 읽기 | 파일 mtime·FSEvents와 시간 체크포인트 | Safari만 전체 디스크 접근 | [raycast browser-history](https://github.com/raycast/extensions/blob/main/extensions/browser-history/src/constants.ts), [raycast/utils sql-utils](https://github.com/raycast/utils/blob/main/src/sql-utils.ts), [hindsight](https://github.com/RyanDFIR/hindsight) |
| 설치된 앱 | `mdfind`로 `com.apple.application-bundle` 검색 + `NSWorkspace` | NSMetadataQuery 라이브 업데이트 | 없음 | [ospfranco/sol](https://github.com/ospfranco/sol) |
| 시스템 설정 | ExtensionKit `.searchTerms`의 한·영 제목과 키워드 + `x-apple.systempreferences:` 딥링크 | OS 빌드가 바뀌면 재스캔 | 없음 | [SystemSettings-URLs-macOS](https://github.com/jaywcjlove/SystemSettings-URLs-macOS) |
| 명령 | `shortcuts list/run`, AppleScript·셸 스크립트 | 주기적 갱신 | System Events 등에 대한 Automation | [raycast/script-commands](https://github.com/raycast/script-commands/tree/master/commands/system) |

### 문서는 Spotlight가 본문을 내주지 않으므로 직접 크롤한다

문서 텍스트는 Spotlight에서 꺼낼 수 없다. Spotlight 색인은 `kMDItemTextContent`로 *검색*은 되지만, `mdls`나 MDItem으로 본문을 *읽어오지는* 못한다. Eclectic Light의 분석과 이번 조사에서 macOS 26.6.2로 직접 확인한 결과가 일치한다 ([Eclectic Light](https://eclecticlight.co/2026/05/08/how-to-check-whether-spotlight-is-getting-the-right-metadata/)). 특정 선행 문자로 시작하는 평문 파일과 JSON이 색인되지 않는 사각지대도 보고됐다 ([Eclectic Light: JSON](https://eclecticlight.co/2026/07/15/spotlights-blind-spot-json-documents/)). 그래서 사용자가 지정한 폴더를 직접 크롤한다.

변경 감지는 FSEvents의 영속 이벤트 DB를 쓴다. 마지막 이벤트 ID와 `FSEventsCopyUUIDForDevice()`의 UUID를 저장해 두면, 재실행 후 `sinceWhen`으로 꺼져 있던 동안의 변경까지 따라잡는다. `MustScanSubDirs`(이벤트 합쳐짐·유실)나 `EventIdsWrapped`(ID 순환) 플래그를 받으면 재스캔한다. `FSEventStreamScheduleWithRunLoop`는 macOS 13부터 폐기됐으므로 `FSEventStreamSetDispatchQueue`를 쓴다 ([Apple: File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)).

한국어 OCR에는 모드 제약이 있다. `VNRecognizeTextRequest` 리비전 3은 **`.accurate` 모드에서만 `ko-KR`을 지원**하고, `.fast`는 유럽어 6개뿐이다. macOS 26의 `RecognizeDocumentsRequest`는 표·목록 같은 문서 구조까지 읽는다 ([Apple: VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest); [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)). OCR은 비싸다. `PDFPage.string`이 빈 스캔 PDF와, 사용자가 동의한 이미지 폴더에만 지연 실행한다.

### 클립보드는 0.5초 폴링과 nspasteboard 마커로 거른다

클립보드에는 변경 알림 API가 없어 폴링해야 한다. Maccy가 참고 구현이다. 기본 0.5초 주기 타이머로 `changeCount`를 비교하고, `.transient`·`.concealed`·`.autoGenerated` 마커가 붙은 항목은 무조건 무시하며, 기록은 SwiftData에 저장한다 ([Maccy Clipboard.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift); [Storage.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Storage.swift)). nspasteboard.org 규약도 같은 방향이다. Transient는 기록하지 않고, Concealed는 저장을 피하거나 암호화하며, 원본 앱은 `org.nspasteboard.source`로 표시하라고 권한다 ([nspasteboard.org](https://nspasteboard.org/)).

변수는 macOS 15.4의 클립보드 접근 경고다. 새로 생긴 `NSPasteboard.accessBehavior`는 읽기 전용이라 앱이 스스로 허용 상태로 바꿀 수 없다. 개인정보 보호 설정에는 "Paste from Other Apps" 항목이 생겼다 ([Apple: accessBehavior.ask](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/ask)). 이 경고가 기본으로 시행되는지는 출처마다 다르다. macOS 26에서는 개발자 플래그 없이는 보이지 않았다는 보고가 있고, 이후 그 플래그가 폐기됐다는 블로그 댓글도 있다 ([Michael Tsai](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/); [OneShot #15](https://github.com/admax12959/OneShot/issues/15)). 그러니 실행할 때마다 `accessBehavior`를 확인하고, `.ask`나 `.alwaysDeny`면 설정 딥링크로 안내하는 온보딩을 둔다. Apple은 경고 대화상자 자체에는 설정 링크를 넣지 않겠다고 답했다 ([feedback-assistant #655](https://github.com/feedback-assistant/reports/issues/655)).

### 브라우저 기록은 복사본을 읽고 URL당 문서 하나로 만든다

브라우저마다 기록 형식이 다르다. Chromium 계열은 프로필별 `History` SQLite(`urls`·`visits` 테이블)를 1601년 기준 마이크로초로 쓰고, 비샌드박스 앱이면 권한 없이 읽힌다. Safari의 `~/Library/Safari/History.db`는 2001년 기준 초를 쓰고 전체 디스크 접근이 필요하다. Firefox의 `places.sqlite`는 유닉스 기준 마이크로초를 쓴다 ([raycast browser-history 상수](https://github.com/raycast/extensions/blob/main/extensions/browser-history/src/constants.ts); [Timothy Comeau](https://timothycomeau.com/writing/chrome-history); [raycast safari](https://github.com/raycast/extensions/blob/main/extensions/safari/src/hooks/useHistorySearch.ts); [Firefox nsPlacesTables.h](https://searchfox.org/mozilla-central/source/toolkit/components/places/nsPlacesTables.h)).

브라우저가 실행 중이면 DB가 잠겨 있다. `immutable=1`로 열면 파일이 바뀌는 순간 잘못된 결과나 손상 오류가 날 수 있다 ([SQLite URI](https://www.sqlite.org/uri.html)). Raycast의 처리 방식이 모범 사례다. 잠김 오류가 나면 DB를 임시 폴더로 복사하고 빈 `-wal`·`-shm` 파일을 만든 뒤 읽는다. 권한 오류가 나면 전체 디스크 접근 설정으로 안내한다 ([raycast/utils sql-utils.ts](https://github.com/raycast/utils/blob/main/src/sql-utils.ts)).

브라우저는 페이지 본문을 거의 저장하지 않는다. 그래서 문서는 방문이 아니라 URL마다 하나씩 "제목 — 도메인 — URL 경로 토큰 — 검색어"로 만든다. 이번 조사에서 Chrome `History`를 직접 열어 보니 `keyword_search_terms` 테이블에 사용자가 주소창에 친 검색어가 들어 있었다. 한국어 자연어인 경우가 많아 임베딩 매칭에 특히 가치가 크다. `content_annotations.password_state` 컬럼도 있어서, 비밀번호가 오간 방문을 건너뛰는 데 쓸 수 있다.

### 앱 이름과 설정 패널에는 한·영 코퍼스가 이미 들어 있다

앱과 시스템 설정에는 이미 한·영 코퍼스가 있다. 이번 조사에서 macOS 26.6.2로 직접 확인했다. 앱은 Spotlight 메타데이터에 현지화 이름과 영어 이름을 함께 가진다. 예를 들어 계산기 앱의 `kMDItemDisplayName`은 "계산기.app", `kMDItemAlternateNames`는 "Calculator.app"이고, 시스템 앱은 `InfoPlist.loctable`에 언어별 표시 이름을 담고 있다.

시스템 설정 패널은 macOS 13 이후 `/System/Library/ExtensionKit/Extensions/` 아래 확장 51개로 구성된다. 각 확장에는 언어별 `.searchTerms` plist가 있고, 딥링크 앵커(예: `Privacy_AllFiles`)마다 현지화된 제목과 키워드 목록이 들어 있다. 영어 파일 47개에 앵커가 563개다. 예컨대 `Privacy_AllFiles`의 한국어 제목은 "응용 프로그램이 모든 사용자 파일에 접근하는 것을 허용"이고, 키워드는 "파일, 전체 디스크 접근 권한, …"이다.

같은 앵커의 en과 ko 항목을 합치면, 손으로 쓰지 않고도 약 560개의 이중언어 설정 항목을 딥링크와 함께 얻는다. 딥링크 형식은 Raycast와 PermissionsKit이 쓰는 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`와 같다 ([MacPaw/PermissionsKit](https://github.com/MacPaw/PermissionsKit)). 다만 `.searchTerms`는 문서화되지 않은 내부 형식이다. 방어적으로 파싱하고 OS 업데이트 때마다 다시 스캔해야 한다. 또 `Privacy_Pasteboard`가 빠져 있었으므로 완전한 앵커 목록은 아니다.

명령 쪽은 두 갈래다. 사용자 단축어는 `shortcuts list`로 이름만 모은다. CLI가 설명을 노출하지 않기 때문이다 ([Apple Shortcuts 사용 설명서](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)). 잠자기, 다크 모드, 휴지통 비우기 같은 내장 명령은 Raycast script-commands의 AppleScript를 참고하고, 한·영 설명은 직접 쓴다 ([raycast/script-commands](https://github.com/raycast/script-commands/tree/master/commands/system)).

### 인덱스는 Mac에서 가장 민감한 데이터이고, 배포는 Developer ID로 한다

이 인덱스는 클립보드, 스크린샷 OCR, 방문 기록을 담으므로 Mac에서 가장 민감한 데이터다. 그래서 클립보드 수집은 사용자가 켜기 전까지 꺼 두고, 1Password·Bitwarden·KeePassXC·Apple 암호 앱의 번들 ID는 처음부터 제외한다. 보존 기간은 클립보드 7~30일, 브라우저 기록 90일로 제한한다. 임베딩만으로도 원문이 역추론될 수 있으므로 텍스트와 벡터를 SQLCipher나 Keychain 키 기반 CryptoKit AES-GCM으로 함께 암호화하고, 출처별 삭제와 "일시 정지" 토글을 둔다.

배포는 Developer ID로 서명·공증한 비샌드박스 앱이 현실적이다. Mac App Store 앱은 샌드박스가 필수다. Apple DTS는 샌드박스에서 Accessibility API가 지원되지 않는다고 밝혔고, ⌘V를 합성하는 클립보드 관리자가 심사에서 두 번 거절됐다 ([Apple 포럼 696586](https://developer.apple.com/forums/thread/696586); [포럼 820594](https://developer.apple.com/forums/thread/820594)). 전체 디스크 접근 권한을 요청하는 API는 없다. 보호된 파일을 열어보는 방식으로 권한 여부를 감지하고, 설정 딥링크로 안내한다 ([포럼 687633](https://developer.apple.com/forums/thread/687633); [inket/FullDiskAccess](https://github.com/inket/FullDiskAccess)).

## ⌥Space 패널은 검증된 AppKit 레시피가 있지만 단축키 충돌과 한글 조합이 함정이다

### 오픈소스 런처 20여 개 중 임베딩 검색을 가진 것은 없다

| 프로젝트 | 스택 | 라이선스 | 별 | 참고 가치 |
|---|---|---|---|---|
| [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast) | Swift (SwiftUI+AppKit), macOS 26+ | AGPL-3.0 | 8,444 | NSPanel, IME 조합 처리, 입력 소스 세션, Carbon 핫키, FSEvents 파일 색인 문서 |
| [ospfranco/sol](https://github.com/ospfranco/sol) | React Native macOS + Swift 호스트 | MIT | 3,168 | 허용형 라이선스의 Panel·HotKey·위치 계산 코드 |
| [vicinaehq/vicinae](https://github.com/vicinaehq/vicinae) | C++/Qt + Objective-C++ | GPL-3.0 | 10,240 | 기본 단축키 `alt+space`, `RegisterEventHotKey`, `SMAppService`, `NSGlassEffectView` |
| [SuperCmdLabs/SuperCmd](https://github.com/SuperCmdLabs/SuperCmd) | Electron 40 + Swift 헬퍼 | MIT | 3,218 | Electron 패널 우회책, Raycast API 호환 계층, 한국어 현지화 |
| [Wox-launcher/Wox](https://github.com/Wox-launcher/Wox) | Go 코어 + 자체 GPU UI | GPL-3.0 | 27,505 | 크로스플랫폼 구조 |
| [Xoshbin/asyar](https://github.com/Xoshbin/asyar) | Tauri + Svelte 5 | GPL-3.0 | 904 | Raycast 대비 벤치마크 스크립트 |
| [johnbean393/Sidekick](https://github.com/johnbean393/Sidekick) | Swift + llama.cpp | MIT | 3,319 | 프로세스 내 RAG. 런처가 아니라 채팅 UI |
| [khoj-ai/khoj](https://github.com/khoj-ai/khoj) | Python + TS 서버 | AGPL-3.0 | 37,669 | 시맨틱 검색 서버. 핫키 런처 아님 |

이번 조사에서 Tinycast, SuperCmd, Vicinae, Sol의 소스를 `embedding|NLEmbedding|cosine|sqlite-vec`로 검색했다. 걸린 것은 Tinycast의 받아쓰기용 Core ML 모델 하나뿐이었다 ([QwenRecognizer.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/Dictation/Helper/QwenRecognizer.swift)). 로컬 시맨틱 검색을 하는 앱은 런처가 아니었다. Sidekick과 Khoj는 채팅·RAG 앱이고, rem은 자연어 검색이 아직 로드맵 항목이다 ([jasonjmcghee/rem](https://github.com/jasonjmcghee/rem)). **Spotlight식 핫키 패널과 온디바이스 임베딩 검색을 결합한 성숙한 오픈소스는 없다.** 이 프로젝트가 메울 실제 공백이다.

재사용 범위는 라이선스가 가른다. Tinycast는 가장 완성도 높은 순수 SwiftUI/AppKit 참고 코드지만 AGPL이다. 패턴을 읽는 것은 자유롭지만, 포크하면 앱 전체가 AGPL이 된다. 코드를 직접 가져다 쓸 수 있는 것은 MIT인 Sol과 SuperCmd다.

Raycast 확장으로 만드는 길은 맞지 않는다. 스토어 지침이 무거운 바이너리 번들을 금지하는데 모델만 수백 MB다. 핫키, 패널, IME도 Raycast가 소유한다 ([Raycast 지침](https://developers.raycast.com/basics/prepare-an-extension-for-store)). 대신 독립 앱의 엔진을 로컬 데몬으로 노출하면, Raycast API 호환 확장 하나로 Raycast, Vicinae, SuperCmd, Tinycast 사용자에게 모두 닿을 수 있다.

### 핫키는 Carbon으로 등록하고 ⌥Space 충돌은 실행 시 감지한다

전역 핫키는 Carbon `RegisterEventHotKey`가 정답이다. `sindresorhus/KeyboardShortcuts`(2,724★, MIT)는 샌드박스와 Mac App Store에서도 동작하고, 권한 대화상자를 띄우지 않으며, SwiftUI 녹화기도 제공한다 ([KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)). Tinycast, Vicinae, Tauri의 `global-hotkey`, 그리고 Sol이 쓰는 `soffes/HotKey`도 모두 같은 Carbon API를 쓴다 ([HotKeyCenter.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/HotKeys/Service/HotKeyCenter.swift); [global-hotkey](https://github.com/tauri-apps/global-hotkey/blob/dev/src/platform_impl/macos/mod.rs)).

다른 방식은 권한이 필요하다. `NSEvent.addGlobalMonitorForEvents`는 Accessibility 권한이 없으면 아무 경고 없이 동작하지 않고, 이벤트를 가로챌 수도 없다 ([KeyboardShortcuts PR #236](https://github.com/sindresorhus/KeyboardShortcuts/pull/236)). `CGEventTap`은 듣기 전용이면 Input Monitoring, 이벤트를 수정하려면 Accessibility 권한이 필요하다 ([Apple 포럼 707680](https://developer.apple.com/forums/thread/707680)). 그러니 수정자 키 두 번 누르기 같은 트리거를 넣을 때만 쓴다.

⌥Space는 사실상 업계 기본값이다. Raycast 매뉴얼은 기본값이 "⌥ Space"라고 적고, Vicinae와 SuperCmd도 같다 ([Raycast 매뉴얼](https://manual.raycast.com/settings.md); [Vicinae config.hpp](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/config/config.hpp)). macOS 15.0~15.1은 샌드박스 앱이 Option만 쓴 단축키를 등록하지 못하게 막았지만(-9868 오류), 15.2에서 이 제한이 풀렸다 ([KeyboardShortcuts #176](https://github.com/sindresorhus/KeyboardShortcuts/issues/176); [릴리스 2.2.4](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/2.2.4)).

남은 위험은 다른 앱과의 충돌이다. ChatGPT/Codex 통합 앱(v26.924, 2026년 9월)은 ⌥Space를 "Show Pet / Mini"에 등록하며, 사용자가 바꾸거나 끌 수 없다 ([openai/codex #49201](https://github.com/openai/codex/issues/49201)). Claude Desktop의 Quick Launcher도 ⌥Space를 쓰고 ([claude-code #21382](https://github.com/anthropics/claude-code/issues/21382)), Siri의 "⌥Space 길게 누르기"와 겹치면 반응이 지연된다. 또 ⌥Space를 전역 점유하면 모든 앱에서 줄바꿈 없는 공백(U+00A0)을 입력할 수 없게 된다 ([UIUC TIL](https://til.acm.illinois.edu/macos/insert-a-non-breaking-space-character/)). 따라서 등록 실패를 감지해 다른 조합을 고르게 하는 UI, ChatGPT 앱 설치 여부 검사, 이 부작용을 알리는 온보딩 문구를 넣는다.

### 패널은 non-activating NSPanel, 입력은 hasMarkedText로 조합 상태를 지킨다

패널 구성은 Sol, Tinycast, multi.app의 글이 같은 레시피로 수렴한다. `NSPanel` 서브클래스의 **이니셜라이저에서** `.nonactivatingPanel` 스타일 마스크를 지정하고, `canBecomeKey = true`와 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`를 설정한다. 배경은 투명하게 하고 그림자는 켠다. 배경 효과는 macOS 26 이상에서 `NSGlassEffectView`, 이전 버전에서 `NSVisualEffectView`를 쓰고, SwiftUI는 `NSHostingView`로 얹는다. 패널은 `resignKey`와 `cancelOperation`(Esc)에서 닫는다. 앱은 `LSUIElement`로 만들고, 활성화 정책을 `.prohibited`에서 `.accessory`로 바꾸는 기법으로 포커스를 빼앗지 않게 한다 ([PalettePanel.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PalettePanel.swift); [Sol Panel.swift](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/views/Panel.swift); [multi.app](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)). 위치는 `NSScreen.main`이 아니라 커서가 있는 화면 기준으로 잡는다. Tinycast는 가시 영역 높이의 18% 지점에 위쪽 끝을 고정하고, 결과가 늘면 아래로 자라게 한다 ([Theme.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/DesignSystem/Theme.swift)).

키보드 조작은 Raycast와 Alfred 관례를 따른다. ↑↓와 ⌃N/⌃P로 이동하고, ↵로 열고, ⌘K로 보조 동작을, ⌘1~9로 N번째 결과를 바로 실행한다. Tab은 모드 전환, 오른쪽에는 상세 미리보기, Esc는 뒤로 가기 또는 닫기다 ([Alfred 단축키](https://support.alfredapp.com/cheatsheet); [Raycast List API](https://developers.raycast.com/api-reference/user-interface/list)).

한국어 사용자에게 핵심은 **조합 중인 글자(marked text)**를 다루는 방식이다. Tinycast는 필드 에디터의 `hasMarkedText()`를 `isComposing` 상태로 공개하고, 조합 중에는 루트 키 처리를 건너뛰며 Backspace를 IME에 넘긴다. 조합 변화는 확정 전까지 오지 않는 `didChange` 대신 `NSTextView.didChangeSelectionNotification`으로 관찰한다. 또 패널을 띄운 순간의 입력 소스를 저장했다가, 패널에서만 선호 소스를 적용하고 숨길 때 원래대로 돌려놓는다 ([palette.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/palette.md)).

웹 스택에서는 이 처리가 실제로 실패했다. Electron 기반 Claude Desktop의 ⌥Space 런처는 두벌식 입력에서 "오늘 무엇을 도와드릴까요?"를 "오ㄹ 무ㅅㅡ 도ㅏㅡㅣ까?"로 깨뜨렸다 ([claude-code #21382](https://github.com/anthropics/claude-code/issues/21382)). 프로그램으로 띄운 Electron 창에서 CJK IME가 동작하지 않는 오래된 버그와 같은 계열이다 ([electron #32307](https://github.com/electron/electron/issues/32307)).

"엔터 검색과 입력 중 검색"이라는 요구는 세 층으로 구현한다. 첫째 층은 조합 중이 아닐 때 확정 입력이 생길 때마다 메모리에서 앱·설정·명령을 퍼지·초성·접두 매칭으로 즉시 찾는다. 둘째 층은 마지막 확정 입력 후 150~300 ms의 디바운스가 지나면 임베딩 하이브리드 검색을 실행하고, 이전 작업은 Swift 구조적 동시성으로 취소한다. 셋째 층은 Enter다. Enter가 조합을 확정하는 키였다면 확정 후 곧바로 전체 시맨틱 검색을 돌리되, 같은 키 입력으로 항목을 열지는 않는다. 이를 위해 입력창은 조합 상태를 노출하지 않는 SwiftUI `TextField` 대신 AppKit `NSTextField`와 필드 에디터로 만든다. 디바운스 간격은 경험칙이므로 평가하면서 조정한다.

### 네이티브 Swift가 Tauri·Electron보다 창 동작·IME·메모리에서 앞선다

스택은 네이티브 Swift가 가장 낫다. 세 스택 모두 핫키는 Carbon으로 같고, 차이는 창 동작, IME, 메모리, ML 통합에서 난다. Tinycast는 메모리 100 MB 미만을, Wox는 약 150 MB를 내세운다 ([Tinycast](https://github.com/abue-ammar/tinycast); [Wox](https://github.com/Wox-launcher/Wox)).

Electron은 `type: 'panel'`이 이전 앱의 포커스를 빼앗는 문제가 오래됐다 ([electron #35815](https://github.com/electron/electron/issues/35815)). SuperCmd는 `acceptFirstMouse`, `skipTransformProcessType`, Dock 숨김 시점 조정 같은 우회책을 쌓아서야 동작시켰다 ([SuperCmd main.ts](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/main.ts)). Tauri 2와 `ahkohd/tauri-nspanel`(427★) 조합은 Rust·웹 팀에게 차선책이다. 다만 WKWebView에서 IME를 다룰 때 `isComposing`과 keyCode 229를 함께 확인해야 하는 부담이 남는다 ([tauri-nspanel](https://github.com/ahkohd/tauri-nspanel); [MDN keydown](https://developer.mozilla.org/en-US/docs/Web/API/Document/onkeydown)).

배포는 Developer ID 서명, Hardened Runtime, `notarytool` 공증, staple 순서로 진행한다 ([Apple 공증 문서](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)). 로그인 시 자동 실행은 `SMAppService.mainApp`(macOS 13+)으로 등록한다. `register()`가 성공해도 상태가 `requiresApproval`에 머물 수 있으므로 이 상태를 UI에 표시한다 ([Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)).

## 권장 아키텍처: Swift 셸, 상주 검색 엔진, 단일 SQLite 파일

앞의 근거를 합치면 아래 구조가 나온다. 원칙은 세 가지다. 키 입력 경로를 모델 추론과 분리하고, 무거운 수집은 배경으로 보내고, 모든 상태는 트랜잭션이 보장되는 파일 하나에 둔다.

```
[⌥Space] KeyboardShortcuts (Carbon RegisterEventHotKey, 권한 프롬프트 없음)
  └─ PalettePanel: NSPanel(.nonactivatingPanel) + SwiftUI(NSHostingView), LSUIElement
       └─ NSTextField ──(hasMarkedText == false)──> QueryController
            ├─ 확정 입력마다: 앱·설정·명령 퍼지/초성/접두 매칭 (메모리, 수 ms)
            ├─ 150–300 ms 디바운스: SearchEngine.search(q), 이전 Task 취소
            └─ Enter: 전체 하이브리드 + (선택) Qwen3-Reranker-0.6B 문서 재순위화

SearchEngine (상주 actor → 필요 시 SMAppService LaunchAgent + XPC로 분리)
  ├─ Embedder 프로토콜: MLXEmbedders(기본) | Core ML ANE | llama.cpp XCFramework
  │    "task: search result | query: " 접두어, bf16/fp32, 8,192 상한, 절단 후 재정규화
  ├─ Lexical: FTS5 BM25 (한글 음절 bigram + 공백 토큰 커스텀 토크나이저, 접두 질의)
  ├─ Dense: int8 256차원 상주 행렬 brute force(Accelerate) → 상위 200개 768차원 재채점
  └─ Fusion: RRF(k=60) → 라벨 축적 후 CC + frecency + 타입 prior + 날짜 필터

Ingestors (배경, 저우선 QoS)
  Files(FSEvents, PDFKit, NSAttributedString, Vision .accurate ko/en)
  Clipboard(changeCount 폴링, nspasteboard 마커, 비밀번호 앱 제외)
  Browser(SQLite 복사본, URL당 1문서) · Apps(mdfind) · Settings(.searchTerms ko+en) · Commands

Store: index.sqlite (GRDB, WAL; items/chunks/fts/frecency/model_version) + vectors.bin (mmap)
```

| 계층 | 1순위 선택 | 대안 | 근거 |
|---|---|---|---|
| 모델 | `google/embeddinggemma-2` 텍스트 270M, 상주 256차원 + 재채점 768차원 | harrier-oss-v1-270m(MIT), Qwen3-Embedding-0.6B(Apache-2.0)를 평가셋으로 비교 | Apache-2.0, 8K 컨텍스트, 코드 +10점, v1의 한국어 교차언어 우위 |
| 추론 | MLXEmbedders (mlx-swift-lm, #684 이후 커밋) | FluidInference Core ML(ANE, 색인용), llama.cpp XCFramework, LiteRT-LM | 프로세스 내 Swift, 패리티 0.9999 검증, 텍스트 전용 176~288 MB |
| 어휘 검색 | SQLite FTS5 + GRDB 커스텀 토크나이저 | Kiwi 형태소 분석, Tantivy+lindera(FFI) | 공백 토큰화 대비 한국어 재현율 개선, 단일 파일 트랜잭션 |
| 벡터 검색 | mmap int8/float 행렬 + Accelerate brute force | sqlite-vector, sqlite-vec(버전 고정), 100만 개 이상이면 USearch | 50만 청크 이하에서 정확 검색이 수 ms, 삭제가 단순 |
| 융합·랭킹 | RRF k=60 → CC, Firefox식 감쇠 frecency, 규칙 기반 의도 라우팅 | VecturaKit 하이브리드(프로토타입) | Cormack, Bruch, SIS, Kim & Croft |
| UI | AppKit NSPanel + SwiftUI, NSTextField | Tauri + tauri-nspanel | non-activating 패널, 한글 조합 처리, 메모리 100 MB 미만 선례 |
| 핫키 | KeyboardShortcuts (⌥Space 기본, 변경 가능) | soffes/HotKey, CGEventTap(수정자 키 전용 트리거) | 권한 불필요, 15.2 이후 Option 단축키 허용 |
| 배포 | Developer ID + 공증, 비샌드박스, SMAppService, Sparkle | – | 브라우저 기록·Safari·폴더 크롤 요구사항 |

### 질의 경로: 어휘가 이름을, 임베딩이 의도를, 최근성이 최종 순서를 맡는다

질의 경로는 문헌의 결론을 그대로 옮긴다. 사람 이름과 정확한 명칭은 어휘 검색이, 의도와 바꿔 말하기는 임베딩이, 최종 순서는 최근성이 결정한다.

질의 임베딩 비용은 공개 수치로 보면 작다. M5 Pro ANE에서 32토큰에 2.6 ms, M5 GPU의 LiteRT에서 128토큰에 9.5 ms다. 50만 청크 256차원 int8 brute force도 대역폭 환산으로 수 ms이므로, 디바운스 후 하이브리드 검색 전체가 수십 ms 안에 끝날 것으로 예상한다. 다만 M1~M4 수치가 하나도 공개되지 않았으므로, 첫 개발 단계에서 대상 Mac으로 확인해야 한다.

최종 점수는 `w_sem·dense + w_lex·BM25 + w_fuzzy·접두퍼지 + w_fre·log(1+frecency) + 타입 prior`다. 초기 버전은 이 신호들의 순위 목록을 RRF로 합친다. 개인 평가셋이 40~100개 질의를 넘으면 소스별 가중치를 학습한 CC로 바꾼다. "지난주", "last week" 같은 시간 표현은 질의에서 떼어내 수정 시각과 방문 시각 필터로 변환한다.

### 색인 경로: 소스마다 텍스트 카드 하나, 벡터마다 모델 버전 하나

색인 경로의 원칙은 "소스마다 텍스트 카드 하나"다. 앱은 `title: 계산기 | text: Calculator com.apple.calculator 유틸리티 …`처럼 한·영 이름과 번들 ID를 담는다. 설정은 같은 앵커의 한·영 `.searchTerms` 제목과 키워드를 합친 카드에 딥링크를 붙인다. 브라우저는 URL마다 "제목 — 도메인 — 경로 토큰 — 검색어"로, 클립보드는 내용 앞부분과 원본 앱으로 만든다. 문서는 `title:`에 파일명·경로·가장 가까운 제목을 넣은 256~512토큰 청크와 파일 수준 벡터 하나로 구성한다. 벡터 행에는 모델 ID, 차원, 프롬프트 버전을 저장한다. 모델이나 런타임을 바꾸면 배경에서 재색인한 뒤 원자적으로 교체한다. 수집기는 저우선 QoS로 돌려 OCR과 대량 임베딩이 패널 응답을 방해하지 않게 한다.

엔진은 처음에는 같은 프로세스 안의 actor로 시작한다. 메모리나 크래시를 격리해야 할 때, 앱이 꺼진 동안에도 색인을 이어가야 할 때, Raycast 호환 확장에 엔진을 노출할 때는 `SMAppService` LaunchAgent와 XPC로 분리한다.

### 측정을 먼저 하고 권한이 필요 없는 소스부터 출시한다

진행 순서는 측정이 먼저다. 1단계에서는 Python sentence-transformers fp32로 기준 벡터를 만들고 한·영 평가셋 50~150개를 작성한다. 그 위에서 모델(v2·v1·harrier·Qwen3), 검색 방식(dense 단독·BM25 단독·RRF), 차원(768·256·128), 한국어 토크나이저(unicode61·bigram·Kiwi), 문서 접두어(`title:` 형식과 단순 연결)를 비교한다. 2단계에서는 Swift 런타임 세 가지의 패리티와 지연을 대상 Mac에서 측정한다. 3단계에서는 권한이 필요 없고 코퍼스가 작은 앱·설정·명령부터 패널·핫키·IME와 함께 출시하고, 이어서 문서, 브라우저 기록, 클립보드 순으로 권한 온보딩을 하나씩 붙인다.

위험 관리는 네 가지로 정리된다. 런타임 커밋을 고정하고 CI에서 패리티 테스트를 돌린다. fp16 경로를 금지한다. 입력 상한을 8,192토큰 이하로 명시한다. ⌥Space 충돌과 클립보드 접근 경고는 실행할 때마다 감지해 안내한다.

## Conclusion

이번 조사로 이 프로젝트의 차별점이 어디에 있는지가 분명해졌다. EmbeddingGemma 2의 텍스트 품질은 v1과 같고, MMTEB 평균으로는 2026년 경쟁 모델에 뒤진다. 그러니 "최신 모델을 썼다"는 것 자체는 경쟁력이 아니다. 실제 가치는 세 가지의 결합에서 나온다. 한국어 교차언어 검색에서 확인된 강점과 Apache-2.0의 배포 자유도, 한국어 형태소 문제를 다루는 어휘 경로, 그리고 설정 `.searchTerms`와 앱 현지화 이름처럼 OS에 이미 있는 이중언어 코퍼스를 텍스트 카드로 엮는 설계다. 시장에도 빈자리가 있다. Spotlight식 핫키 패널과 온디바이스 임베딩 검색을 결합한 오픈소스가 아직 없고, macOS 26 Spotlight는 클립보드 기록과 액션을 흡수했지만 ([AppleInsider](https://appleinsider.com/inside/macos-tahoe/tips/spotlight-got-a-huge-upgrade-in-macos-tahoe-heres-how-to-use-it)) 개인 파일에 대한 다국어 시맨틱 검색은 여전히 채우지 못했다.

위험이 어디 있는지도 예상과 달랐다. 성능은 문제가 아니다. 공개 수치상 질의 임베딩은 한 자릿수 ms이고, 50만 청크 brute force도 수 ms다. 진짜 위험은 일주일 된 런타임들이 오류 없이 틀린 벡터를 낼 가능성이다. 그래서 첫 번째 엔지니어링 산출물은 UI가 아니라 한·영 패리티 테스트, 개인 known-item 평가셋, 모델 버전을 기록하는 인덱스여야 한다. 이 셋을 갖추면 모델, 런타임, 토크나이저, 융합 가중치를 증거에 따라 언제든 갈아 끼울 수 있다. 빠르게 변하는 2026년 임베딩 생태계에서는 그것이 가장 오래가는 설계다.
