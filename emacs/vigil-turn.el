;;; vigil-turn.el --- One turn of an agent's conversation, call by call -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `vigil-turn' (C-c C-t in an agent's buffer, T on a call being inspected or
;; in the context buffer): what the agent did in one turn -- between one of
;; your prompts and the next -- as a list of its calls in the order they
;; came: when each began, counted from the prompt, how long it took, how it
;; went, and what it was: "created src/x.py", "edited README.md", the
;; command it ran.  A subagent's calls come under the call that launched it.
;;
;; It opens on the turn of the call nearest point -- in the conversation, the
;; last call marked at or above it -- with that call's line selected, in the
;; frame calls are inspected in.  Moving through the list scrolls the
;; conversation behind it to each call's line and lights it up, as stepping
;; through calls does; RET or a click inspects the call, and `l' comes back
;; from it to the list; `o' goes to its line in the conversation.  `]' and `[' go to the next and
;; previous turn.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'hl-line)
(require 'vigil)
(require 'vigil-transcript)

(declare-function cooked-annotation-beg "cooked-annotate")
(declare-function cooked-popup-buffer "cooked-popup")
(declare-function cooked-popup-mode "cooked-popup")

(defvar-local vigil-turn--agent nil "The agent buffer this turn is of.")
(defvar-local vigil-turn--turn nil
  "Which turn this is: how many prompts were given before its calls.")
(defvar-local vigil-turn--current nil "The call the cursor was last on.")

(defun vigil-turn--prompts (agent)
  "The prompts that began AGENT's turns, oldest first."
  (vigil--user-prompts (buffer-local-value 'vigil--prompts agent)))

(defun vigil-turn--of (call agent)
  "Which of AGENT's turns CALL was in."
  (vigil--turn (or (vigil-call-start call) 0)
               (buffer-local-value 'vigil--prompts agent)))

(defun vigil-turn--calls (agent turn)
  "AGENT's calls in TURN, in the order they came."
  (cl-remove-if-not (lambda (call) (eql (vigil-turn--of call agent) turn))
                    (buffer-local-value 'vigil--order agent)))

(defun vigil-turn--call-near (position agent)
  "The call marked nearest POSITION in AGENT's conversation.
The last one marked at or above it; failing that, the first below it."
  (let (before after)
    (dolist (call (buffer-local-value 'vigil--order agent))
      (when-let* ((annotation (vigil-call-annotation call))
                  (at (marker-position (cooked-annotation-beg annotation))))
        (if (<= at position)
            (when (or (null before) (>= at (car before)))
              (setq before (cons at call)))
          (when (or (null after) (< at (car after)))
            (setq after (cons at call))))))
    (cdr (or before after))))

(defun vigil-turn--what (call)
  "What CALL did, in a few words: \"created x.py\", the command it ran."
  (let* ((summary (car (split-string (vigil--summary call) "\n")))
         (response (and (consp (vigil-call-response call)) (vigil-call-response call))))
    (pcase (vigil-call-name call)
      ("Write" (concat (if (equal (alist-get 'type response) "update") "rewrote " "created ")
                       summary))
      ((or "Edit" "MultiEdit" "NotebookEdit") (concat "edited " summary))
      ("Read" (concat "read " summary))
      ((or "Grep" "Glob") (concat "searched for " summary))
      ((or "Agent" "Task")
       (concat (format "[%s] %s" (or (alist-get 'subagent_type (vigil-call-input call)) "?")
                       summary)
               ;; While it runs: how many calls it has made, and the last.
               (if-let* ((subagent (vigil-call-subagent call))
                         (progress (vigil--subagent-progress subagent)))
                   (propertize (concat "  " progress) 'face 'shadow)
                 "")))
      ("Skill" (or (alist-get 'skill (vigil-call-input call)) summary))
      (_ (let ((description (alist-get 'description (vigil-call-input call))))
           ;; A command's first line may say little (`python3 - <<EOF'); the
           ;; agent's own words for it say what it was for.
           (if (and (stringp description) (stringp (alist-get 'command (vigil-call-input call))))
               (concat description "  " (propertize summary 'face 'shadow))
             summary))))))

(defun vigil-turn--status (call)
  "How CALL went, as a word in a face, or nothing if it simply finished."
  (let ((status (if (vigil--background-p (vigil-call-response call))
                    "background"
                  (vigil--status call))))
    (pcase status
      ("done" "")
      ("background" (propertize status 'face 'shadow))
      ("running" (propertize status 'face 'warning))
      (_ (propertize status 'face 'error)))))

