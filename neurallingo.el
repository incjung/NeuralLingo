;;; neurallingo.el --- AI English Learning Assistant for Emacs -*- lexical-binding: t; -*-

;; Author: AI Assistant
;; Version: 3.0
;; Keywords: convenience, tools, learning

;;; Commentary:
;; 영어 기사나 텍스트를 읽을 때 문장 단위로 AI 분석을 제공합니다.
;; 친절하고 유머러스한 영어 선생님 페르소나가 적용되어 있습니다.
;; - C-c a: 문장 분석 (Gemini 2.5 Flash 연동, 억양/예문/연상법 포함)
;; - C-c q: 현재 문장에 대한 꼬리 질문 (미니버퍼 입력, 패널 내용 포함 누적)
;; - C-c s: 현재 문서(버퍼) 전용 학습 세션 자동 저장
;; - C-c l: 현재 문서(버퍼) 전용 학습 세션 불러오기 및 하이라이트 복원
;; - C-c r: 저장된 모든 세션을 모아 Org-mode 플래시카드로 복습(Remind)
;; - C-c c: 모든 흔적 지우기

;;; Code:
;;; neurallingo.el --- AI English Learning Assistant for Emacs (Vertex AI Version) -*- lexical-binding: t; -*-

;; Author: AI Assistant
;; Version: 4.0 (Vertex AI Edition)
;; Keywords: convenience, tools, learning

;;; Commentary:
;; 구글 클라우드(Vertex AI)의 크레딧을 사용하여 영어 문장 분석을 제공합니다.
;; 인증을 위해 시스템에 gcloud CLI가 설치되어 있어야 하며
;; `gcloud auth application-default login`이 완료된 상태여야 합니다.

;;; Code:

