;;; vigil-status-views.el --- How `M-x vigil' draws a session -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; What `M-x vigil' (vigil-status.el) draws, from what vigil-status-session.el
;; read, laid out with vigil-ui.el:
;;
;; - things said shortly: a duration, a time, how a call went, what a
;;   command was for;
;; - a turn as a timeline;
;; - the lines of the lists: a prompt, a commit, a changed file;
;; - a command whole: laid out to be read (vigil-command.el), what
;;   shellcheck says of it, what it was for and what it goes by;
;; - a turn in full, and a diff;
;; - the views: status, prompts, answers, commands, changes, build.
;;
;; Everything here inserts at point or gives a string: which buffer, and
;; when, is vigil-status.el's to say.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-ui)
(require 'vigil-command)
(require 'vigil-status-session)

;;;; Said shortly

(defun vigil-status--duration (seconds)
  "SECONDS in a few characters: 0.4s, 12s, 3m05s, 1h02m."
  (cond ((null seconds) "")
        ((< seconds 10) (format "%.1fs" seconds))
        ((< seconds 60) (format "%ds" (round seconds)))
        ((< seconds 3600) (format "%dm%02ds" (/ (round seconds) 60) (% (round seconds) 60)))
        (t (format "%dh%02dm" (/ (round seconds) 3600) (/ (% (round seconds) 3600) 60)))))

(defun vigil-status--clock (time &optional seconds)
  "TIME as this buffer says it: with the day, if the session began on another.
With SECONDS, to the second."
  (let ((first (plist-get (car vigil-status--turns) :start)))
    (format-time-string
     (concat (if (and first (not (equal (format-time-string "%F" first)
                                        (format-time-string "%F"))))
                 "%b %d " "")
             (if seconds "%H:%M:%S" "%H:%M"))
     time)))

(defun vigil-status--ago (time)
  "How long ago TIME was, in a few characters."
  (concat (vigil-status--duration (max 0 (- (float-time) time))) " ago"))

(defun vigil-status--counts (calls)
  "CALLS in a few words: how many, of which kinds, and how many failed."
  (if (null calls)
      "no calls"
    (let ((kinds '((command . "command") (wrote . "write") (look . "look")
                   (edit . "edit") (read . "read")
                   (subagent . "subagent") (web . "web") (other . "other")))
          (failed (cl-count 'failed calls :key #'vigil-survey-step-status))
          (unended (cl-count-if (lambda (call) (gethash call vigil-status--unended))
                                calls))
          said)
      (pcase-dolist (`(,kind . ,name) kinds)
        (let ((count (cl-count kind calls :key #'vigil-status--kind)))
          (when (> count 0)
            (push (format "%d %s%s" count name
                          (if (or (= count 1) (member name '("web" "other"))) "" "s"))
                  said))))
      (concat (format "%d call%s: " (length calls) (if (= 1 (length calls)) "" "s"))
              (string-join (nreverse said) ", ")
              (if (> failed 0) (format "; %d failed" failed) "")
              (if (> unended 0) (format "; %d reported no end" unended) "")))))

(defun vigil-status--state-said (call)
  "How CALL went, where it did not simply end well: a word or two, or none."
  (cond ((eq (vigil-survey-step-status call) 'failed)
         (propertize "failed" 'face 'vigil-ui-bad))
        ((vigil-status--running-p call) (propertize "running" 'face 'vigil-ui-busy))
        ((gethash call vigil-status--unended)
         (propertize "no end" 'face 'vigil-ui-bad))
        (t "")))

(defun vigil-status--tags-said (tags)
  "TAGS, what a command was for, in a few words: their names."
  (mapconcat (lambda (tag)
               (propertize (or (cdr (assq (car tag) vigil-purpose-names))
                               (symbol-name (car tag)))
                           'face (pcase (car tag)
                                   ((or 'code 'tests 'docs 'write) 'vigil-ui-kind-edit)
                                   ((or 'test 'check) 'vigil-ui-kind-test)
                                   ('look 'vigil-ui-kind-read)
                                   (_ 'default))))
             tags " "))

(defun vigil-status--tally (calls)
  "How many of CALLS, commands, were for each thing, in a few words."
  (let (counts)
    (dolist (call calls)
      (dolist (tag (vigil-status--tags call))
        (cl-incf (alist-get (car tag) counts 0))))
    (mapconcat (lambda (name)
                 (format "%d %s" (alist-get (car name) counts) (cdr name)))
               (seq-filter (lambda (name) (alist-get (car name) counts))
                           vigil-purpose-names)
               "   ")))

(defun vigil-status--call-said (call)
  "What CALL was about, in a line: why, in its agent's words, where it said.
And else the command itself, on one line, laid out and highlighted."
  (let ((said (vigil-survey-step-text call))
        (command (vigil-survey-step-command call)))
    (or (and command
             (equal said (vigil-survey--line command 120))
             vigil-status-tidy
             (ignore-errors (vigil-command-line command)))
        said
        (vigil-survey-step-name call)
        "")))

(defun vigil-status--refs-said (refs)
  "REFS, as git says the branches and tags at a commit, said shortly."
  (if refs
      (string-join
       (mapcar (lambda (ref)
                 (cond ((string-prefix-p "tag: " ref)
                        (propertize (substring ref 5) 'face 'vigil-ui-strong))
                       ((string-prefix-p "HEAD -> " ref) (substring ref 8))
                       (t ref)))
               (seq-remove (lambda (ref) (member ref '("HEAD")))
                           (split-string refs ", " t)))
       " ")
    ""))

(defun vigil-status--live-since ()
  "What the changes shown as changing now are counted from, in a few words."
  (let ((base (plist-get vigil-status--live :base)))
    (cond ((null base) "")
          ((eq vigil-status--since 'session)
           (format "since the session began at %s"
                   (vigil-status--clock (plist-get base :time))))
          (t (format "since the last prompt at %s"
                     (vigil-status--clock (plist-get base :time)))))))

;;;; A turn as a timeline

(defconst vigil-status--timeline-kinds
  '((failed "█" vigil-ui-bad "failed")
    (command "█" vigil-ui-kind-command "command")
    (edit "▓" vigil-ui-kind-edit "edit or write")
    (wrote "▓" vigil-ui-kind-edit "write")
    (test "▞" vigil-ui-kind-test "test or check")
    (read "░" vigil-ui-kind-read "read or look")
    (look "░" vigil-ui-kind-read "look")
    (subagent "▚" vigil-ui-kind-subagent "subagent")
    (web "▒" vigil-ui-kind-other "web")
    (other "▒" vigil-ui-kind-other "other")
    (nil "─" vigil-ui-dim "between calls"))
  "How each kind of call is drawn in a timeline: (KIND CHARACTER FACE NAME).
Each has a character of its own as well as a face, to be told apart where a
theme gives two faces one colour.")

(defun vigil-status--timeline-kind (call)
  "What kind CALL is drawn as in a timeline.
A command that wrote is drawn as a write; one that did not and ran tests or
a check, as a test; and else as what it is."
  (let ((kind (vigil-status--kind call)))
    (if (and (eq kind 'command)
             (cl-some (lambda (tag) (memq (car tag) '(test check)))
                      (vigil-status--tags call)))
        'test
      kind)))

(defun vigil-status--timeline (turn cells)
  "TURN as a timeline CELLS characters wide: what its agent was doing when.
Each character is an equal share of the turn, drawn as the kind of call
that took most of it, or as between calls where calls took under a third of
it.  A call that failed in a share makes it one that failed; and an edit
made in a share of nothing else makes it an edit's, an edit taking no time
to speak of.  A command after which the files differed is drawn as an edit
is.  A subagent's own calls are not drawn: the call that launched it is."
  (let* ((start (plist-get turn :start))
         (end (max (plist-get turn :end) (+ start 0.001)))
         (share (/ (- end start) (float cells)))
         (calls (seq-remove #'vigil-survey-step-agent (plist-get turn :calls)))
         (parts nil))
    (dotimes (i cells)
      (let ((from (+ start (* i share)))
            (to (+ start (* (1+ i) share)))
            (sums nil) (failed nil) (edited nil))
        (dolist (call calls)
          (let* ((a (vigil-survey-step-time call))
                 (b (+ a (or (vigil-status--took call) 0)))
                 (bad (or (eq (vigil-survey-step-status call) 'failed)
                          (gethash call vigil-status--unended)))
                 (overlap (- (min b to) (max a from))))
            (when (and bad (or (> overlap 0) (and (>= a from) (< a to))))
              (setq failed t))
            (when (and (eq (vigil-survey-step-kind call) 'edit) (>= a from) (< a to))
              (setq edited t))
            (when (> overlap 0)
              (cl-incf (alist-get (vigil-status--timeline-kind call) sums 0) overlap))))
        (let* ((most (car (sort sums (lambda (x y) (> (cdr x) (cdr y))))))
               (kind (cond (failed 'failed)
                           ((and most (>= (cdr most) (/ share 3))) (car most))
                           (edited 'edit)))
               (drawn (or (assq kind vigil-status--timeline-kinds)
                          (assq 'other vigil-status--timeline-kinds))))
          (push (propertize (nth 1 drawn) 'face (nth 2 drawn)) parts))))
    (apply #'concat (nreverse parts))))

(defun vigil-status--timeline-in-list (turn)
  "TURN's timeline as a list has it: as long as the turn was, among the turns.
The longest is `vigil-status-timeline-width' characters, and none is under one."
  (let ((longest (apply #'max 0.001
                        (mapcar (lambda (turn)
                                  (- (plist-get turn :end) (plist-get turn :start)))
                                vigil-status--turns))))
    (vigil-status--timeline
     turn
     (max 1 (round (* vigil-status-timeline-width
                      (/ (- (plist-get turn :end) (plist-get turn :start)) longest)))))))

(defun vigil-status--timeline-legend ()
  "What the characters of a timeline are, in a line."
  (concat
   (propertize "  " 'face 'vigil-ui-dim)
   (mapconcat (pcase-lambda (`(,_ ,character ,face ,name))
                (concat (propertize character 'face face)
                        (propertize (concat " " name) 'face 'vigil-ui-dim)))
              (seq-remove (lambda (kind) (memq (car kind) '(web look wrote)))
                          vigil-status--timeline-kinds)
              "   ")))

;;;; The lines of a list

(defun vigil-status--turn-columns (width)
  "The columns a prompt is listed in, in WIDTH columns of room.
With less than 110, the prompt and its timeline alone."
  (append '((:title "#" :right t) (:title "When") (:title "Took" :right t)
            (:title "Timeline") (:title "Prompt" :flex t))
          (and (>= width 110)
               '((:title "Calls" :right t) (:title "Files" :right t) (:title "Lines")))))

(defun vigil-status--turn-after (turn)
  "What changed after TURN's prompt, in two cells: how many files, and lines."
  (let ((after (nth 2 (vigil-status--built-after turn))))
    (list (if after (number-to-string (length after)) "")
          (if after
              (pcase-let ((`(,_ ,_ ,_ ,added ,removed) (vigil-review--totals after)))
                (vigil-ui-lines-changed added removed))
            ""))))

(defun vigil-status--calls-cell (turn)
  "How many calls TURN made, and how many of them failed, in a cell."
  (let* ((calls (plist-get turn :calls))
         (failed (cl-count-if (lambda (call)
                                (or (eq (vigil-survey-step-status call) 'failed)
                                    (gethash call vigil-status--unended)))
                              calls)))
    (concat (number-to-string (length calls))
            (if (> failed 0)
                (propertize (format " (%d failed)" failed) 'face 'vigil-ui-bad)
              ""))))

(defun vigil-status--took-cell (turn)
  "How long TURN took, in a cell: so far, where it has no reply."
  (concat (vigil-status--duration (- (plist-get turn :end) (plist-get turn :start)))
          (if (plist-get turn :reply) "" "…")))

(defun vigil-status--turn-cells (turn width)
  "What TURN says in each of the columns `vigil-status--turn-columns' gives WIDTH."
  (append
   (list (propertize (number-to-string (plist-get turn :index)) 'face 'vigil-ui-strong)
         (vigil-status--clock (plist-get turn :start))
         (vigil-status--took-cell turn)
         (vigil-status--timeline-in-list turn)
         (or (vigil-survey-step-text (plist-get turn :prompt)) ""))
   (and (>= width 110)
        (cons (vigil-status--calls-cell turn) (vigil-status--turn-after turn)))))

(defun vigil-status--turn-properties (turn)
  "The text properties the line TURN is listed on has."
  (list 'vigil-status-turn (plist-get turn :index)
        'vigil-status-heading t
        'vigil-status-text (vigil-survey-step-text (plist-get turn :prompt))))

(defconst vigil-status--commit-columns
  '((:title "When") (:title "Commit") (:title "Subject" :flex t) (:title "At")
    (:title "Changelog"))
  "The columns a commit is listed in.")

(defun vigil-status--commit-cells (commit)
  "What COMMIT says in each of `vigil-status--commit-columns'."
  (list (vigil-status--clock (plist-get commit :time))
        (propertize (substring (plist-get commit :hash) 0 7) 'face 'vigil-status-commit)
        (plist-get commit :subject)
        (vigil-status--refs-said (plist-get commit :refs))
        (propertize (string-join (plist-get commit :versions) " ") 'face 'vigil-ui-good)))

(defun vigil-status--changes-columns ()
  "The columns a changed file is listed in."
  '((:title "File" :flex t) (:title "Lines") (:title "Changed" :right t)))

(defun vigil-status--change-cells (change)
  "What CHANGE, a file that differs, says in each column of the list of them."
  (let* ((mark (vigil-review--mark (plist-get change :status)))
         (time (vigil-status--file-time (plist-get change :file))))
    ;; Its mark and its name are one: no column's width apart.
    (list (concat (propertize (car mark) 'face (cdr mark)) " " (plist-get change :file))
          (if (plist-get change :added)
              (vigil-ui-lines-changed (plist-get change :added) (plist-get change :removed))
            (propertize "not text" 'face 'vigil-ui-dim))
          (if time (vigil-status--ago time) ""))))

;;;; What is under a line, folded

(defun vigil-status--folded-before (key default)
  "Whether the fold KEY names was folded when this buffer was last drawn.
DEFAULT where it was not there then."
  (let ((known (assoc key vigil-status--folds)))
    (if known (cdr known) default)))

(defun vigil-status--note-folds ()
  "Remember which folds of this buffer are folded, to draw them so again."
  (dolist (fold (vigil-ui-folds))
    (when-let* ((key (overlay-get fold 'vigil-status-key)))
      (setf (alist-get key vigil-status--folds nil nil #'equal)
            (vigil-ui-folded-p fold)))))

(defun vigil-status--make-fold (body key folded)
  "Fold what was inserted from BODY to point, under the line before BODY.
KEY names it, to remember how it was left; FOLDED is how it is to begin."
  (when (> (point) body)
    (overlay-put (vigil-ui-fold-mark
                  (vigil-ui-fold-make (1- body) (1- (point))
                                           (count-lines body (point)) 'turn
                                           (vigil-status--folded-before key folded)))
                 'vigil-status-key key)))

;;;; A command, whole

(defvar vigil-status--shellchecked (make-hash-table :test #'equal)
  "What shellcheck said of each command, by its text.")

(defun vigil-status-shellcheck-notes (command)
  "What shellcheck says of COMMAND, a shell command as text.
Each (LINE COLUMN LEVEL MESSAGE CODE), of the command as it was given; nil
where it says nothing, or is not there to ask."
  (when-let* (((stringp command))
              (program (and vigil-status-shellcheck
                            (executable-find vigil-status-shellcheck))))
    (vigil-command-remember
     vigil-status--shellchecked command
     (lambda ()
       (with-temp-buffer
         (insert command)
         (let ((default-directory temporary-file-directory)
               (coding-system-for-read 'utf-8)
               (coding-system-for-write 'utf-8)
               found)
           (ignore-errors
             (call-process-region (point-min) (point-max) program t '(t nil) nil
                                  "-s" "bash" "-f" "gcc" "-S"
                                  vigil-status-shellcheck-level "-"))
           (goto-char (point-min))
           (while (re-search-forward
                   "^-:\\([0-9]+\\):\\([0-9]+\\): \\([a-z]+\\): \\(.*?\\)\\(?: \\[\\(SC[0-9]+\\)\\]\\)?$"
                   nil t)
             (push (list (string-to-number (match-string 1))
                         (string-to-number (match-string 2))
                         (match-string 3) (match-string 4) (match-string 5))
                   found))
           (nreverse found)))))))

(defun vigil-status--insert-code (text indent &rest properties)
  "Insert TEXT, code, INDENT spaces in: as it is, each line hanging if it wraps.
The spaces are not in the buffer.  PROPERTIES are text properties it has."
  (let ((start (point)))
    (insert (string-trim-right text) "\n")
    (add-text-properties start (point)
                         (append (list 'line-prefix (make-string indent ?\s)
                                       'wrap-prefix (make-string (+ indent 4) ?\s))
                                 properties))))

(defun vigil-status--insert-command (command id)
  "Insert COMMAND, the command of the call ID, whole and to be read.
Laid out and highlighted where it can be, the programs inside it under it,
and what shellcheck says of it after."
  (let ((tidy (and vigil-status-tidy (ignore-errors (vigil-command-tidy command))))
        (properties (list 'vigil-status-call id 'vigil-status-text command)))
    (apply #'vigil-status--insert-code
           (if tidy
               (plist-get tidy :shell)
             (propertize command 'face 'vigil-ui-code))
           2 properties)
    (pcase-dolist (`(,label . ,text) (plist-get tidy :blocks))
      (insert "\n")
      (apply #'vigil-status--insert-code label 2 properties)
      (apply #'vigil-status--insert-code text 4 properties))
    (when-let* ((notes (vigil-status-shellcheck-notes command)))
      (insert "\n" (propertize "shellcheck, of the command as it was given\n"
                               'face 'vigil-ui-dim))
      (pcase-let ((`(,_ . ,lines)
                   (vigil-ui-table
                    '((:right t) () (:flex t) ())
                    (mapcar (pcase-lambda (`(,line ,column ,level ,message ,code))
                              (list (format "%d:%d" line column)
                                    (propertize level 'face
                                                (if (equal level "error")
                                                    'vigil-ui-bad 'vigil-ui-busy))
                                    message
                                    (propertize (or code "") 'face 'vigil-ui-dim)))
                            notes)
                    (vigil-ui-width))))
        (dolist (line lines) (insert line "\n"))))
    (insert "\n")))

(defun vigil-status--insert-purpose (call)
  "Insert what the command CALL was for, and what it goes by.
Each thing it was for with why; the programs it runs and where they are;
and of each Python program inside it, what it imports, writes, reads and
runs."
  (let* ((command (vigil-survey-step-command call))
         (width (vigil-ui-width))
         (rows (lambda (rows)
                 (pcase-let ((`(,_ . ,lines)
                              (vigil-ui-table '(() (:flex t)) rows width)))
                   (dolist (line lines) (insert line "\n"))))))
    (insert (propertize "What it was for\n" 'face 'vigil-ui-dim))
    (funcall rows (mapcar (lambda (tag)
                            (list (vigil-status--tags-said (list tag)) (cdr tag)))
                          (vigil-status--tags call t)))
    (when-let* ((programs (ignore-errors
                            (vigil-purpose-programs command vigil-status--root))))
      (insert "\n" (propertize "Programs, where each is now\n" 'face 'vigil-ui-dim))
      (funcall rows (mapcar (lambda (program)
                              (list (car program) (abbreviate-file-name (cdr program))))
                            programs)))
    (pcase-dolist (`(,label . ,code) (ignore-errors (vigil-purpose-scripts command)))
      (when-let* ((scan (vigil-purpose-python code)))
        (insert "\n" (propertize (format "Python: %s\n" label) 'face 'vigil-ui-dim))
        (if (plist-get scan :error)
            (insert "  " (propertize (format "does not parse: %s" (plist-get scan :error))
                                     'face 'vigil-ui-bad)
                    "\n")
          (let ((said (lambda (key) (and (plist-get scan key)
                                         (string-join (plist-get scan key) ", ")))))
            (vigil-ui-sheet
             `(("imports" . ,(let ((standard (funcall said :standard))
                                   (others (funcall said :others)))
                               (and (or standard others)
                                    (concat (or others "")
                                            (if (and others standard) "; " "")
                                            (if standard
                                                (propertize
                                                 (concat standard ", of Python's own")
                                                 'face 'vigil-ui-dim)
                                              "")))))
               ("writes" . ,(funcall said :writes))
               ("reads" . ,(funcall said :reads))
               ("runs" . ,(funcall said :runs))
               ("asserts" . ,(and (> (plist-get scan :asserts) 0)
                                  (number-to-string (plist-get scan :asserts))))
               ("defines" . ,(and (> (plist-get scan :defines) 0)
                                  (vigil-ui-plural (plist-get scan :defines)
                                                   "function or class"
                                                   "functions and classes"))))
             2)))))
    (insert "\n")))

;;;; A turn in full, and a diff

(defun vigil-status--insert-turn (turn indent)
  "Insert what TURN's prompt led to: the prompt, its calls and the reply.
The name of each part INDENT spaces in, and the part two more."
  (let* ((prompt (plist-get turn :prompt))
         (reply (plist-get turn :reply))
         (calls (plist-get turn :calls))
         (index (plist-get turn :index))
         (start (plist-get turn :start))
         (label (lambda (text)
                  (insert (propertize (concat (make-string indent ?\s) text "\n")
                                      'face 'vigil-ui-dim)))))
    (funcall label "Prompt")
    (vigil-ui-block (vigil-survey-step-text prompt) (+ indent 2) 'vigil-ui-prompt
                    'vigil-status-turn index
                    'vigil-status-text (vigil-survey-step-text prompt))
    (when calls
      (funcall label (vigil-status--counts calls))
      (pcase-let ((`(,_ . ,rows)
                   (vigil-ui-table
                    '((:right t) (:right t) () () (:flex t))
                    (mapcar
                     (lambda (call)
                       (list (concat "+" (vigil-status--duration
                                          (max 0 (- (vigil-survey-step-time call) start))))
                             (vigil-status--duration (vigil-status--took call))
                             (concat (if (vigil-survey-step-agent call) "↳" "")
                                     (symbol-name (vigil-status--kind call)))
                             (vigil-status--state-said call)
                             (vigil-status--call-said call)))
                     calls)
                    (vigil-ui-width) (+ indent 2))))
        (dolist (call calls)
          (insert (propertize (concat (pop rows) "\n")
                              'vigil-status-call (vigil-survey-step-id call)
                              'vigil-status-turn index)))))
    (funcall label (if reply "Reply" "No reply yet"))
    (when reply
      (vigil-ui-block (vigil-ui-markdown (vigil-survey-step-text reply)) (+ indent 2)
                      'vigil-ui-dim
                      'vigil-status-turn index
                      'vigil-status-text (vigil-survey-step-text reply)))))

(defun vigil-status--insert-diff (file lines)
  "Insert LINES, the diff of FILE as git prints it, without its preamble.
Each line knows its file and which line of it it is."
  (let ((line nil) (count 0))
    (dolist (text lines)
      (cond
       ((string-match "\\`@@ -[0-9,]+ \\+\\([0-9]+\\)" text)
        (setq line (string-to-number (match-string 1 text)))
        (insert (propertize (concat "    " text "\n")
                            'face 'diff-hunk-header
                            'vigil-status-file file 'vigil-status-line line
                            'vigil-status-diff count)))
       ((null line))                     ; the preamble: which file, which blobs
       ((string-prefix-p "\\" text))
       (t
        (let ((removed (string-prefix-p "-" text)))
          (insert (propertize (concat "    " text "\n")
                              'face (cond ((string-prefix-p "+" text) 'diff-added)
                                          (removed 'diff-removed)
                                          (t 'diff-context))
                              'wrap-prefix "      "
                              'vigil-status-file file 'vigil-status-line line
                              'vigil-status-diff count))
          (unless removed (setq line (1+ line))))))
      (setq count (1+ count)))))

;;;; The views

(defun vigil-status--insert-status ()
  "Insert the status view: the session in short."
  (let* ((turns vigil-status--turns)
         (calls (apply #'append (mapcar (lambda (turn) (plist-get turn :calls)) turns)))
         (commands (seq-filter (lambda (call)
                                 (memq (vigil-status--kind call) '(command wrote)))
                               calls))
         (running (seq-filter #'vigil-status--running-p calls))
         (objective (vigil-survey-objective vigil-status--session))
         (subagents (vigil-survey-subagents vigil-status--session))
         (changes (plist-get vigil-status--built :changes))
         (now (plist-get vigil-status--live :changes))
         (width (vigil-ui-width)))
    (if (null turns)
        (insert "No prompt of this session has been reported.\n")
      (vigil-ui-sheet
       `(("Began" . ,(format "%s, %s"
                             (vigil-status--clock (plist-get (car turns) :start))
                             (vigil-status--ago (plist-get (car turns) :start))))
         ("Prompts" . ,(format "%d, the last at %s" (length turns)
                               (vigil-status--clock
                                (plist-get (car (last turns)) :start))))
         ("Calls" . ,(replace-regexp-in-string "\\`\\([0-9]+\\) calls?: " "\\1: "
                                               (vigil-status--counts calls)))
         ("Commands" . ,(and commands
                             (format "%s in all"
                                     (vigil-status--duration
                                      (apply #'+ (mapcar (lambda (call)
                                                           (or (vigil-status--took call) 0))
                                                         commands))))))
         ("Running" . ,(and running
                            (propertize
                             (format "%s: %s" (vigil-ui-plural (length running) "call")
                                     (vigil-ui-cut
                                      (or (vigil-survey-step-text (car (last running))) "")
                                      (- width 30)))
                             'face 'vigil-ui-busy)))
         ("Subagents" . ,(and subagents
                              (format "%d, %d running" (length subagents)
                                      (cl-count 'running subagents
                                                :key (lambda (s) (plist-get s :status))))))
         ("Working on" . ,(and objective
                               (format "%s  (%d of %d done)" (plist-get objective :text)
                                       (plist-get objective :done)
                                       (plist-get objective :total))))
         ("Built" . ,(cond ((null vigil-status--root) "It works in no repository.")
                           ((null vigil-status--built)
                            "No snapshot is kept of it: see `vigil snapshots on'.")
                           (t (vigil-review-changes-said changes))))))
      (when now
        (vigil-ui-heading "Changing now" (vigil-status--live-since) "l")
        (vigil-ui-insert-table
         (vigil-status--changes-columns)
         (mapcar #'vigil-status--change-cells (seq-take now 8))
         (mapcar (lambda (change) (list 'vigil-status-file (plist-get change :file)))
                 (seq-take now 8))
         width)
        (when (> (length now) 8)
          (insert (propertize (format "  and %d more\n" (- (length now) 8))
                              'face 'vigil-ui-dim))))
      (let ((recent (reverse (last turns vigil-status-recent))))
        (vigil-ui-heading "Recent prompts"
                          (format "%d of %d, the last first" (length recent)
                                  (length turns))
                          "P")
        (vigil-ui-insert-table (vigil-status--turn-columns width)
                               (mapcar (lambda (turn) (vigil-status--turn-cells turn width))
                                       recent)
                               (mapcar #'vigil-status--turn-properties recent)
                               width))
      (when vigil-status--root
        (vigil-ui-heading "Commits since it began"
                          (format "%d, the last first" (length vigil-status--commits))
                          "b")
        (if vigil-status--commits
            (let ((commits (reverse (last vigil-status--commits 8))))
              (vigil-ui-insert-table
               vigil-status--commit-columns
               (mapcar #'vigil-status--commit-cells commits)
               (mapcar (lambda (commit)
                         (list 'vigil-status-commit (plist-get commit :hash)))
                       commits)
               width))
          (insert (propertize "  None.\n" 'face 'vigil-ui-dim)))))))

(defun vigil-status--insert-prompts ()
  "Insert the prompts view: each prompt, when, and what its agent did when.
What each led to is beside the list, with the detail; else under its line."
  (let* ((turns (reverse vigil-status--turns)) ; the last first
         (width (vigil-ui-width))
         (table (vigil-ui-table (vigil-status--turn-columns width)
                                (mapcar (lambda (turn) (vigil-status--turn-cells turn width))
                                        turns)
                                width))
         (lines (cdr table))
         (last (car turns)))
    (if (null turns)
        (insert "No prompt of this session has been reported.\n")
      (insert (car table) "\n"))
    (dolist (turn turns)
      (insert (apply #'propertize (concat (pop lines) "\n")
                     (vigil-status--turn-properties turn)))
      (unless vigil-status--detail
        (let ((body (point)))
          (vigil-status--insert-turn turn 4)
          (insert "\n")
          ;; Every turn but the last begins folded: the list is the prompts.
          (vigil-status--make-fold body (list 'prompts (plist-get turn :index))
                                   (not (eq turn last))))))
    (when turns
      (insert "\n" (vigil-status--timeline-legend) "\n"))))

(defun vigil-status--insert-answers ()
  "Insert the answers view: the replies alone.
Each beside the list, with the detail; else under its line."
  (let* ((turns (seq-filter (lambda (turn)
                              (and (plist-get turn :reply)
                                   (vigil-survey-step-text (plist-get turn :reply))))
                            ;; The last first.
                            (reverse vigil-status--turns)))
         (without (- (length vigil-status--turns) (length turns)))
         (width (vigil-ui-width))
         (table (vigil-ui-table
                 '((:title "#" :right t) (:title "When") (:title "In answer to" :flex t))
                 (mapcar (lambda (turn)
                           (list (propertize (number-to-string (plist-get turn :index))
                                             'face 'vigil-ui-strong)
                                 (vigil-status--clock
                                  (vigil-survey-step-time (plist-get turn :reply)))
                                 (or (vigil-survey-step-text (plist-get turn :prompt)) "")))
                         turns)
                 width))
         (lines (cdr table)))
    (when turns (insert (car table) "\n"))
    (dolist (turn turns)
      (let ((text (vigil-survey-step-text (plist-get turn :reply)))
            (index (plist-get turn :index)))
        (insert (propertize (concat (pop lines) "\n")
                            'vigil-status-turn index
                            'vigil-status-heading t
                            'vigil-status-text text))
        (unless vigil-status--detail
          (let ((body (point)))
            (vigil-ui-block (vigil-ui-markdown text) 4 'vigil-ui-dim
                            'vigil-status-turn index
                            'vigil-status-text text)
            (insert "\n")
            (vigil-status--make-fold body (list 'answers index) nil)))))
    (insert (if vigil-status--detail "\n" "")
            (propertize
             (concat (if (> without 0)
                         (format "%s no reply yet.  "
                                 (if (= without 1) "1 prompt has"
                                   (format "%d prompts have" without)))
                       "")
                     "Only the reply that ended each turn is kept, not what the agent said between calls.\n")
             'face 'vigil-ui-dim))))

(defun vigil-status--insert-commands ()
  "Insert the commands view: every command, when, and for how long.
Those that only looked are left out unless asked for."
  (let (rows (total 0) (looks 0))
    (dolist (turn vigil-status--turns)
      (dolist (call (plist-get turn :calls))
        (when (eq (vigil-survey-step-kind call) 'command)
          (if (and (eq (vigil-status--kind call) 'look) (not vigil-status--looks))
              (cl-incf looks)
            (when (eq (vigil-status--kind call) 'look) (cl-incf looks))
            (push (cons turn call) rows)
            (cl-incf total (or (vigil-status--took call) 0))))))
    ;; As they were pushed: the last first.
    (when vigil-status--by-duration
      (setq rows (sort rows (lambda (a b)
                              (> (or (vigil-status--took (cdr a)) 0)
                                 (or (vigil-status--took (cdr b)) 0))))))
    (let ((failed (cl-count 'failed rows
                            :key (lambda (row) (vigil-survey-step-status (cdr row)))))
          (unended (cl-count-if (lambda (row) (gethash (cdr row) vigil-status--unended))
                                rows)))
      (vigil-ui-sheet
       `(("Commands" . ,(format "%d, %s in all" (length rows)
                                (vigil-status--duration total)))
         ("For" . ,(and rows (vigil-status--tally (mapcar #'cdr rows))))
         ("Looks" . ,(and (> looks 0)
                          (concat (format (if vigil-status--looks
                                              "%d of them only looked"
                                            "%d more only looked, and are left out")
                                          looks)
                                  "   " (propertize "L" 'face 'vigil-ui-key)
                                  (propertize (if vigil-status--looks
                                                  " leaves them out" " lists them")
                                              'face 'vigil-ui-dim))))
         ("Failed" . ,(and (> failed 0) (propertize (number-to-string failed)
                                                    'face 'vigil-ui-bad)))
         ("No end" . ,(and (> unended 0)
                           (format "%d ended without saying how: they failed before vigil listened for that"
                                   unended)))
         ("Order" . ,(concat (if vigil-status--by-duration
                                 "the longest first" "the last first")
                             "   " (propertize "D" 'face 'vigil-ui-key)
                             (propertize " changes it" 'face 'vigil-ui-dim))))))
    (insert "\n")
    (vigil-ui-insert-table
     '((:title "#" :right t) (:title "When") (:title "Took" :right t) (:title "For")
       (:title "") (:title "Command" :flex t))
     (mapcar (pcase-lambda (`(,turn . ,call))
               (list (number-to-string (plist-get turn :index))
                     (vigil-status--clock (vigil-survey-step-time call))
                     (vigil-status--duration (vigil-status--took call))
                     (vigil-status--tags-said (vigil-status--tags call))
                     (vigil-status--state-said call)
                     (concat (if (vigil-survey-step-agent call) "↳ " "")
                             (vigil-status--call-said call))))
             rows)
     (mapcar (pcase-lambda (`(,turn . ,call))
               (list 'vigil-status-call (vigil-survey-step-id call)
                     'vigil-status-turn (plist-get turn :index)))
             rows))))

(defun vigil-status--insert-changes ()
  "Insert the changes view: the files changing now, and what is changing."
  (let* ((live vigil-status--live)
         (changes (plist-get live :changes))
         (width (vigil-ui-width)))
    (cond
     ((null vigil-status--root)
      (insert "This session works in no repository.\n"))
     ((null live)
      (insert "No snapshot is kept of this session, so there is nothing to count changes from.\n"
              (propertize "`vigil snapshots on', or `vigil setup', keeps them from the next prompt.\n"
                          'face 'vigil-ui-dim)))
     (t
      (vigil-ui-sheet
       `(("Counted" . ,(concat (vigil-status--live-since) "   "
                               (propertize "T" 'face 'vigil-ui-key)
                               (propertize (if (eq vigil-status--since 'session)
                                               " counts from the last prompt"
                                             " counts from the session's beginning")
                                           'face 'vigil-ui-dim)))
         ("Changed" . ,(vigil-review-changes-said changes))
         ("As of" . ,(concat (vigil-status--clock (plist-get live :time) t)
                             (propertize ", read again whenever the agent reports"
                                         'face 'vigil-ui-dim)))
         ("Following" . ,(concat (if vigil-status--follow
                                     "the last change, as it is made"
                                   "nothing: the buffer stays where you leave it")
                                 "   " (propertize "F" 'face 'vigil-ui-key)
                                 (propertize (if vigil-status--follow " stops" " follows")
                                             'face 'vigil-ui-dim)))))
      (when changes
        (insert "\n")
        (vigil-ui-insert-table
         (vigil-status--changes-columns)
         (mapcar #'vigil-status--change-cells changes)
         (mapcar (lambda (change)
                   (list 'vigil-status-file (plist-get change :file)
                         ;; With the detail, a file's line here is the file's.
                         'vigil-status-heading vigil-status--detail))
                 changes)
         width))
      (when (and changes (not vigil-status--detail)) (insert "\n"))
      (dolist (change (and (not vigil-status--detail)
                           (seq-take changes vigil-status-live-files)))
        (let* ((file (plist-get change :file))
               (mark (vigil-review--mark (plist-get change :status)))
               (time (vigil-status--file-time file)))
          ;; No line between one file and the next: folded, they are a list.
          (insert (propertize
                   (concat "  " (propertize (car mark) 'face (cdr mark)) " "
                           (propertize file 'face 'vigil-ui-heading)
                           "  " (vigil-ui-lines-changed (plist-get change :added)
                                                        (plist-get change :removed))
                           (if time
                               (propertize (concat "  " (vigil-status--ago time))
                                           'face 'vigil-ui-dim)
                             "")
                           "\n")
                   'vigil-status-file file 'vigil-status-heading t))
          (let ((body (point)))
            (vigil-status--insert-diff file (gethash file (plist-get live :diffs)))
            ;; A diff that shows is set off from the file after it.
            (insert "\n")
            ;; The one last written shows; the rest wait to be opened.
            (vigil-status--make-fold body (list 'changes file)
                                     (not (equal file (plist-get live :latest)))))))
      (when (and (not vigil-status--detail)
                 (> (length changes) vigil-status-live-files))
        (insert "\n" (propertize (format "%d more files changed, and are not laid out.\n"
                                         (- (length changes) vigil-status-live-files))
                                 'face 'vigil-ui-dim)))))))

(defun vigil-status--insert-build ()
  "Insert the build view: prompts and commits by when, the last first."
  (let* ((events (sort (append
                        (mapcar (lambda (turn) (cons (plist-get turn :start) turn))
                                vigil-status--turns)
                        (mapcar (lambda (commit) (cons (plist-get commit :time) commit))
                                vigil-status--commits))
                       ;; The last first.
                       (lambda (a b) (> (car a) (car b)))))
         (events (mapcar #'cdr events)))
    (cond
     ((null vigil-status--root)
      (insert (propertize "This session works in no repository: there are no commits to set its prompts against.\n\n"
                          'face 'vigil-ui-dim)))
     ((null vigil-status--commits)
      (insert (propertize "No commit has been made since it began.\n\n"
                          'face 'vigil-ui-dim))))
    (vigil-ui-insert-table
     '((:title "When") (:title "#" :right t) (:title "Prompt, or commit" :flex t)
       (:title "Files" :right t) (:title "Lines") (:title "At") (:title "Changelog"))
     (mapcar
      (lambda (event)
        (if (plist-get event :hash)
            (pcase-let ((`(,when ,hash ,subject ,refs ,versions)
                         (vigil-status--commit-cells event)))
              (list when (propertize "◆" 'face 'vigil-ui-good)
                    (concat hash " " (propertize subject 'face 'vigil-ui-strong))
                    "" "" refs versions))
          (pcase-let ((`(,files ,lines) (vigil-status--turn-after event)))
            (list (vigil-status--clock (plist-get event :start))
                  (propertize (number-to-string (plist-get event :index))
                              'face 'vigil-ui-strong)
                  (or (vigil-survey-step-text (plist-get event :prompt)) "")
                  files lines "" ""))))
      events)
     (mapcar (lambda (event)
               (if (plist-get event :hash)
                   (list 'vigil-status-commit (plist-get event :hash))
                 (vigil-status--turn-properties event)))
             events))
    (when (and vigil-status--root
               (file-exists-p (expand-file-name vigil-status-changelog vigil-status--root)))
      (insert "\n"
              (propertize
               (format "◆ is a commit; Changelog names the versions it added to %s.\n"
                       vigil-status-changelog)
               'face 'vigil-ui-dim)))))

;;;; Which there are, and the lines above them

(defconst vigil-status-views
  '((status "s" "Status" vigil-status--insert-status)
    (prompts "P" "Prompts" vigil-status--insert-prompts)
    (answers "a" "Answers" vigil-status--insert-answers)
    (commands "c" "Commands" vigil-status--insert-commands)
    (changes "l" "Changes" vigil-status--insert-changes)
    (build "b" "Build" vigil-status--insert-build))
  "The views of a session: each (VIEW KEY NAME DRAW).
KEY shows it, NAME is what its tab says, and DRAW inserts it.")

(defun vigil-status--set-lines ()
  "Say what this buffer is of in its header line, and its views in its tab line."
  (setq header-line-format
        (vigil-ui-header
         (propertize vigil-status--session 'face 'vigil-ui-strong)
         (propertize (if vigil-status--root
                         (abbreviate-file-name (directory-file-name vigil-status--root))
                       "in no repository")
                     'face 'vigil-ui-dim)
         (and vigil-status--branch (propertize vigil-status--branch 'face 'vigil-ui-dim))
         (and (not (vigil-status--agent vigil-status--session))
              (propertize "not open in this Emacs" 'face 'vigil-ui-dim)))
        tab-line-format
        (vigil-ui-tabs vigil-status-views vigil-status--view
                       (concat (propertize "?" 'face 'vigil-ui-key) " menu"))))

(provide 'vigil-status-views)
;;; vigil-status-views.el ends here
