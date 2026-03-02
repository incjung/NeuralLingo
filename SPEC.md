# Specification: neurallingo.el

## 1. 개요 (Overview)
`neurallingo.el`은 Emacs 사용자가 영어 텍스트를 읽을 때 실시간으로 문장을 분석하고 AI 선생님과 대화하며 학습할 수 있도록 돕는 마이너 모드입니다. Google Cloud Vertex AI(Gemini)를 기반으로 하며, 단순 번역을 넘어 뉘앙스 학습, 기억에 남는 단어 연상법, 문맥 기반 질의응답을 제공합니다.

## 2. 핵심 기능 (Key Features)

### 2.1. 문장 분석 (C-c a)
- **자동 문장 인식:** 현재 커서가 위치한 문장을 자동으로 인식하여 하이라이트합니다.
- **AI 분석 패널:** 우측 사이드 패널(`*NeuralLingo-Analysis*`)에 다음과 같은 정보를 렌더링합니다.
  - **선생님 코멘트:** 친절하고 유머러스한 페르소나를 유지하며 문장의 뉘앙스 및 발음/억양 팁 제공.
  - **이중 번역:** 격식(Formal) 버전과 비격식/슬랭(Informal) 버전의 한국어 번역 제공.
  - **핵심 단어 추출:** 주요 단어의 뜻, 발음 기호, **재미있는 연결고리(연상법)**, 실생활 예문 2개 포함.
- **캐싱 시스템:** 한 번 분석한 문장은 메모리에 저장되어 다시 요청 시 즉시 표시됩니다.

### 2.2. 문맥 인식 꼬리 질문 (C-c q)
- **연속 대화:** 분석된 문장에 대해 궁금한 점을 미니버퍼에서 질문할 수 있습니다.
- **문맥 전달:** 질문 시 **초기 분석 데이터**와 **이전 질의응답 이력**을 모두 AI에게 전달하여 문맥에 맞는 답변을 제공합니다.
- **패널 누적:** 답변 내용은 분석 패널 하단의 `[ ADDITIONAL Q&A ]` 섹션에 차곡차곡 쌓입니다.

### 2.3. 세션 관리 (C-c s, C-c l)
- **영구 저장:** 현재 버퍼의 학습 내역(분석 결과, 질문 이력)을 JSON 파일로 로컬 디렉토리에 저장합니다.
- **복원:** 나중에 해당 문서를 다시 열었을 때 이전에 학습했던 하이라이트와 분석 내용을 그대로 복원합니다.

### 2.4. 단어 리마인더 (C-c r)
- **세션별 그룹화:** `neurallingo-cache-dir` 내의 모든 JSON 파일을 읽어, 파일 이름(학습 소스)을 최상위 카테고리(`*`)로 분류합니다.
- **계층적 Org 구조:** 
    - `* [파일명]` (예: `* README.org`) - 세션 단위 그룹
    - `** [분석 문장]` (예: `** Learning Emacs is fun.`) - 분석 대상 문장
    - `*** [단어]` (예: `*** fun`) - 문장에 포함된 개별 학습 단어
- **인터랙티브 복습:**
    - **Hide/Show:** `TAB` 키를 사용하여 세션, 문장, 또는 단어별 상세 정보(뜻, 연상법, 예문)를 계층적으로 열람하며 복습합니다.
    - **자동 렌더링:** `C-c r` 호출 시 실시간으로 저장소의 모든 데이터를 통합하여 전용 버퍼(`*NeuralLingo-Reminder*`)를 생성합니다.

## 3. 기술 스택 및 요구사항 (Technical Requirements)

### 3.1. 인프라
- **AI Engine:** Google Cloud Vertex AI (Gemini 2.5 Flash / Flash-lite 등).
- **인증:** Google Cloud SDK (`gcloud`)의 Application Default Credentials(ADC) 사용.
- **의존성:** `json`, `url`, `subr-x` (Emacs 내장 라이브러리).