(require 'json)
(require 'url)
(require 'subr-x)

(defgroup neurallingo nil
  "AI English Learning Assistant via Vertex AI."
  :group 'tools)

;; [중요] 구글 클라우드 설정 변수
;; (defcustom neurallingo-project-id "my-eng-analysis"
;;   "Google Cloud Project ID."
;;   :type 'string
;;   :group 'neurallingo)

;; (defcustom neurallingo-location "us-central1"
;;   "Google Cloud Region (e.g., us-central1)."
;;   :type 'string
;;   :group 'neurallingo)

;; (defcustom neurallingo-model-id "gemini-2.5-flash"
;;   "Vertex AI Model ID."
;;   :type 'string
;;   :group 'neurallingo)

(defcustom neurallingo-cache-dir (expand-file-name "neurallingo" user-emacs-directory)
  "문서별 학습 기록(JSON)이 자동으로 저장될 디렉토리입니다."
  :type 'string
  :group 'neurallingo)

(defcustom neurallingo-request-timeout 30
  "Timeout in seconds for Vertex AI requests."
  :type 'integer
  :group 'neurallingo)

(defvar neurallingo--token-cache nil
  "Internal cache for the Vertex AI access token.
This is a list of (TOKEN . EXPIRATION-TIME).")

;; 1. 디자인 및 색상 설정
(defface neurallingo-highlight-face
  '((((class color) (background dark))
     (:background "#0f2b3c" :underline (:color "#22d3ee" :style wave)))
    (((class color) (background light))
     (:background "#e0f7fa" :underline (:color "#00acc1" :style wave)))
    (t (:underline t)))
  "Face used to highlight analyzed sentences."
  :group 'neurallingo)

(defface neurallingo-panel-header-face
  '((t (:foreground "#22d3ee" :weight bold)))
  "Face for panel headers."
  :group 'neurallingo)

(defface neurallingo-qna-question-face
  '((t (:foreground "#a78bfa" :weight bold)))
  "Face for user's follow-up questions."
  :group 'neurallingo)

(defface neurallingo-teacher-face
  '((((class color) (background dark)) (:foreground "#fde047" :slant italic))
    (((class color) (background light)) (:foreground "#ca8a04" :slant italic))
    (t (:slant italic)))
  "Face for teacher's humorous and energetic comments."
  :group 'neurallingo)

(defface neurallingo-example-face
  '((((class color) (background dark)) (:foreground "#94a3b8"))
    (((class color) (background light)) (:foreground "#475569"))
    (t (:slant italic)))
  "Face for real-life examples."
  :group 'neurallingo)

(defvar neurallingo-buffer-name "*NeuralLingo-Analysis*"
  "Name of the buffer used for displaying AI analysis.")

(defvar neurallingo--analysis-cache (make-hash-table :test 'equal)
  "문장을 키로, 분석 결과(alist)를 값으로 저장하는 해시 테이블.")

;; 2. 문장 파싱 및 오버레이 관리
(defun neurallingo--bounds-of-sentence-at-point ()
  "현재 커서가 위치한 문장의 시작과 끝 위치 반환."
  (save-excursion
    (let ((end (progn (forward-sentence) (point)))
          (beg (progn (backward-sentence) (point))))
      (cons beg end))))

(defun neurallingo--highlight-region (beg end)
  "본문에 영구적인 하이라이트를 남깁니다."
  (unless (cl-some (lambda (ov) (overlay-get ov 'neurallingo-overlay))
                   (overlays-at beg))
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'face 'neurallingo-highlight-face)
      (overlay-put ov 'neurallingo-overlay t))))

(defun neurallingo-clear-all-highlights ()
  "현재 버퍼의 모든 하이라이트와 캐시를 초기화합니다."
  (interactive)
  (remove-overlays (point-min) (point-max) 'neurallingo-overlay t)
  (clrhash neurallingo--analysis-cache)
  (message "[NeuralLingo] 모든 학습 흔적과 캐시 메모리가 초기화되었습니다."))

;; 3. 사이드 패널 관리 및 렌더링
(defun neurallingo--prepare-panel (&optional _)
  "우측 패널 버퍼를 가져오거나 새로 생성하여 창을 분할합니다."
  (let ((buf (get-buffer-create neurallingo-buffer-name)))
    (display-buffer buf '(display-buffer-in-side-window (side . right) (window-width . 0.45)))
    buf))

(defun neurallingo--show-loading (buf message-text)
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize (format "\n> %s\n" message-text) 'face 'warning)))))

(defun neurallingo--display-result (data sentence)
  "분석 결과를 사이드 패널에 렌더링합니다."
  (let ((buf (neurallingo--prepare-panel)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "[ TARGET SENTENCE ]\n" 'face 'neurallingo-panel-header-face))
        (insert sentence "\n\n")

        (if (not data)
            (insert (propertize "❌ 데이터를 불러오는 데 실패했습니다." 'face 'error))
          
          (let ((comment (or (cdr (assoc "teacher_comment" data)) (cdr (assoc 'teacher_comment data)))))
            (when comment
              (insert (propertize "👩‍🏫 [ 선생님의 꿀팁 & 뉘앙스 ]\n" 'face 'neurallingo-panel-header-face))
              (insert (propertize (format "%s\n\n" comment) 'face 'neurallingo-teacher-face))))

          (let ((formal (or (cdr (assoc "formal_translation" data)) (cdr (assoc 'formal_translation data))))
                (informal (or (cdr (assoc "informal_translation" data)) (cdr (assoc 'informal_translation data)))))
            (when (or formal informal)
              (insert (propertize "📝 [ TRANSLATIONS ]\n" 'face 'neurallingo-panel-header-face))
              (insert (format "👔 격식 표현: %s\n" (or formal "-")))
              (insert (format "😎 비격식/슬랭: %s\n\n" (or informal "-")))))

          (insert (propertize "💡 [ KEY VOCABULARY ]\n" 'face 'neurallingo-panel-header-face))
          (let ((vocab-list (or (cdr (assoc "vocabulary" data)) (cdr (assoc 'vocabulary data)))))
            (if (and vocab-list (not (eq vocab-list 'null)))
                (mapc (lambda (v)
                        (insert (propertize (format "> %s" (or (cdr (assoc "word" v)) (cdr (assoc 'word v)) "알 수 없음")) 'face 'font-lock-variable-name-face))
                        (insert (format " [%s]\n  📖 뜻: %s\n"
                                        (or (cdr (assoc "pronunciation" v)) (cdr (assoc 'pronunciation v)) "-")
                                        (or (cdr (assoc "meaning" v)) (cdr (assoc 'meaning v)) "-")))
                        (insert (format "  🔗 연결고리: %s\n" (or (cdr (assoc "fun_connection" v)) (cdr (assoc 'fun_connection v)) "-")))
                        (insert (format "  🗣️ 발음 팁: %s\n" (or (cdr (assoc "pronunciation_tip" v)) (cdr (assoc 'pronunciation_tip v)) "-")))
                        (let ((examples (or (cdr (assoc "examples" v)) (cdr (assoc 'examples v)))))
                          (when (and examples (listp examples))
                            (insert "  📚 실생활 예문:\n")
                            (mapc (lambda (ex)
                                    (insert (propertize (format "      - %s\n" ex) 'face 'neurallingo-example-face)))
                                  examples)))
                        (insert "\n"))
                      vocab-list)
              (insert "로딩 중이거나 추출된 핵심 단어가 없습니다.\n\n")))

          (let ((qna-list (or (cdr (assoc "qna" data)) (cdr (assoc 'qna data)))))
            (when qna-list
              (insert (propertize "\n[ ADDITIONAL Q&A ]\n" 'face 'neurallingo-panel-header-face))
              (dolist (qna (reverse qna-list))
                (insert (propertize (format "Q: %s\n" (car qna)) 'face 'neurallingo-qna-question-face))
                (insert (format "A: %s\n\n" (cdr qna)))))))
        
        (goto-char (point-max))))))

;; 4. Vertex AI API 연동 (OAuth2 인증 방식, 개선됨)
(defun neurallingo--get-cached-access-token ()
  "Return a cached Vertex AI access token.
If the token is expired or not available, fetch a new one."
  (if (and neurallingo--token-cache
           (time-less-p (current-time) (cdr neurallingo--token-cache)))
      (car neurallingo--token-cache)
    (message "[NeuralLingo] Authenticating with gcloud...")
    (let ((token (string-trim (shell-command-to-string "gcloud auth print-access-token"))))
      (if (string-empty-p token)
          (error "[NeuralLingo] Failed to get access token from gcloud. Is it configured correctly?")
        (setq neurallingo--token-cache (cons token (time-add (current-time) (seconds-to-time 3500)))) ; Cache for just under an hour
        (car neurallingo--token-cache)))))

(defun neurallingo--request-gemini-async (prompt callback parse-json-p)
  "Vertex AI API 비동기 호출 (크레딧 사용 버전, 개선됨)."
  (let* ((token (neurallingo--get-cached-access-token))
         (url (format "https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/google/models/%s:generateContent"
                      neurallingo-location
                      neurallingo-project-id
                      neurallingo-location
                      neurallingo-model-id))
         (url-request-method "POST")
         (url-request-extra-headers `(("Content-Type" . "application/json")
                                      ("Authorization" . ,(encode-coding-string (format "Bearer %s" token) 'utf-8))))
         (payload-alist `(("contents" . [(("parts" . [(("text" . ,prompt))]) ("role" . "user"))])))
         (payload-alist (if parse-json-p
                            (append payload-alist '(("generationConfig" . (("responseMimeType" . "application/json")))))
                          payload-alist))
         (url-request-data (encode-coding-string (json-encode payload-alist) 'utf-8))
         (url-retrieve-timeout neurallingo-request-timeout)
         (final-url (encode-coding-string url 'utf-8)))
    (url-retrieve final-url
                  (lambda (status cb is-json)
                    (unwind-protect
                        (with-current-buffer (current-buffer)
                          (let ((err (plist-get status :error)))
                            (if err
                                (message "[NeuralLingo] Request failed: %s" err)
                              (progn
                                ;; Check HTTP status
                                (goto-char (point-min))
                                (let ((http-status nil))
                                  (when (re-search-forward "^HTTP/[0-9.]* +\\([0-9]+\\)" nil t)
                                    (setq http-status (string-to-number (match-string 1))))
                                  (re-search-forward "^$" nil 'move)
                                  (forward-line)
                                  (let ((response-str (decode-coding-string (buffer-substring-no-properties (point) (point-max)) 'utf-8)))
                                    (if (and http-status (>= http-status 200) (< http-status 300))
                                        ;; Success, parse response
                                        (condition-case err
                                            (let* ((json-object-type 'alist)
                                                   (json-key-type 'string)
                                                   (json-array-type 'list)
                                                   (response (json-read-from-string response-str))
                                                   (candidates (cdr (assoc "candidates" response)))
                                                   (candidate (car candidates))
                                                   (content (cdr (assoc "content" candidate)))
                                                   (parts (cdr (assoc "parts" content)))
                                                   (part (car parts))
                                                   (text (cdr (assoc "text" part))))
                                              (if (and text (stringp text))
                                                  (let ((parsed-text (if is-json 
                                                                         (json-read-from-string text)
                                                                       text)))
                                                    (funcall cb parsed-text))
                                                (message "[NeuralLingo] Error: Could not find 'text' in response. Raw response: %s" response-str)))
                                          (error (message "[NeuralLingo] JSON parsing error: %s (Raw: %s)" err response-str)))
                                      ;; Not 2xx, API error
                                      (message "[NeuralLingo] API Error (HTTP %s): %s"
                                               (or http-status "N/A")
                                               response-str))))))))
                    (kill-buffer (current-buffer))))
                  (list callback parse-json-p))))
;; 5. 메인 명령어: 문장 분석 (C-c a)
(defun neurallingo-analyze-current-sentence ()
  "현재 문장 분석 시작."
  (interactive)
  (let* ((bounds (neurallingo--bounds-of-sentence-at-point))
         (beg (car bounds))
         (end (cdr bounds))
         (sentence (buffer-substring-no-properties beg end))
         (cached-data (gethash sentence neurallingo--analysis-cache)))
    
    (neurallingo--highlight-region beg end)
    
    (if cached-data
        (progn
          (message "[NeuralLingo] ⚡ 캐시된 분석 결과를 불러왔습니다.")
          (neurallingo--display-result cached-data sentence))
      (let ((buf (neurallingo--prepare-panel)))
        (neurallingo--display-result '(("formal_translation" . "선생님이 생각 중...")) sentence)
        (neurallingo--show-loading buf (format "CONNECTING TO VERTEX AI (%s)..." neurallingo-project-id))
        (message "[NeuralLingo] 구글 클라우드 크레딧을 사용하여 분석 중입니다...")
        
        (let* ((safe-sentence (substring (json-encode sentence) 1 -1))
               (prompt (format  "You are a highly competent, friendly, and humorous English teacher bridging Korean and English.
Your goal is to help the user understand English naturally or translate Korean into natural English.
Use easy-to-understand analogies instead of complex grammar jargon. Maintain an energetic and humorous tone.

Rules:
1. Provide a welcoming 'teacher_comment' addressing the overall nuance of the sentence and giving native-like pronunciation/intonation feedback.
2. Provide both a formal translation and an informal/slang-friendly translation.
3. Extract key vocabulary. For each word, provide a 'fun_connection' (etymology, mnemonic using similar-sounding Korean words, or cultural context) to make it unforgettable.
4. Provide a 'pronunciation_tip' for each word focusing on stress and native-like linking.
5. Provide exactly TWO practical, real-life examples for each vocabulary word.
6. Do NOT include trailing commas.

Sentence: \"%s\"

Respond ONLY with a valid JSON object matching exactly this schema:
{
  \"teacher_comment\": \"Humorous greeting + explanation of sentence nuance (no jargon) + sentence-level intonation/stress tips.\",
  \"formal_translation\": \"Formal Korean translation\",
  \"informal_translation\": \"Informal, natural, or slang-friendly Korean translation\",
  \"vocabulary\": [
    {
      \"word\": \"keyword\",
      \"pronunciation\": \"pronunciation symbol & Korean spelling\",
      \"meaning\": \"Korean meaning\",
      \"fun_connection\": \"Fun etymology, mnemonic, or cultural link\",
      \"pronunciation_tip\": \"Tips on linking, stress, native sounding\",
      \"examples\": [\"Real-life example 1 with Korean translation\", \"Real-life example 2 with Korean translation\"]
    }
  ]
}" safe-sentence)))
          
          (neurallingo--request-gemini-async prompt
           (lambda (parsed-data)
             (puthash sentence parsed-data neurallingo--analysis-cache)
             (neurallingo--display-result parsed-data sentence)
             (message "[NeuralLingo] 분석 완료!"))
           t))))))

;; 6. 메인 명령어: 꼬리 질문 (C-c q)
(defun neurallingo-ask-question ()
  (interactive)
  (let* ((bounds (neurallingo--bounds-of-sentence-at-point))
         (sentence (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (cached-data (gethash sentence neurallingo--analysis-cache)))
    
    (if (not cached-data)
        (message "[NeuralLingo] 이 문장을 먼저 분석해주세요 (C-c a)")
      (let ((question (read-string "선생님께 질문하기: ")))
        (when (not (string-empty-p question))
          (let* ((analysis-copy (copy-alist cached-data))
                 ;; Q&A 히스토리는 따로 뺍니다 (프롬프트 구성용)
                 (history (cdr (or (assoc "qna" analysis-copy) (assoc 'qna analysis-copy))))
                 ;; 분석 데이터에서 qna는 제외하고 순수 분석 내용만 JSON으로 변환
                 (_ (setq analysis-copy (assoc-delete-all "qna" (assoc-delete-all 'qna analysis-copy))))
                 (analysis-json (json-encode analysis-copy))
                 (history-str (if history 
                                  (mapconcat (lambda (qna) (format "Q: %s\nA: %s" (car qna) (cdr qna))) (reverse history) "\n")
                                "No previous questions."))
                 (prompt (format "You are a friendly and humorous English teacher.
The student is studying this sentence: \"%s\"

[Initial Analysis Provided to Student]:
%s

[Previous Q&A History]:
%s

[Student's New Question]:
\"%s\"

Please answer the student's question kindly in Korean, keeping the teacher persona and referencing the analysis if needed." 
                                 sentence analysis-json history-str question)))
            
            (let ((buf (neurallingo--prepare-panel)))
              (neurallingo--show-loading buf (format "질문 답변 중: %s" question))
              (neurallingo--request-gemini-async prompt
               (lambda (answer)
                 (let* ((current-data (gethash sentence neurallingo--analysis-cache))
                        (qna-cell (or (assoc "qna" current-data)
                                     (assoc 'qna current-data))))
                   (if qna-cell
                       (setcdr qna-cell (cons (cons question answer) (cdr qna-cell)))
                     (puthash sentence (cons (cons "qna" (list (cons question answer))) current-data) neurallingo--analysis-cache))
                   (neurallingo--display-result (gethash sentence neurallingo--analysis-cache) sentence)
                   (message "[NeuralLingo] 답변 도착!")))
               nil))))))))

;; 7. 세션 저장/불러오기 유틸리티
(defun neurallingo--get-session-file-path ()
  (let* ((raw-name (buffer-name))
         (safe-name (replace-regexp-in-string "[^A-Za-z0-9가-힣.-]" "_" raw-name)))
    (expand-file-name (format "%s.json" safe-name) neurallingo-cache-dir)))

(defun neurallingo-save-session ()
  (interactive)
  (let ((data nil)
        (file-path (neurallingo--get-session-file-path))
        (coding-system-for-write 'utf-8))
    (unless (file-exists-p neurallingo-cache-dir) (make-directory neurallingo-cache-dir t))
    (maphash (lambda (k v) (push (cons k v) data)) neurallingo--analysis-cache)
    (with-temp-file file-path 
      (set-buffer-file-coding-system 'utf-8)
      (insert (if data (json-encode data) "{}")))
    (message "[NeuralLingo] 세션 저장 완료.")))

(defun neurallingo-load-session ()
  (interactive)
  (let ((file-path (neurallingo--get-session-file-path))
        (coding-system-for-read 'utf-8))
    (if (file-exists-p file-path)
        (let* ((json-object-type 'alist)
               (json-key-type 'string)
               (data (json-read-file file-path)))
          (clrhash neurallingo--analysis-cache)
          (when data (dolist (item data) (puthash (car item) (cdr item) neurallingo--analysis-cache)))
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (let* ((bounds (neurallingo--bounds-of-sentence-at-point))
                     (sentence (buffer-substring-no-properties (car bounds) (cdr bounds))))
                (when (gethash sentence neurallingo--analysis-cache)
                  (neurallingo--highlight-region (car bounds) (cdr bounds))))
              (forward-sentence)))
          (message "[NeuralLingo] 세션 로드 완료!"))
      (message "[NeuralLingo] 저장된 파일이 없습니다."))))

;; 8. 키맵 및 모드 설정
(defvar neurallingo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") 'neurallingo-analyze-current-sentence)
    (define-key map (kbd "C-c q") 'neurallingo-ask-question)
    (define-key map (kbd "C-c s") 'neurallingo-save-session)
    (define-key map (kbd "C-c l") 'neurallingo-load-session)
    (define-key map (kbd "C-c c") 'neurallingo-clear-all-highlights)
    map))

;;;###autoload
(define-minor-mode neurallingo-mode
  "Vertex AI를 사용하는 영어 분석 마이너 모드."
  :lighter " NLingo(V)"
  :keymap neurallingo-mode-map)

(provide 'neurallingo)