(defun vigil-turn--since (seconds)
  "SECONDS since a turn began, as +M:SS."
  (let ((s (max 0 (floor seconds))))
    (format "+%d:%02d" (/ s 60) (% s 60))))

(defun vigil-turn--prompt (agent turn)
  "The prompt that began TURN of AGENT's, if there was one."
  (and (> turn 0) (nth (1- turn) (vigil-turn--prompts agent))))

(defun vigil-turn--entries ()
  "The rows of this turn's list: its calls, in order."
  (let* ((agent vigil-turn--agent)
         (calls (vigil-turn--calls agent vigil-turn--turn))
         (prompt (vigil-turn--prompt agent vigil-turn--turn))
         (began (or (and prompt (vigil--prompt-time prompt))
                    (and calls (vigil-call-start (car calls)))
                    0)))
    (mapcar (lambda (call)
              (list call
                    (vector (if (vigil-call-start call)
                                (vigil-turn--since (- (vigil-call-start call) began))
                              "")
                            (vigil--took call)
                            (let ((tokens (vigil--context call agent)))
                              (if tokens (vigil--tokens tokens) ""))
                            (vigil-turn--status call)
                            (concat (if (vigil-call-agent call) "  ↳ " "")
                                    (vigil-call-name call))
                            (vigil-turn--what call))))
            calls)))

