;;; vigil-transcript.el --- An agent's tool calls, where its terminal shows them -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; The half of vigil that reads the agent's terminal: a cooked buffer, whose
;; transcript is ordinary text at positions that stay put.  With it, an
;; agent's buffer:
;;
;; - has a wedge in the fringe on the line of the conversation where each call
;;   shows (cooked-annotate.el).  Click it, or RET on the line, to inspect; `o'
;;   on a call being inspected, or in the context buffer, goes to its line.
;;   A call put on show, and each one `]' and `[' step to, is scrolled to and
;;   lit up in the conversation behind the pop-up, where the pop-up leaves it
;;   in sight; `q' puts the conversation back as it was.
;; - stops at each prompt for \\[cooked-previous-command] and \\[cooked-next-command].
;; - opens the file names in the conversation in a pop-up, and copies the
;;   agent's prose as paragraphs.
;; - can show only the prompts and the replies (`vigil-focus-mode').
;;
;; The line a call is marked on is found by looking for what the call itself
;; says -- the command, the file's name -- in the output since the last marked
;; call, newest first, and never before the prompt the call answered -- which
;; the UserPromptSubmit report says, so that a file named in the prompt is not
;; taken for the call that edits it.  Nothing is read out of how the agent
;; draws its screen: no glyph, no layout.  Calls whose words cannot be found
;; -- the agent may show only a summary of them -- are marked together on the
;; line above the next call that was found; see `vigil--group-unmarked'.
;;
;; Loaded by `vigil-setup'.  vigil.el works without it, as vigil-archive.el
;; shows: what is here hangs on two hooks, `vigil-mode-hook' and
;; `vigil-changed-hook', and three keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil)
(require 'pulse)

(declare-function cooked-annotate "cooked-annotate")
(declare-function cooked-annotation-data "cooked-annotate")
(declare-function cooked-annotation-beg "cooked-annotate")
(declare-function cooked-annotation-delete "cooked-annotate")
(defvar cooked-prompt-positions-functions)
(defvar cooked-file-open-function)
(defvar cooked-copy-unwrap)

;;;; Where a call shows in the conversation

(defcustom vigil-anchor-tries 10
  "How many times, half a second apart, a finished call's line is looked for.
The agent may draw the line a little after the call has finished."
  :type 'natnum
  :group 'vigil)

(defun vigil--needles (call)
  "What CALL's line in the conversation would say, most specific first."
  (let* ((input (vigil-call-input call))
         (file (alist-get 'file_path input))
         (path (or file (alist-get 'notebook_path input) (alist-get 'path input))))
    (delq nil
          (delete-dups
           (list (vigil--clip (alist-get 'command input) 30)
                 (and (stringp path) (vigil--relative path (vigil-call-cwd call)))
                 (and (stringp path) (file-name-nondirectory path))
                 (vigil--clip (alist-get 'pattern input) 30)
                 (vigil--clip (alist-get 'url input) 40)
                 (vigil--clip (alist-get 'description input) 30))))))

(defun vigil--help (call)
  "One line saying what CALL was."
  (format "%s: %s" (vigil-call-name call) (vigil--summary call)))

(defun vigil--find (call ceiling)
  "The line start below CEILING where CALL shows, back no further than the floor.
Of the lines that say what CALL said, the one where it is said furthest to
the left -- a line about a call begins with it, while prose mentioning the same
file or command has it somewhere along -- and of those, the last."
  (let* ((ceiling (min ceiling (or (vigil--reply-after call) ceiling)))
         (floor (min ceiling (or (vigil--prompt-before call) (point-min))))
         (case-fold-search nil))
    (save-excursion
      (cl-some
       (lambda (needle)
         (let (best best-column)
           (goto-char ceiling)
           (while (search-backward needle floor t)
             (let ((column (- (point) (line-beginning-position))))
               (when (or (null best) (< column best-column))
                 (setq best (line-beginning-position) best-column column))))
           best))
       (vigil--needles call)))))

(defcustom vigil-anchor-delay 1.0
  "Seconds a finished call waits before its line is looked for.
Reports are written by hooks that run alongside each other, so the report of
the prompt a call answered can arrive just after the call's own."
  :type 'number
  :group 'vigil)

;; Landmarks: the prompts and the replies that ended turns, whose text the
;; hooks report.  A call shows between the echo of the prompt it answered and
;; the reply that ended its turn, so those bound where it is looked for.  Each
;; is found at its last occurrence, newest first: the agent may draw the same
;; conversation more than once, and the last drawing is the one that stays.

(defvar vigil--landmarks nil
  "During one pass: (PROMPT-ENDS . REPLY-STARTS), alists to positions.")

(defun vigil--replies ()
  "The replies that ended turns, oldest first."
  (cl-remove-if-not (lambda (note) (eq (plist-get note :kind) 'reply))
                    vigil--notes))

(defun vigil--prompt-before (call)
  "Where the echo of the prompt CALL answered ends, if it was found.
A prompt that is never shown -- the agent gives itself some -- is passed over."
  (let (end)
    (dolist (prompt vigil--prompts)
      (when-let* ((position (cdr (assq prompt (car vigil--landmarks))))
                  ((<= (or (vigil--prompt-time prompt) 0)
                       (or (vigil-call-start call) 0))))
        (setq end position)))
    end))

(defun vigil--reply-after (call)
  "Where the reply that ended CALL's turn begins, if it was found."
  (cl-some (lambda (note)
             (and (>= (plist-get note :time) (or (vigil-call-start call) 0))
                  (cdr (assq note (cdr vigil--landmarks)))))
           (vigil--replies)))

(defun vigil--prompt-pieces (text)
  "Pieces of the end of TEXT to find its echo by, longest first.
Short, because a long prompt is wrapped at the window's width and a piece
that crosses a wrap is not found."
  (let* ((text (string-trim text))
         (line (car (last (split-string text "\n" t)))))
    (when line
      (delete-dups
       (append (cl-loop for n in '(24 16 10)
                        when (>= (length line) n)
                        collect (string-trim (substring line (- (length line) n))))
               (and (< (length line) 10) (> (length line) 0) (list line)))))))

(defun vigil--reply-piece (text)
  "A regexp for a piece of TEXT, a reply in markdown, as (REGEXP . LINES).
The start of its first line long enough to be told apart, without the
characters markdown takes away when it is drawn; LINES is how many lines
with text come before that line in the reply.  Nil for an empty reply."
  (let* ((all (split-string (or text "") "\n" t "[[:space:]]+"))
         (lines all)
         (before 0)
         (found nil))
    (while (and lines (not found))
      (let ((plain (string-trim (replace-regexp-in-string "[*`_#>]" "" (pop lines)))))
        (if (>= (length plain) 12)
            (setq found (cons (regexp-quote (substring plain 0 (min 20 (length plain))))
                              before))
          (setq before (1+ before)))))
    ;; A reply too short for that is looked for whole: the search stays
    ;; below the next landmark, so a short piece is still in its place.
    (or found
        (let ((plain (string-trim (replace-regexp-in-string "[*`_#>]" "" (or (car all) "")))))
          (and (>= (length plain) 2)
               (cons (concat "\\_<" (regexp-quote plain) "\\_>") 0))))))

(defun vigil--find-landmarks ()
  "Find the prompts and replies in the conversation.
For `vigil--landmarks'."
  (let ((items (sort (append (mapcar (lambda (prompt)
                                       (cons (or (vigil--prompt-time prompt) 0) prompt))
                                     vigil--prompts)
                             (mapcar (lambda (note) (cons (plist-get note :time) note))
                                     (vigil--replies)))
                     (lambda (a b) (> (car a) (car b)))))
        (ceiling (point-max))
        (case-fold-search nil)
        (prompts nil)
        (replies nil))
    (save-excursion
      (dolist (item items)
        (let ((thing (cdr item)))
          (if (vigil--prompt-p thing)
              (when-let* ((at (cl-some (lambda (piece)
                                         (goto-char ceiling)
                                         (search-backward piece nil t))
                                       (vigil--prompt-pieces
                                        (vigil--prompt-text thing)))))
                (goto-char at)
                (push (cons thing (line-end-position)) prompts)
                (setq ceiling (line-beginning-position)))
            (when-let* ((piece (vigil--reply-piece (plist-get thing :text)))
                        (at (progn (goto-char ceiling)
                                   (re-search-backward (car piece) nil t))))
              (goto-char at)
              (beginning-of-line)
              ;; Back to the reply's first line, past the short ones before
              ;; the line that was found.
              (let ((n (cdr piece)))
                (while (and (> n 0) (zerop (forward-line -1)))
                  (unless (looking-at-p "[[:space:]]*$")
                    (setq n (1- n)))))
              (push (cons thing (point)) replies)
              (setq ceiling (point)))))))
    (cons prompts replies)))

(defun vigil--unmarked (annotation)
  "Put the calls ANNOTATION marked back among those still to be found.
For `cooked-annotate': the agent drew over the line, as it does when it folds
calls it showed one by one into a summary of them."
  (let ((buffer (current-buffer)))
    (dolist (call (let ((data (cooked-annotation-data annotation)))
                    (if (vigil--group-p data) data (list data))))
      (when (eq (vigil-call-annotation call) annotation)
        (setf (vigil-call-annotation call) nil
              (vigil-call-tries call) 0)))
    (run-with-timer 0 nil (lambda ()
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (vigil--anchor-pending)))))))

(defun vigil--group-line (after before)
  "The start of the last line with text on it after AFTER and before BEFORE."
  (save-excursion
    (goto-char before)
    (forward-line -1)
    (while (and (> (point) after) (looking-at-p "[[:space:]]*$"))
      (forward-line -1))
    (and (> (point) after) (< (point) before) (point))))

(defun vigil--group-unmarked ()
  "Mark each run of finished calls whose words were nowhere, on one line.
An agent may show calls only as a summary (\"Read 2 files\"), in its own
words, which are not read here.  But it shows them in order: a run of such
calls is shown after the line of the marked call before it and before the
line of the marked call after it -- or before the reply that ended their
turn -- so the run is marked on the last line with text in between.  A run
with neither after it yet waits.  Groups are made afresh each time: there
are few of them, and a call that comes back unmarked rejoins its run."
  (let ((run nil)                       ; oldest first
        (after (point-min))
        (old nil))
    (dolist (call vigil--order)
      (let ((annotation (vigil-call-annotation call)))
        (when (and annotation (vigil--group-p (cooked-annotation-data annotation)))
          (cl-pushnew annotation old)
          (setf (vigil-call-annotation call) nil))))
    (mapc #'cooked-annotation-delete old)
    (cl-flet ((flush (before)
                (when (and run before)
                  (let* ((floor (max after (or (vigil--prompt-before (car run))
                                               (point-min))))
                         (line (vigil--group-line floor before)))
                    (when line
                      (let ((group (cooked-annotate
                                    line line :data run :action #'vigil--activate
                                    :removed #'vigil--unmarked
                                    :help (mapconcat #'vigil--help run "\n"))))
                        (dolist (inner run)
                          (setf (vigil-call-annotation inner) group))))))
                (setq run nil)))
      (dolist (call vigil--order)
        (unless (or (vigil-call-agent call) (null (vigil-call-response call)))
          ;; A run does not cross into the next turn.
          (when (and run (not (eql (vigil--prompt-before call)
                                   (vigil--prompt-before (car run)))))
            (flush (vigil--reply-after (car run))))
          (let ((annotation (vigil-call-annotation call)))
            (cond
             (annotation
              (let ((at (marker-position (cooked-annotation-beg annotation))))
                (when run
                  (flush (min at (or (vigil--reply-after (car run)) at))))
                (setq after (save-excursion (goto-char at) (line-end-position)))))
             ((>= (vigil-call-tries call) vigil-anchor-tries)
              (setq run (append run (list call))))
             (t (setq run nil))))))
      (when run (flush (vigil--reply-after (car run)))))))

(defun vigil--check-mark (call)
  "Unmark CALL if its mark is not between its prompt and its turn's reply.
A mark made before those could be found in the conversation -- the agent
draws them a moment after they are sent, and may draw it all again -- may
have been put in the wrong place.  Checked on every pass, so marks settle where
they belong whatever order things were drawn in."
  (when-let* ((annotation (vigil-call-annotation call))
              ((not (vigil--group-p (cooked-annotation-data annotation))))
              (at (marker-position (cooked-annotation-beg annotation)))
              ((or (< at (or (vigil--prompt-before call) at))
                   (>= at (or (vigil--reply-after call) (1+ at))))))
    (cooked-annotation-delete annotation)
    (setf (vigil-call-annotation call) nil
          (vigil-call-tries call) 0)))

(defun vigil--anchor-pending ()
  "Mark the line of every finished call not marked yet, newest first.
Newest first, each below the line found for the call after it, so that a
command run twice is found twice in the right places; and back no further
than the newest call already marked."
  (when (and (derived-mode-p 'cooked-mode) (require 'cooked-annotate nil t))
    (let ((vigil--landmarks (vigil--find-landmarks))
          (ceiling (point-max))
          (waiting nil))
      ;; A newer call still waiting to be found holds the older ones back: its
      ;; line, once drawn, would otherwise be open for one of them to take.
      (catch 'wait
        (dolist (call (reverse vigil--order))
          (vigil--check-mark call)
          (cond
           ((vigil-call-annotation call)
            ;; Older calls than a marked one are above it.
            (setq ceiling (min ceiling (marker-position
                                        (cooked-annotation-beg
                                         (vigil-call-annotation call))))))
           ;; A subagent's calls are not in the conversation shown here.
           ((vigil-call-agent call))
           ;; Still running: its line may already be drawn.  Its result's
           ;; report is what will bring this pass round again.
           ((null (vigil-call-response call))
            (throw 'wait nil))
           ((>= (vigil-call-tries call) vigil-anchor-tries))
           ((< (- (float-time) (or (vigil-call-end call) 0)) vigil-anchor-delay)
            (setq waiting t)
            (throw 'wait nil))
           (t
            (cl-incf (vigil-call-tries call))
            (if-let* ((pos (vigil--find call ceiling)))
                (progn
                  (setf (vigil-call-annotation call)
                        (cooked-annotate pos pos
                                         :help (vigil--help call)
                                         :data call
                                         :action #'vigil--activate
                                         :removed #'vigil--unmarked))
                  (setq ceiling pos))
              (when (< (vigil-call-tries call) vigil-anchor-tries)
                (setq waiting t)
                (throw 'wait nil)))))))
      (unless waiting (vigil--group-unmarked))
      (when waiting
        (let ((buffer (current-buffer)))
          (run-with-timer 0.5 nil
                          (lambda ()
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (vigil--anchor-pending))))))))))

(defun vigil--activate (annotation)
  "Inspect the call ANNOTATION marks.  The annotation's action."
  (vigil-inspect (cooked-annotation-data annotation) (current-buffer)))

(defcustom vigil-follow-calls t
  "Whether a call being inspected is shown in the conversation behind the pop-up.
Its line scrolled to where the pop-up leaves it in sight, and lit up for a
moment, as each call is put on show and as \\`]' and \\`[' step through them.
\\`q' puts the conversation back where it was."
  :type 'boolean
  :group 'vigil)

(defface vigil-follow-highlight
  '((t :inherit highlight :extend t))
  "The line of a call being inspected, lit up for a moment in the conversation."
  :group 'vigil)

(defvar vigil--follow-saved nil
  "Where the conversation was before calls were followed in it, to go back to.
\(WINDOW START POINT AT-END), AT-END whether it was following its output.")

(defun vigil--item-annotation (item agent)
  "The mark in AGENT's conversation of ITEM: a call, a group or a subagent.
A subagent's own calls are not in the conversation: theirs is the mark of
the call that launched it.  Nil if there is none."
  (let* ((call (cond ((vigil-subagent-p item) (vigil-subagent-call item))
                     ((vigil--group-p item) (car item))
                     (t item)))
         (subagents (buffer-local-value 'vigil--subagents agent))
         (call (if (and (vigil-call-p call) (vigil-call-agent call) subagents)
                   (let ((subagent (gethash (vigil-call-agent call) subagents)))
                     (and subagent (vigil-subagent-call subagent)))
                 call)))
    (and (vigil-call-p call) (vigil-call-annotation call))))

(defun vigil--uncovered-row (window)
  "The row of WINDOW to show a line on so that the pop-up does not cover it.
The middle of the larger part of WINDOW above or below the pop-up; nil, for
its middle, where the pop-up is not over it or leaves no room."
  (let ((popup (bound-and-true-p cooked-popup--frame)))
    (when (and (frame-live-p popup)
               (eq (frame-parent popup) (window-frame window)))
      (pcase-let* ((`(,left ,top ,right ,bottom) (window-inside-pixel-edges window))
                   (`(,x . ,y) (frame-position popup))
                   (width (frame-pixel-width popup))
                   (height (frame-pixel-height popup))
                   (line (frame-char-height (window-frame window)))
                   (above (- y top))
                   (below (- bottom (+ y height))))
        (when (and (< x right) (> (+ x width) left)     ; over it at all
                   (< y bottom) (> (+ y height) top)
                   (or (> above line) (> below line)))
          (if (>= below above)
              (/ (+ (- (+ y height) top) (/ below 2)) line)
            (/ (max 0 (/ above 2)) line)))))))

(defun vigil--light-up (agent position)
  "Light up the line at POSITION of AGENT's conversation, for a moment."
  (with-current-buffer agent
    (let ((pulse-delay 0.05)
          (pulse-iterations 12))
      (pulse-momentary-highlight-one-line position 'vigil-follow-highlight))))

(defun vigil--follow (item agent)
  "Show ITEM, being inspected, in AGENT's conversation behind the pop-up.
On `vigil-inspect-functions'.  See `vigil-follow-calls'."
  (when-let* ((vigil-follow-calls)
              ((buffer-live-p agent))
              (window (get-buffer-window agent 'visible))
              (annotation (vigil--item-annotation item agent)))
    (with-demoted-errors "vigil: %S"
      (let ((position (marker-position (cooked-annotation-beg annotation))))
        ;; Where the conversation was is kept when the pop-up is first put
        ;; up; not as what it shows changes.  See `vigil--continuing'.
        (unless (and vigil--continuing
                     vigil--follow-saved
                     (eq (car vigil--follow-saved) window))
          (setq vigil--follow-saved
                (list window (window-start window) (window-point window)
                      (>= (window-point window)
                          (with-current-buffer agent (1- (point-max)))))))
        (let ((row (vigil--uncovered-row window)))
          (with-selected-window window
            (goto-char position)
            (recenter row)))
        (vigil--light-up agent position)))))

(defun vigil-popup-quit ()
  "Close the pop-up, and put the conversation back where it was.
Before calls were followed in it: see `vigil-follow-calls'."
  (interactive)
  (let ((saved vigil--follow-saved))
    (setq vigil--follow-saved nil)
    (cooked-popup-quit)
    (pcase-let ((`(,window ,start ,point ,at-end) saved))
      (when (window-live-p window)
        (if at-end
            (set-window-point window (with-current-buffer (window-buffer window)
                                       (point-max)))
          (set-window-start window start t)
          (set-window-point window point))))))

(defun vigil-goto-call (&optional call agent)
  "Go to the line of the conversation where CALL shows, in AGENT's buffer.
By default, the call being inspected."
  (interactive)
  (let* ((call (or call vigil--popup-call))
         (agent (or agent vigil--popup-agent))
         (annotation (and call (buffer-live-p agent)
                          (vigil--item-annotation call agent))))
    (unless annotation
      (user-error "This call is not marked in the conversation"))
    (setq vigil--follow-saved nil)
    (cooked-popup-quit)
    (pop-to-buffer agent)
    (goto-char (cooked-annotation-beg annotation))
    (recenter)
    (vigil--light-up agent (point))))

(defun vigil-context-goto ()
  "Go to the line of the conversation where the call at point shows."
  (interactive)
  (vigil-goto-call (or (vigil--context-item) (user-error "Not a call"))
                           vigil--context-agent))

;;;; Prompts

(defun vigil--prompt-starts ()
  "Where each prompt's echo begins in this agent's conversation.
For `cooked-prompt-positions-functions', so that \\[cooked-previous-command]
and \\[cooked-next-command] move between them.  Found as the prompts are
for marking calls: by their own words, last drawing first."
  (let ((vigil--landmarks (vigil--find-landmarks))
        (case-fold-search nil)
        (starts nil))
    (dolist (prompt vigil--prompts)
      (when-let* ((end (cdr (assq prompt (car vigil--landmarks)))))
        (let* ((text (string-trim (vigil--prompt-text prompt)))
               (first (car (split-string text "\n" t)))
               (piece (and first (substring first 0 (min 16 (length first))))))
          ;; Back from its end to its first line, or that line if not found.
          (push (save-excursion
                  (goto-char end)
                  (when piece
                    (search-backward piece (max (point-min)
                                                (- end (* 2 (length text)) 200))
                                     t))
                  (line-beginning-position))
                starts))))
    starts))

;;;; Focus: the conversation without the work

(defvar-local vigil--focus nil
  "Whether this agent buffer shows only prompts and replies.")

(defvar-local vigil--focus-overlays nil
  "The overlays hiding each turn's work while focused.")

(defvar-local vigil--focus-timer nil
  "The timer that keeps the hidden turns current while focused.")

(defvar-local vigil--focus-tick nil
  "What the hidden turns were last placed for: where the scrollback ended, and
how many prompts and notes there were.  Output on the live screen -- an
agent's spinner -- changes neither, so it costs nothing.")

(defvar-local vigil--focus-shown nil
  "Prompts whose turn was opened by hand while focused.")

(declare-function cooked--screen-start-position "cooked")

(defun vigil--turns ()
  "Each turn's work, as (PROMPT FROM TO): what lies between its prompt's echo
and its reply.  A finished turn is not drawn again -- the agent redraws only
what is below it -- so it is hidden wherever it is.  A turn with no reply yet
is still being drawn, and only what of it has scrolled off the screen is."
  (let* ((vigil--landmarks (vigil--find-landmarks))
         (prompts (sort (copy-sequence (car vigil--landmarks))
                        (lambda (a b) (< (cdr a) (cdr b)))))
         (replies (sort (mapcar #'cdr (cdr vigil--landmarks)) #'<))
         (limit (or (ignore-errors (cooked--screen-start-position)) (point-max)))
         (turns nil))
    (while prompts
      (let* ((prompt (pop prompts))
             (from (cdr prompt))
             (next (and prompts (save-excursion (goto-char (cdar prompts))
                                                (line-beginning-position))))
             (reply (cl-find-if (lambda (r) (and (> r from) (or (null next) (< r next))))
                                replies))
             ;; Up to the newline before the reply, or the next prompt's echo.
             (to (if reply (1- reply) (min limit (1- (or next limit))))))
        (when (> to (1+ from))
          (push (list (car prompt) from to) turns))))
    (nreverse turns)))

(defun vigil--turn-calls (prompt)
  "How many of this agent's own calls answered PROMPT."
  (let ((next (cadr (memq prompt vigil--prompts))))
    (cl-count-if (lambda (call)
                   (and (not (vigil-call-agent call))
                        (>= (or (vigil-call-start call) 0)
                            (or (vigil--prompt-time prompt) 0))
                        (or (null next)
                            (< (or (vigil-call-start call) 0)
                               (or (vigil--prompt-time next) 0)))))
                 vigil--order)))

(defun vigil--focus-clear ()
  "Show every turn's work again."
  (mapc #'delete-overlay vigil--focus-overlays)
  (setq vigil--focus-overlays nil))

(defun vigil--focus-open (overlay)
  "Show the turn OVERLAY hides, and keep it shown.
Also what isearch calls to open it for a match inside."
  (when-let* ((prompt (overlay-get overlay 'vigil-prompt)))
    (push prompt vigil--focus-shown))
  (delete-overlay overlay)
  (setq vigil--focus-overlays (delq overlay vigil--focus-overlays)))

(defun vigil--focus-place (&optional force)
  "Hide each turn's work, if the conversation changed since the last time.
FORCE places them whether or not it did."
  (let ((tick (list (ignore-errors (cooked--screen-start-position))
                    (length vigil--prompts)
                    (length vigil--notes)
                    (length vigil--order)
                    (window-width))))
    (when (and vigil--focus
               (or force (not (equal vigil--focus-tick tick))))
      (setq vigil--focus-tick tick)
      (vigil--focus-clear)
      (dolist (turn (vigil--turns))
        (pcase-let ((`(,prompt ,from ,to) turn))
          (unless (memq prompt vigil--focus-shown)
            (let* ((calls (vigil--turn-calls prompt))
                   (overlay (make-overlay from to nil t nil))
                   (label (format "  ⋯ %s hidden  (%s to show)"
                                  (if (> calls 0)
                                      (format "%d tool call%s" calls
                                              (if (= calls 1) "" "s"))
                                    "work")
                                  (substitute-command-keys
                                   "\\[vigil-focus-mode]"))))
              (overlay-put overlay 'invisible 'vigil-focus)
              (overlay-put overlay 'evaporate t)
              (overlay-put overlay 'vigil-prompt prompt)
              (overlay-put overlay 'isearch-open-invisible
                           #'vigil--focus-open)
              ;; The placeholder rides on the hidden text's first character, a
              ;; newline, which the invisible spec would otherwise take with it.
              (overlay-put overlay 'before-string
                           (propertize (concat "\n" label) 'face 'shadow))
              (push overlay vigil--focus-overlays))))))))

(define-minor-mode vigil-focus-mode
  "Show only the prompts and the agent's replies, hiding the work between.
Reads, diffs, command output, subagents: everything between a prompt's echo
and its reply.  A turn still under way is hidden only as far as it has
scrolled off the screen, which is still being drawn; nothing about the
terminal changes -- its size, its rows, its marks.  Isearch opens a hidden
turn to show a match inside it.  \\[vigil-focus-mode] again shows
everything."
  :lighter " focus"
  (unless (and (derived-mode-p 'cooked-mode) vigil-mode)
    (setq vigil-focus-mode nil)
    (user-error "Focus is for agent buffers"))
  (setq vigil--focus vigil-focus-mode)
  (when vigil--focus-timer (cancel-timer vigil--focus-timer))
  (setq vigil--focus-timer nil vigil--focus-shown nil)
  (vigil--focus-clear)
  (if (not vigil-focus-mode)
      (remove-from-invisibility-spec 'vigil-focus)
    (add-to-invisibility-spec 'vigil-focus)
    (vigil--focus-place t)
    ;; A plain timer, not an idle one: an idle timer fires once per pause in
    ;; typing, and the conversation grows while nobody types.  Cheap when
    ;; nothing it watches changed; see `vigil--focus-tick'.
    (let ((buffer (current-buffer)) timer)
      (setq timer (run-with-timer
                   1 1 (lambda ()
                         (if (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (vigil--focus-place))
                           (cancel-timer timer))))
            vigil--focus-timer timer))))

(defun vigil-focus ()
  "Toggle `vigil-focus-mode' here, or in the current agent's buffer."
  (interactive)
  (let ((buffer (if (buffer-local-value 'vigil-mode (current-buffer))
                    (current-buffer)
                  (vigil--target-agent))))
    (with-current-buffer buffer
      (vigil-focus-mode 'toggle))))

;;;; Joining vigil.el

(define-key vigil-popup-mode-map (kbd "o") #'vigil-goto-call)
(define-key vigil-popup-mode-map [remap cooked-popup-quit] #'vigil-popup-quit)
(define-key vigil-context-mode-map (kbd "o") #'vigil-context-goto)
(define-key vigil-mode-map (kbd "C-c C-f") #'vigil-focus-mode)

(defun vigil-transcript--setup ()
  "Set an agent's terminal up for its calls, or put it back as it was.
On `vigil-mode-hook'."
  (if vigil-mode
      (when (derived-mode-p 'cooked-mode)
        (add-hook 'cooked-prompt-positions-functions #'vigil--prompt-starts nil t)
        ;; File names in the conversation open in a pop-up, not over it.
        (setq-local cooked-file-open-function #'vigil--open-file)
        ;; The agent wraps its own prose: a copy comes out as paragraphs.
        (setq-local cooked-copy-unwrap t))
    (remove-hook 'cooked-prompt-positions-functions #'vigil--prompt-starts t)
    (kill-local-variable 'cooked-file-open-function)
    (kill-local-variable 'cooked-copy-unwrap)
    (when vigil-focus-mode (vigil-focus-mode -1))))

(add-hook 'vigil-mode-hook #'vigil-transcript--setup)
(add-hook 'vigil-changed-hook #'vigil--anchor-pending)
(add-hook 'vigil-inspect-functions #'vigil--follow)

(provide 'vigil-transcript)
;;; vigil-transcript.el ends here