### 3.2. 설정 변수
설정 변수는 init.el 에서 사용자가 지정함. 코드에서는 변수 정의만 존재.
- `neurallingo-project-id`: Google Cloud 프로젝트 ID.
- `neurallingo-location`: us-central1 등 리전 설정.
- `neurallingo-model-id`: 사용할 Gemini 모델 ID.
- `neurallingo-cache-dir`: 세션 JSON 파일이 저장될 위치.

## 4. 데이터 흐름 (Data Flow)
1. **Request:** `url-retrieve`를 통해 비동기로 Vertex AI API에 POST 요청 전송.
2. **Encoding:** 모든 요청 데이터와 인증 헤더는 `Multibyte text` 오류를 방지하기 위해 UTF-8 바이트(unibyte)로 강제 인코딩함.
3. **Decoding:** AI로부터 받은 응답 문자열 및 세션 JSON 파일을 처리할 때 `decode-coding-string` 또는 `coding-system-for-read 'utf-8`을 사용하여 한글 깨짐 방지.
4. **Parsing:** 응답 데이터는 `json-key-type`을 `string`으로 설정하여 `assoc`을 통한 안정적인 데이터 추출 보장.
5. **Rendering:** `with-current-buffer`와 `inhibit-read-only`를 사용하여 사이드 패널에 서식(Face)이 적용된 텍스트 출력.

## 5. 단축키 맵 (Key Bindings)
| 단축키 | 명령 | 기능 |
| :--- | :--- | :--- |
| `C-c a` | `neurallingo-analyze-current-sentence` | 현재 문장 분석 시작 |
| `C-c q` | `neurallingo-ask-question` | 분석된 문장에 대해 질문하기 |
| `C-c s` | `neurallingo-save-session` | 현재 버퍼의 학습 기록 저장 |
| `C-c l` | `neurallingo-load-session` | 저장된 학습 기록 불러오기 |
| `C-c r` | `neurallingo-open-reminder` | 저장된 모든 세션을 파일별로 그룹화하여 Org-mode 복습 버퍼 생성 |
| `C-c c` | `neurallingo-clear-all-highlights` | 모든 하이라이트 및 캐시 초기화 |

## 6. AI 시스템 프롬프트 (AI System Prompts)

### 6.1. 초기 문장 분석 (Initial Analysis)
- **목적:** 문장의 뉘앙스 파악, 번역, 핵심 단어 및 연상법 추출.
- **Rules:**
  1. **teacher_comment:** 문장의 전체적인 뉘앙스 설명 및 원어민스러운 발음/억양 피드백 제공.
  2. **이중 번역:** 격식(Formal) 번역과 비격식/슬랭(Informal) 번역 모두 제공.
  3. **Vocabulary 연상법:** 각 단어에 대해 잊지 못할 'fun_connection'(어원, 한국어 유사 발음을 이용한 암기법, 문화적 맥락 등) 제공.
  4. **pronunciation_tip:** 강세(stress)와 원어민식 연음(linking)에 집중한 발음 팁 제공.
  5. **예문 제공:** 각 단어별로 정확히 2개의 실생활 예문 포함.
  6. **JSON 형식:** trailing comma를 포함하지 않는 유효한 JSON 객체로만 응답.

### 6.2. 꼬리 질문 답변 (Follow-up Q&A)
- **목적:** 기존 분석 내용과 대화 이력을 바탕으로 사용자의 추가 질문에 답변.
- **프롬프트 구조:** 
  1. 현재 학습 중인 문장 제공.
  2. 이전에 제공된 AI 분석 결과(JSON) 전달.
  3. 지금까지 주고받은 Q&A 히스토리 포함.
  4. 사용자의 새로운 질문에 대해 한국어로 답변.

## 7. 구현 및 검증 워크플로우 (Implementation & Validation Workflow)