(defun vigil-turn--header ()
  "This turn's header line: which, when, how many calls, how long, and its prompt."
  (let* ((agent vigil-turn--agent)
         (turn vigil-turn--turn)
         (prompts (vigil-turn--prompts agent))
         (prompt (vigil-turn--prompt agent turn))
         (calls (vigil-turn--calls agent turn))
         (began (or (and prompt (vigil--prompt-time prompt))
                    (and calls (vigil-call-start (car calls)))))
         (next (nth turn prompts))
         (reply (cl-find-if (lambda (note)
                              (and (eq (plist-get note :kind) 'reply)
                                   began (>= (plist-get note :time) began)
                                   (or (null next)
                                       (< (plist-get note :time)
                                          (or (vigil--prompt-time next) 0)))))
                            (buffer-local-value 'vigil--notes agent)))
         (ended (or (and reply (plist-get reply :time))
                    (cl-loop for call in calls
                             maximize (or (vigil-call-end call) (vigil-call-start call) 0))))
         (text (and prompt (car (split-string (string-trim (vigil--prompt-text prompt))
                                              "\n")))))
    (string-replace
     "%" "%%"
     (string-join
      (delq nil (list (if (> turn 0)
                          (format "Turn %d/%d" turn (length prompts))
                        "Before the first prompt")
                      (vigil--time began)
                      (format "%d call%s" (length calls) (if (= (length calls) 1) "" "s"))
                      (and began ended (> ended began)
                           (concat (vigil--for (- ended began))
                                   (if reply "" " so far")))
                      text))
      "  ·  "))))

(defun vigil-turn--follow ()
  "Show the call on this line in the conversation, if the cursor moved to another.
On `post-command-hook'."
  (let ((call (tabulated-list-get-id)))
    (unless (eq call vigil-turn--current)
      (setq vigil-turn--current call)
      (when call
        (let ((vigil--continuing t))
          (vigil--follow call vigil-turn--agent))))))

(defvar vigil-turn-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-turn-inspect)
    (define-key map [mouse-1] #'vigil-turn-inspect-mouse)
    (define-key map (kbd "i") #'vigil-turn-inspect)
    (define-key map (kbd "o") #'vigil-turn-goto)
    (define-key map (kbd "]") #'vigil-turn-next)
    (define-key map (kbd "[") #'vigil-turn-previous)
    (define-key map [remap cooked-popup-quit] #'vigil-popup-quit)
    map)
  "Keys of `vigil-turn-mode'.")

(define-derived-mode vigil-turn-mode tabulated-list-mode "Turn"
  "One turn of an agent's conversation, call by call.
\\{vigil-turn-mode-map}"
  (setq tabulated-list-format [("At" 6 nil :right-align t) ("Took" 7 nil :right-align t)
                               ("Context" 7 nil :right-align t) ("" 11 nil) ("Call" 12 nil) ("What" 0 nil)]
        tabulated-list-padding 1
        ;; The column names in the buffer, so the header line can say which turn.
        tabulated-list-use-header-line nil
        tabulated-list-entries #'vigil-turn--entries)
  (setq-local mode-line-format
              " RET inspect  o conversation  n p move  ] next turn  [ previous turn  q close")
  (add-hook 'post-command-hook #'vigil-turn--follow nil t)
  (hl-line-mode 1))

(defun vigil-turn--show (agent turn &optional call)
  "Show TURN of AGENT's conversation, with the cursor on CALL, or its first call."
  (let ((buffer (get-buffer-create "*vigil turn*"))
        (vigil--continuing (vigil--popup-up-p)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (vigil-turn-mode)
        (setq vigil-turn--agent agent
              vigil-turn--turn turn
              default-directory (buffer-local-value 'default-directory agent))
        (tabulated-list-init-header)
        (tabulated-list-print)
        (setq header-line-format (vigil-turn--header))
        (goto-char (point-min))
        (forward-line 1)                ; past the column names
        (when call
          (let ((at (save-excursion
                      (goto-char (point-min))
                      (catch 'found
                        (while (not (eobp))
                          (when (eq (tabulated-list-get-id) call) (throw 'found (point)))
                          (forward-line 1))))))
            (when at (goto-char at))))
        (setq vigil-turn--current (tabulated-list-get-id))
        (cooked-popup-mode 1)))
    (cooked-popup-buffer buffer)
    (with-current-buffer buffer
      (when vigil-turn--current
        (vigil--follow vigil-turn--current agent)))
    buffer))

(defun vigil-turn--call ()
  "The call on this line, or an error saying there is none."
  (or (tabulated-list-get-id) (user-error "No call on this line")))

(defun vigil-turn-goto ()
  "Go to the line of the conversation where the call on this line shows."
  (interactive)
  (vigil-goto-call (vigil-turn--call) vigil-turn--agent))

(defun vigil-turn-inspect ()
  "Inspect the call on this line; \\`l' there comes back to this turn."
  (interactive)
  (vigil-inspect (vigil-turn--call) vigil-turn--agent))

(defun vigil-turn-inspect-mouse (event)
  "Inspect the call clicked on; \\`l' there comes back to this turn.
EVENT is the click."
  (interactive "e")
  (mouse-set-point event)
  (vigil-turn-inspect))

(defun vigil-turn--step (n)
  "Show the turn N after this one; before it, if N is negative."
  (let* ((agent vigil-turn--agent)
         (turn (+ vigil-turn--turn n))
         (last (length (vigil-turn--prompts agent))))
    (unless (<= 0 turn last)
      (user-error "No %s turn" (if (> n 0) "later" "earlier")))
    (vigil-turn--show agent turn)))

(defun vigil-turn-next ()
  "Show the agent's next turn."
  (interactive)
  (vigil-turn--step 1))

(defun vigil-turn-previous ()
  "Show the agent's previous turn."
  (interactive)
  (vigil-turn--step -1))

(defun vigil-turn--start ()
  "The call to open a turn on, and its agent buffer: (CALL . AGENT).
The call being inspected, or the one at point in the context buffer, or the
one marked nearest point in the conversation."
  (let* ((normal (lambda (item)
                   (cond ((vigil-subagent-p item) (vigil-subagent-call item))
                         ((vigil--group-p item) (car item))
                         (t item)))))
    (cond
     ((and vigil--popup-call (buffer-live-p vigil--popup-agent))
      (cons (funcall normal vigil--popup-call) vigil--popup-agent))
     ((derived-mode-p 'vigil-context-mode)
      (cons (funcall normal (vigil--context-item)) vigil--context-agent))
     (t
      (let ((agent (vigil--target-agent)))
        (cons (vigil-turn--call-near
               (with-current-buffer agent
                 (if-let* ((window (get-buffer-window agent)))
                     (window-point window)
                   (point)))
               agent)
              agent))))))

;;;###autoload
(defun vigil-turn ()
  "Show the turn of the call nearest point, call by call, and that call in it.
See vigil-turn.el."
  (interactive)
  (pcase-let* ((`(,call . ,agent) (vigil-turn--start))
               (agent (or agent (user-error "Not an agent's buffer"))))
    (if (vigil-call-p call)
        (vigil-turn--show agent (vigil-turn--of call agent) call)
      ;; No call to start from: the latest turn.
      (vigil-turn--show agent (length (vigil-turn--prompts agent))))))

(define-key vigil-mode-map (kbd "C-c C-t") #'vigil-turn)
(define-key vigil-popup-mode-map (kbd "T") #'vigil-turn)
(define-key vigil-context-mode-map (kbd "T") #'vigil-turn)

(provide 'vigil-turn)
;;; vigil-turn.el ends here
