;;; neurallingo.el --- AI English Learning Assistant for Emacs -*- lexical-binding: t; -*-

;; Author: AI Assistant
;; Version: 2.7
;; Keywords: convenience, tools, learning

;;; Commentary:
;; 영어 기사나 텍스트를 읽을 때 문장 단위로 AI 분석을 제공합니다.
;; - C-c a: 문장 분석 (Gemini 2.5 Flash 연동, 연상법 포함)
;; - C-c q: 현재 문장에 대한 꼬리 질문 (미니버퍼 입력, 패널 하단에 누적)
;; - C-c s: 현재 문서(버퍼) 전용 학습 세션 자동 저장
;; - C-c l: 현재 문서(버퍼) 전용 학습 세션 불러오기 및 하이라이트 복원
;; - C-c r: 저장된 모든 세션을 모아 Org-mode 플래시카드로 복습(Remind)
;; - C-c c: 모든 흔적 지우기

;;; Code:

(require 'json)
(require 'url)

(defgroup neurallingo nil
  "AI English Learning Assistant."
  :group 'tools)

;; 사용자 지정 변수: Gemini API Key
(defcustom neurallingo-gemini-api-key ""
  "Google Gemini API Key for NeuralLingo."
  :type 'string
  :group 'neurallingo)

;; 사용자 지정 변수: 세션 저장 디렉토리
(defcustom neurallingo-cache-dir (expand-file-name "neurallingo" user-emacs-directory)
  "문서별 학습 기록(JSON)이 자동으로 분리되어 저장될 기본 디렉토리입니다."
  :type 'string
  :group 'neurallingo)

;; 1. 디자인 및 색상 설정 (Face Definitions)
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

(defvar neurallingo-buffer-name "*NeuralLingo-Analysis*"
  "Name of the buffer used for displaying AI analysis.")

;; 분석 결과를 저장할 해시 테이블 (메모리)
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

;; 3. 사이드 패널 윈도우 관리 및 렌더링
(defun neurallingo--prepare-panel (&optional _)
  "우측 패널 버퍼를 가져오거나 새로 생성하여 창을 분할합니다."
  (let ((buf (get-buffer-create neurallingo-buffer-name)))
    (display-buffer buf '(display-buffer-in-side-window (side . right) (window-width . 0.4)))
    buf))

(defun neurallingo--show-loading (buf message-text)
  "패널에 로딩 메시지를 추가합니다."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize (format "\n> %s\n" message-text) 'face 'warning)))))

(defun neurallingo--display-result (data sentence)
  "분석 결과(기본 데이터 + Q&A 내역)를 사이드 패널에 렌더링합니다."
  (let ((buf (neurallingo--prepare-panel)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; 원문 표시
        (insert (propertize "[ TARGET SENTENCE ]\n" 'face 'neurallingo-panel-header-face))
        (insert sentence "\n\n")

        ;; 번역 영역
        (insert (propertize "[ NATURAL TRANSLATION ]\n" 'face 'neurallingo-panel-header-face))
        (insert (or (cdr (assoc "translation" data)) "로딩 중이거나 데이터를 불러올 수 없습니다.") "\n\n")

        ;; 단어 영역 (연상법/Mnemonic 렌더링 추가)
        (insert (propertize "[ KEY VOCABULARY ]\n" 'face 'neurallingo-panel-header-face))
        (let ((vocab-list (cdr (assoc "vocabulary" data))))
          (if (and vocab-list (not (eq vocab-list 'null)))
              (mapc (lambda (v)
                      (insert (propertize (format "> %s" (or (cdr (assoc "word" v)) "알 수 없음")) 'face 'font-lock-variable-name-face))
                      (insert (format " [%s]\n  뜻: %s\n  반의어: %s\n  연상법: %s\n\n"
                                      (or (cdr (assoc "pronunciation" v)) "-")
                                      (or (cdr (assoc "meaning" v)) "-")
                                      (or (cdr (assoc "antonym" v)) "-")
                                      (or (cdr (assoc "mnemonic" v)) "-"))))
                    vocab-list)
            (insert "로딩 중이거나 추출된 핵심 단어가 없습니다.\n\n")))

        ;; 배경지식 및 구조
        (insert (propertize "[ CONTEXT & BACKGROUND ]\n" 'face 'neurallingo-panel-header-face))
        (insert (or (cdr (assoc "context" data)) "로딩 중이거나 데이터를 불러올 수 없습니다.") "\n")

        ;; 💡 꼬리 질문(Q&A) 내역 렌더링
        (let ((qna-list (cdr (assoc "qna" data))))
          (when qna-list
            (insert (propertize "\n[ ADDITIONAL Q&A ]\n" 'face 'neurallingo-panel-header-face))
            (dolist (qna (reverse qna-list))
              (insert (propertize (format "Q: %s\n" (car qna)) 'face 'neurallingo-qna-question-face))
              (insert (format "A: %s\n\n" (cdr qna))))))
        
        (goto-char (point-max))))))

;; 4. Gemini API 연동
(defun neurallingo--request-gemini-async (prompt callback parse-json-p)
  "Gemini API 비동기 호출 공통 함수."
  (if (string-empty-p neurallingo-gemini-api-key)
      (error "[NeuralLingo] 오류: `neurallingo-gemini-api-key`가 설정되지 않았습니다.")
    (let* ((url-request-method "POST")
           (url-request-extra-headers '(("Content-Type" . "application/json")))
           (payload-alist `(("contents" . [(("parts" . [(("text" . ,prompt))]) ("role" . "user"))])))
           (payload-alist (if parse-json-p
                              (append payload-alist '(("generationConfig" . (("responseMimeType" . "application/json")))))
                            payload-alist))
           (url-request-data (encode-coding-string (json-encode payload-alist) 'utf-8))
           (url (format "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=%s" neurallingo-gemini-api-key)))
      
      (url-retrieve url
                    (lambda (status cb is-json)
                      (if (plist-get status :error)
                          (message "[NeuralLingo] API 요청 실패: %s" (plist-get status :error))
                        (goto-char (point-min))
                        (re-search-forward "^$" nil 'move)
                        (forward-line)
                        (let* ((response-str (decode-coding-string (buffer-substring-no-properties (point) (point-max)) 'utf-8)))
                          (kill-buffer (current-buffer))
                          (condition-case err
                              (let* ((json-object-type 'alist)
                                     (json-array-type 'list)
                                     (json-key-type 'string)
                                     (response (json-read-from-string response-str))
                                     (candidates (cdr (assoc "candidates" response)))
                                     (content (cdr (assoc "content" (car candidates))))
                                     (parts (cdr (assoc "parts" content)))
                                     (text (cdr (assoc "text" (car parts)))))
                                (if is-json
                                    (funcall cb (json-read-from-string text))
                                  (funcall cb text)))
                            (error (message "[NeuralLingo] 응답 처리 에러: %S" err))))))
                    (list callback parse-json-p)))))

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
        (neurallingo--display-result '(("translation" . "로딩 중...")) sentence)
        (neurallingo--show-loading buf "CONNECTING TO GEMINI...")
        (message "[NeuralLingo] Gemini AI 분석 스캐닝 중...")
        
        (let ((prompt (format "You are an expert English teacher for Korean speakers. Analyze the following sentence.
Respond ONLY with a valid JSON object.
{ \"translation\": \"Natural Korean translation\", \"vocabulary\": [ {\"word\": \"word\", \"pronunciation\": \"pron\", \"meaning\": \"Korean meaning\", \"antonym\": \"antonym\", \"mnemonic\": \"A short, clever mnemonic (연상법/기억술) to remember the word in Korean\"} ], \"context\": \"Grammar and context explanation\" }
Sentence: \"%s\"" (replace-regexp-in-string "\"" "\\\"" sentence))))
          
          (neurallingo--request-gemini-async prompt
           (lambda (parsed-data)
             (puthash sentence parsed-data neurallingo--analysis-cache)
             (neurallingo--display-result parsed-data sentence)
             (message "[NeuralLingo] AI 분석 완료!"))
           t))))))

;; 6. 메인 명령어: 꼬리 질문 (C-c q)
(defun neurallingo-ask-question ()
  "현재 문장에 대해 AI에게 꼬리 질문을 던지고 패널에 누적합니다."
  (interactive)
  (let* ((bounds (neurallingo--bounds-of-sentence-at-point))
         (sentence (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (cached-data (gethash sentence neurallingo--analysis-cache)))
    
    (if (not cached-data)
        (message "[NeuralLingo] 이 문장을 먼저 분석해주세요 (C-c a)")
      (let ((question (read-string (format "질문 입력 (문맥: %s...): " (substring sentence 0 (min 20 (length sentence)))))))
        (when (not (string-empty-p question))
          (let ((buf (neurallingo--prepare-panel)))
            (neurallingo--show-loading buf (format "질문 분석 중: %s" question))
            (message "[NeuralLingo] 답변을 기다리는 중...")
            
            (let ((prompt (format "You are an English teacher. Context Sentence: \"%s\"
User Question: \"%s\"
Answer the question based on the context. Respond ONLY with the answer in Korean (No markdown formatting)." 
                                  (replace-regexp-in-string "\"" "\\\"" sentence)
                                  (replace-regexp-in-string "\"" "\\\"" question))))
              
              (neurallingo--request-gemini-async prompt
               (lambda (answer)
                 (let ((qna-cell (assoc "qna" cached-data)))
                   (if qna-cell
                       (setcdr qna-cell (cons (cons question answer) (cdr qna-cell)))
                     (puthash sentence (cons (cons "qna" (list (cons question answer))) cached-data) neurallingo--analysis-cache)))
                 (neurallingo--display-result (gethash sentence neurallingo--analysis-cache) sentence)
                 (message "[NeuralLingo] 질문에 대한 답변이 추가되었습니다!"))
               nil))))))))

;; 7. 세션 자동 저장 및 관리를 위한 유틸리티 함수
(defun neurallingo--get-session-file-path ()
  "현재 버퍼에 맞는 고유한 세션 파일 경로를 반환합니다."
  (let* ((raw-name (buffer-name))
         (safe-name (replace-regexp-in-string "[^A-Za-z0-9가-힣.-]" "_" raw-name)))
    (expand-file-name (format "%s.json" safe-name) neurallingo-cache-dir)))

;; 8. 메인 명령어: 세션 저장, 불러오기, 그리고 복습(Remind) 기능
(defun neurallingo-save-session ()
  "현재 분석된 모든 데이터와 질문 내역을 현재 버퍼 전용 JSON 파일로 저장합니다."
  (interactive)
  (let ((data nil)
        (file-path (neurallingo--get-session-file-path)))
    (unless (file-exists-p neurallingo-cache-dir)
      (make-directory neurallingo-cache-dir t))
    
    (maphash (lambda (k v) (push (cons k v) data)) neurallingo--analysis-cache)
    (with-temp-file file-path
      (insert (if data (json-encode data) "{}")))
    (message "[NeuralLingo] 현재 버퍼(%s)의 세션이 저장되었습니다." (buffer-name))))

(defun neurallingo-load-session ()
  "현재 버퍼 전용으로 저장된 세션을 불러오고 본문에 하이라이트를 복원합니다."
  (interactive)
  (let ((file-path (neurallingo--get-session-file-path)))
    (if (file-exists-p file-path)
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'string)
               (data (json-read-file file-path)))
          (clrhash neurallingo--analysis-cache)
          (when data
            (dolist (item data)
              (puthash (car item) (cdr item) neurallingo--analysis-cache)))
          
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (let* ((bounds (neurallingo--bounds-of-sentence-at-point))
                     (beg (car bounds))
                     (end (cdr bounds))
                     (sentence (buffer-substring-no-properties beg end)))
                (when (gethash sentence neurallingo--analysis-cache)
                  (neurallingo--highlight-region beg end)))
              (forward-sentence)))
          (message "[NeuralLingo] 문서 전용 세션을 성공적으로 불러왔습니다!"))
      (message "[NeuralLingo] 이 버퍼(%s)에 대해 저장된 세션 파일이 없습니다." (buffer-name)))))

(defun neurallingo-review ()
  "저장된 모든 세션을 모아 org-mode 기반의 복습(Remind) 플래시카드 버퍼를 생성합니다."
  (interactive)
  (unless (file-exists-p neurallingo-cache-dir)
    (error "[NeuralLingo] 저장된 학습 기록 폴더가 없습니다."))
  
  (let ((files (directory-files neurallingo-cache-dir t "\\.json$"))
        (buf (get-buffer-create "*NeuralLingo-Review*")))
    
    (if (null files)
        (message "[NeuralLingo] 복습할 세션 파일이 하나도 없습니다. 먼저 문서를 저장(C-c s)해 주세요.")
      
      (with-current-buffer buf
        (erase-buffer)
        ;; Org-mode 문서 헤더
        (insert "#+TITLE: NeuralLingo Review (단어 플래시카드)\n")
        (insert "#+STARTUP: content\n\n")
        (insert "💡 [학습 가이드] 영어 문장을 읽으며 스스로 뜻을 떠올려본 뒤, 'TAB' 키를 눌러 숨겨진 단어장을 펼쳐보세요!\n\n")
        
        ;; 모든 JSON 파일 순회
        (dolist (file files)
          (let* ((filename (file-name-base file))
                 (json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'string)
                 ;; 손상된 캐시 파일이 있더라도 에러로 멈추지 않도록 예외 처리
                 (data (condition-case nil
                           (json-read-file file)
                         (error nil))))
            
            (when (and data (not (eq data 'null)))
              (insert (format "* 📁 문서: %s\n" filename))
              (dolist (item data)
                (let* ((sentence (car item))
                       (details (cdr item))
                       (vocab-list (cdr (assoc "vocabulary" details))))
                  
                  ;; 단어가 추출된 문장만 복습 카드에 올림
                  (when (and sentence vocab-list (not (eq vocab-list 'null)))
                    (insert (format "** %s\n" sentence))
                    (insert "*** 💡 단어장 (TAB 눌러서 정답 확인)\n")
                    (dolist (v vocab-list)
                      (insert (format "    - %s [%s]\n" 
                                      (or (cdr (assoc "word" v)) "알 수 없음")
                                      (or (cdr (assoc "pronunciation" v)) "-")))
                      (insert (format "      뜻: %s\n" (or (cdr (assoc "meaning" v)) "-")))
                      (insert (format "      반의어: %s\n" (or (cdr (assoc "antonym" v)) "-")))
                      (insert (format "      연상법: %s\n\n" (or (cdr (assoc "mnemonic" v)) "-"))))))))))
        
        (org-mode)
        ;; 시작할 때 하위 트리(단어장)가 접혀 있도록 설정
        (org-cycle-set-startup-visibility)
        (switch-to-buffer buf)
        (message "[NeuralLingo] 복습 버퍼가 생성되었습니다! 문장에서 TAB을 눌러보세요.")))))

;; 9. Minor Mode 설정
(defvar neurallingo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") 'neurallingo-analyze-current-sentence)
    (define-key map (kbd "C-c q") 'neurallingo-ask-question)
    (define-key map (kbd "C-c s") 'neurallingo-save-session)
    (define-key map (kbd "C-c l") 'neurallingo-load-session)
    (define-key map (kbd "C-c r") 'neurallingo-review)
    (define-key map (kbd "C-c c") 'neurallingo-clear-all-highlights)
    map)
  "Keymap for `neurallingo-mode`.")

;;;###autoload
(define-minor-mode neurallingo-mode
  "영어 문장 단위 AI 분석 및 꼬리 질문을 제공하는 마이너 모드입니다."
  :init-value nil
  :lighter " NLingo"
  :keymap neurallingo-mode-map)

(provide 'neurallingo)
;;; neurallingo.el ends here