### Task 1: 비동기 API 통신 및 인코딩 보안
- **구현 내용:** `url-retrieve`를 이용한 Vertex AI 비동기 요청 및 응답 처리.
- **핵심 체크리스트:**
  - [x] **Request Encoding:** `url-request-data`와 `Authorization` 헤더가 `encode-coding-string` (utf-8)을 통해 unibyte 문자열로 변환되었는가? (Multibyte text 에러 방지)
  - [x] **Response Decoding:** API 응답 버퍼를 `decode-coding-string` (utf-8)로 변환하여 한글 깨짐이 없는가?
  - [x] **URL Safety:** API URL 자체가 인코딩되어 안전하게 전달되는가?

### Task 2: JSON 파싱 및 데이터 신뢰성
- **구현 내용:** AI 응답(JSON)에서 학습 데이터를 추출하여 패널에 렌더링.
- **핵심 체크리스트:**
  - [x] **Key Type:** `json-key-type`을 `'string`으로 명시하여 `assoc` 검색이 안정적으로 작동하는가?
  - [x] **Array Type:** `json-array-type`을 `'list`로 명시하여 `vocabulary`, `examples` 등 배열 데이터를 리스트 함수(`dolist`, `mapc`)로 안전하게 처리하는가? (벡터 파싱 오류 방지)
  - [x] **Schema Validation:** `teacher_comment`, `vocabulary` 등 필수 키값이 누락되었을 때의 예외 처리가 되어 있는가?
  - [x] **Trailing Comma:** AI 응답에 trailing comma가 포함되지 않도록 시스템 프롬프트에 명시되어 있는가?

### Task 3: 문맥 인식 꼬리 질문 (Q&A)
- **구현 내용:** 이전 분석 데이터와 대화 이력을 포함한 추가 질문 기능.
- **핵심 체크리스트:**
  - [x] **Context Injection:** `analysis-json`과 `history-str`이 프롬프트에 정확히 포함되는가?
  - [x] **State Sync:** 콜백 시점에 `gethash`를 다시 호출하여 최신 캐시 데이터를 업데이트하는가?
  - [x] **Encoding Check:** 한국어 질문 입력 시 HTTP 요청이 깨지지 않는가?

### Task 4: 세션 관리 및 상태 복원
- **구현 내용:** 학습 데이터의 로컬 JSON 저장 및 로드.
- **핵심 체크리스트:**
  - [x] **File Encoding:** `coding-system-for-write/read`를 `'utf-8`로 지정하여 저장/로드 시 한글이 보존되는가?
  - [x] **UI Sync:** 세션 로드 시 하이라이트(Overlay)가 본문에 정상적으로 다시 입혀지는가?
  - [x] **Directory Creation:** 캐시 디렉토리가 없을 경우 자동으로 생성하는가?

### Task 5: 세션 그룹화 기반 Org-mode 리마인더 시스템
- **구현 내용:** 로컬 JSON 저장소의 데이터를 파일명 및 분석 문장 단위로 구조화하여 Org-mode 복습 환경 구축.
- **핵심 체크리스트:**
    - [x] **Multi-file Scanning:** `neurallingo-cache-dir` 내의 모든 `.json` 파일을 순회하며 데이터를 수집하는가?
    - [x] **Hierarchical Grouping:** 
        - 1단계(`*`): 파일명(세션명)
        - 2단계(`**`): 분석 대상 원문 문장 (문맥 제공)
        - 3단계(`***`): 개별 학습 단어
    - [x] **Visibility Control:** 
        - 세션 및 문장 레벨은 하위 항목을 보여주도록 설정하는가?
        - 단어 상세 정보(뜻, 연상법 등)는 복습을 위해 기본적으로 `folded` 상태로 생성하는가?
    - [x] **Buffer Management:** `*NeuralLingo-Reminder*` 버퍼를 생성하고 `org-mode`를 활성화하여 즉시 학습 가능한 상태로 만드는가?
