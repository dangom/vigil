;;; vigil-status.el --- One place to begin from: a session, and its views -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil': one buffer for a session, and one key to each way of
;; looking at it, as `magit-status' is for a repository.
;;
;; The buffer has five views of the session, and a key for each:
;;
;;   s  Status     what it is, how much it has done, what it built, its
;;                 last prompts and the commits made since it began
;;   P  Prompts    each prompt in order, and under it what it led to: its
;;                 calls, one a line, and the reply
;;   a  Answers    the replies alone, to read and to copy
;;   c  Commands   every command it ran, when, and for how long
;;   b  Build      its prompts and the repository's commits in the order
;;                 they happened, each commit with what it added to the
;;                 changelog
;;
;; `?' shows these and the rest of vigil in a menu: the session's review,
;; context, turns, graph and focus, and what is not of one session, the
;; running commands, the repository's changes and the archive.
;;
;; It reads a session's reports by its name (vigil-survey.el), so it needs
;; no agent's buffer: a session that is not open in this Emacs is shown as
;; well.  What acts on the conversation itself (context, a turn's list,
;; focus, a call inspected) needs that buffer, and says so.
;;
;; Needs vigil-survey.el and vigil-review.el and what they need; vigil.el
;; and cooked only for what acts on an agent's buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'vigil-base)
(require 'vigil-git)
(require 'vigil-survey)
(require 'vigil-review)

(declare-function vigil-context "vigil")
(declare-function vigil-prompts "vigil")
(declare-function vigil-turn "vigil-turn")
(declare-function vigil-focus-mode "vigil-transcript")
(declare-function vigil-graph "vigil-graph")
(declare-function vigil-running "vigil-running")
(declare-function vigil-archive "vigil-archive")
(declare-function vigil-embark-inspect "vigil-embark")
(declare-function vigil-embark-goto "vigil-embark")
(declare-function magit-show-commit "magit-diff")
(defvar cooked-host-name)

(defgroup vigil-status nil
  "One place to begin from: a session, and its views."
  :group 'tools)

(defcustom vigil-status-changelog "CHANGELOG.md"
  "The file a repository's changelog is in, from its top."
  :type 'string)

(defcustom vigil-status-recent 3
  "How many of a session's last prompts its status names."
  :type 'integer)

(defface vigil-status-view '((t :inherit (bold highlight)))
  "The view that is showing, among the views named at the top.")

(defface vigil-status-heading '((t :inherit bold))
  "A line something is under.")

(defface vigil-status-failed '((t :inherit error))
  "A call that failed.")

(defface vigil-status-commit '((t :inherit font-lock-constant-face))
  "A commit's hash.")

(defconst vigil-status-views
  '((status "s" "Status") (prompts "P" "Prompts") (answers "a" "Answers")
    (commands "c" "Commands") (build "b" "Build"))
  "The views of a session: each (VIEW KEY NAME).")

(defvar-local vigil-status--session nil "The session this buffer is of, by its name.")
(defvar-local vigil-status--root nil "The session's repository, or nil if it has none.")
(defvar-local vigil-status--view 'status "Which view is showing.")
(defvar-local vigil-status--by-duration nil "Whether commands are listed longest first.")
(defvar-local vigil-status--turns nil "The session's turns, as last read.")
(defvar-local vigil-status--built nil "What `vigil-status--read-built' last found.")
(defvar-local vigil-status--commits nil "The commits made since the session began.")

;;;; What a session did

(defun vigil-status--call-p (step)
  "Whether STEP is a call: neither a prompt, nor a reply, nor a session's start."
  (not (memq (vigil-survey-step-kind step) '(prompt reply session))))

(defvar vigil-status--unended (make-hash-table :test #'eq :weakness 'key)
  "The calls that began, never reported an end, and are not still going.")

(defun vigil-status--mark-unended (steps)
  "Note which calls of STEPS, a session's in order, ended without saying so.
A call no end was reported of is still going only while its agent has done
nothing since: once it has gone on, the call ended, however it did.  A
command that fails is one that reports no end."
  (dolist (call steps)
    (when (and (vigil-status--call-p call)
               (eq (vigil-survey-step-status call) 'running))
      (let ((agent (vigil-survey-step-agent call))
            (time (vigil-survey-step-time call)))
        (if (cl-some (lambda (step)
                       (and (not (eq step call))
                            (> (vigil-survey-step-time step) (+ time 2))
                            (or (equal (vigil-survey-step-agent step) agent)
                                (memq (vigil-survey-step-kind step) '(prompt reply)))))
                     steps)
            (puthash call t vigil-status--unended)
          (remhash call vigil-status--unended))))))

(defun vigil-status--running-p (call)
  "Whether CALL is still going."
  (and (eq (vigil-survey-step-status call) 'running)
       (not (gethash call vigil-status--unended))))

(defun vigil-status-turns (session)
  "SESSION's turns, oldest first, each a plist.
:index, counting from 1; :prompt, the step that began it; :calls, its calls
in order, a subagent's among them; :reply, the step that ended it, or nil;
:start and :end, when, :end being the last thing heard of it."
  (let ((index 0) (turns (vigil-survey-turns session)) found)
    (vigil-status--mark-unended (apply #'append turns))
    (dolist (turn turns)
      (when (eq (vigil-survey-step-kind (car turn)) 'prompt)
        (let* ((prompt (car turn))
               (reply (car (last (seq-filter
                                  (lambda (step)
                                    (eq (vigil-survey-step-kind step) 'reply))
                                  turn))))
               (start (vigil-survey-step-time prompt)))
          (push (list :index (cl-incf index) :prompt prompt
                      :calls (seq-filter #'vigil-status--call-p (cdr turn))
                      :reply reply :start start
                      :end (apply #'max start
                                  (mapcar (lambda (step)
                                            (or (vigil-survey-step-end step)
                                                (vigil-survey-step-time step)
                                                start))
                                          turn)))
                found))))
    (nreverse found)))

(defun vigil-status--took (step)
  "How long the call STEP took, in seconds: so far, if it is still going.
Nil where it ended without saying when."
  (when-let* ((start (vigil-survey-step-time step))
              (end (or (vigil-survey-step-end step)
                       (and (vigil-status--running-p step) (float-time)))))
    (- end start)))

(defun vigil-status--duration (seconds)
  "SECONDS in a few characters: 0.4s, 12s, 3m05s, 1h02m."
  (cond ((null seconds) "")
        ((< seconds 10) (format "%.1fs" seconds))
        ((< seconds 60) (format "%ds" (round seconds)))
        ((< seconds 3600) (format "%dm%02ds" (/ (round seconds) 60) (% (round seconds) 60)))
        (t (format "%dh%02dm" (/ (round seconds) 3600) (/ (% (round seconds) 3600) 60)))))

(defun vigil-status--counts (calls)
  "CALLS in a few words: how many, of which kinds, and how many failed."
  (if (null calls)
      "no calls"
    (let ((kinds '((command . "command") (edit . "edit") (read . "read")
                   (subagent . "subagent") (web . "web") (other . "other")))
          (failed (cl-count 'failed calls :key #'vigil-survey-step-status))
          (unended (cl-count-if (lambda (call) (gethash call vigil-status--unended))
                                calls))
          said)
      (pcase-dolist (`(,kind . ,name) kinds)
        (let ((count (cl-count kind calls :key #'vigil-survey-step-kind)))
          (when (> count 0)
            (push (format "%d %s%s" count name
                          (if (or (= count 1) (member name '("web" "other"))) "" "s"))
                  said))))
      (concat (format "%d call%s: " (length calls) (if (= 1 (length calls)) "" "s"))
              (string-join (nreverse said) ", ")
              (if (> failed 0) (format "; %d failed" failed) "")
              (if (> unended 0) (format "; %d reported no end" unended) "")))))

;;;; Where a session is

(defun vigil-status--agent (session)
  "The buffer SESSION's agent is in, in this Emacs; or nil."
  (and (boundp 'cooked-host-name)
       (cl-find-if (lambda (buffer)
                     (and (local-variable-p 'cooked-host-name buffer)
                          (equal (buffer-local-value 'cooked-host-name buffer) session)))
                   (buffer-list))))

(defun vigil-status--agent-or-error ()
  "The buffer this session's agent is in, or an error saying it has none."
  (or (vigil-status--agent vigil-status--session)
      (user-error "%s is not open in this Emacs, and this acts on its buffer"
                  vigil-status--session)))

(defun vigil-status--find-root (session)
  "The repository SESSION works in: its buffer's, or its last report's."
  (or (when-let* ((agent (vigil-status--agent session)))
        (vigil-git-root (buffer-local-value 'default-directory agent)))
      (when-let* ((directory (vigil-survey--directory session))
                  ((file-directory-p directory))
                  (newest (car (last (directory-files directory t "\\.json\\'"))))
                  (cwd (alist-get 'cwd (vigil-base-json-file newest)))
                  ((stringp cwd))
                  ((file-directory-p cwd)))
        (vigil-git-root cwd))))

;;;; What it built, and the commits since

(defun vigil-status--read-built (root session)
  "What the snapshots of ROOT say SESSION built: a plist, or nil.
:changes, the files that differ since its latest beginning; :prompts, for
each prompt a snapshot was kept of, (TIME ID CHANGES): when it was given,
its id, and what changed after it."
  (ignore-errors
    (when-let* ((from (plist-get
                       (cl-find session (vigil-review-sessions root)
                                :key (lambda (s) (plist-get s :host)) :test #'equal)
                       :from))
                (span (vigil-review-span root from)))
      (let ((prompts (plist-get span :prompts))
            (to (plist-get span :to))
            found)
        (while prompts
          (let ((prompt (pop prompts)))
            (push (list (plist-get prompt :time) (plist-get prompt :prompt)
                        (vigil-review-changes root (plist-get prompt :commit)
                                              (plist-get (or (car prompts) to) :commit)))
                  found)))
        (list :changes (vigil-review-changes root (plist-get from :commit)
                                             (plist-get to :commit))
              :prompts (nreverse found))))))

(defun vigil-status--built-after (turn)
  "What the snapshots say of TURN's prompt: (TIME ID CHANGES), or nil.
The one kept within a few seconds of when the prompt was given."
  (cl-find-if (lambda (entry) (< (abs (- (car entry) (plist-get turn :start))) 5))
              (plist-get vigil-status--built :prompts)))

(defun vigil-status--versions (root hash)
  "The versions the commit HASH of ROOT added to the changelog: their names."
  (let ((text (vigil-git root "show" "--format=" "-U0" hash "--" vigil-status-changelog))
        (start 0) found)
    (while (and text (string-match "^\\+## +\\[?\\([^] \n]+\\)" text start))
      (setq start (match-end 0))
      (push (match-string 1 text) found))
    (nreverse found)))

(defun vigil-status-commits (root since)
  "The commits made in ROOT since the time SINCE, oldest first: plists.
:hash; :time; :subject; :refs, the branches and tags at it, as git says
them; :versions, the versions it added to the changelog."
  (let (found)
    (dolist (line (split-string
                   (or (vigil-git root "log" "--branches" "--tags" "HEAD"
                                  (format-time-string "--since=%FT%T%z" since)
                                  "--format=%H%x1f%ct%x1f%s%x1f%D")
                       "")
                   "\n" t))
      (pcase (split-string line "\x1f")
        (`(,hash ,time ,subject ,refs)
         (when (>= (string-to-number time) (floor since))
           (push (list :hash hash :time (string-to-number time) :subject subject
                       :refs (and (not (string-empty-p refs)) refs)
                       :versions (vigil-status--versions root hash))
                 found)))))
    (sort found (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

;;;; Drawing

(defun vigil-status--clock (time)
  "TIME as this buffer says it: with the day, if the session has several."
  (let ((first (plist-get (car vigil-status--turns) :start)))
    (format-time-string
     (if (and first (not (equal (format-time-string "%F" first)
                                (format-time-string "%F"))))
         "%b %d %H:%M" "%H:%M")
     time)))

(defun vigil-status--insert-top ()
  "Insert what every view begins with: the session, and the views there are."
  (let ((session vigil-status--session))
    (insert (propertize session 'face 'bold)
            (propertize (concat "  "
                                (if vigil-status--root
                                    (abbreviate-file-name vigil-status--root)
                                  "in no repository")
                                (if (vigil-status--agent session)
                                    "" "  not open in this Emacs"))
                        'face 'shadow)
            "\n")
    (pcase-dolist (`(,view ,key ,name) vigil-status-views)
      (insert (propertize key 'face 'help-key-binding) " "
              (propertize name 'face (if (eq view vigil-status--view)
                                         'vigil-status-view 'default))
              "   "))
    (insert (propertize "?" 'face 'help-key-binding) " more\n\n")))

(defun vigil-status--turn-line (turn &optional width)
  "The line TURN goes by: its number, when, how long, and its prompt.
The prompt in WIDTH characters, default 60."
  (let ((text (vigil-survey-step-text (plist-get turn :prompt))))
    (format "%2d  %s  %6s  “%s”"
            (plist-get turn :index)
            (vigil-status--clock (plist-get turn :start))
            (vigil-status--duration (- (plist-get turn :end) (plist-get turn :start)))
            (vigil-base-one-line (or text "") (or width 60)))))

(defun vigil-status--changes-said (changes)
  "CHANGES in a few characters: how many files, and lines in and out."
  (if changes
      (pcase-let ((`(,_ ,_ ,_ ,added ,removed) (vigil-review--totals changes)))
        (format "%d file%s +%d −%d" (length changes)
                (if (= 1 (length changes)) "" "s") added removed))
    ""))

(defun vigil-status--indented (text indent)
  "TEXT with every line of it after INDENT spaces."
  (let ((prefix (make-string indent ?\s)))
    (mapconcat (lambda (line) (if (string-empty-p line) "" (concat prefix line)))
               (split-string (string-trim (or text "")) "\n")
               "\n")))

(defun vigil-status--state-said (call)
  "How CALL went, where it did not simply end well: a few words, or none."
  (cond ((eq (vigil-survey-step-status call) 'failed)
         (propertize "  failed" 'face 'vigil-status-failed))
        ((vigil-status--running-p call) (propertize "  running" 'face 'warning))
        ((gethash call vigil-status--unended)
         (propertize "  no end reported" 'face 'vigil-status-failed))
        (t "")))

(defun vigil-status--call-line (call start)
  "The line the call CALL goes by, in a turn that began at START."
  (let ((offset (max 0 (- (vigil-survey-step-time call) start))))
    (propertize
     (format "    %7s  %6s  %-8s %s%s\n"
             (concat "+" (vigil-status--duration offset))
             (vigil-status--duration (vigil-status--took call))
             (if (vigil-survey-step-agent call)
                 (concat "↳" (symbol-name (vigil-survey-step-kind call)))
               (symbol-name (vigil-survey-step-kind call)))
             (vigil-base-one-line (or (vigil-survey-step-text call)
                                      (vigil-survey-step-name call) "")
                                  90)
             (vigil-status--state-said call))
     'vigil-status-call (vigil-survey-step-id call))))

(defun vigil-status--insert-status ()
  "Insert the status view: the session in short."
  (let* ((turns vigil-status--turns)
         (calls (apply #'append (mapcar (lambda (turn) (plist-get turn :calls)) turns)))
         (commands (seq-filter (lambda (call) (eq (vigil-survey-step-kind call) 'command))
                               calls))
         (running (cl-count-if #'vigil-status--running-p calls))
         (objective (vigil-survey-objective vigil-status--session))
         (subagents (vigil-survey-subagents vigil-status--session))
         (changes (plist-get vigil-status--built :changes)))
    (if (null turns)
        (insert "No prompt of this session has been reported.\n")
      (insert (format "Since %s: %d prompt%s.  %s.\n"
                      (vigil-status--clock (plist-get (car turns) :start))
                      (length turns) (if (= 1 (length turns)) "" "s")
                      (vigil-status--counts calls)))
      (when commands
        (insert (format "Its commands took %s in all.\n"
                        (vigil-status--duration
                         (apply #'+ (mapcar (lambda (call) (or (vigil-status--took call) 0))
                                            commands))))))
      (when subagents
        (insert (format "%d subagent%s, %d of them running.\n"
                        (length subagents) (if (= 1 (length subagents)) "" "s")
                        (cl-count 'running subagents
                                  :key (lambda (s) (plist-get s :status))))))
      (when (> running 0)
        (insert (propertize (format "%d call%s running now.\n" running
                                    (if (= running 1) " is" "s are"))
                            'face 'warning)))
      (when objective
        (insert (format "Working on: %s (%d of %d done).\n"
                        (plist-get objective :text) (plist-get objective :done)
                        (plist-get objective :total))))
      (insert "\n" (propertize "Built" 'face 'vigil-status-heading)
              (propertize "   r reviews it" 'face 'shadow) "\n  "
              (cond ((null vigil-status--root) "It works in no repository.")
                    ((null vigil-status--built)
                     "No snapshot is kept of it: see `vigil snapshots on'.")
                    (t (concat (capitalize (substring (vigil-review--count changes) 0 1))
                               (substring (vigil-review--count changes) 1)
                               " since it began.")))
              "\n")
      (insert "\n" (propertize "Last prompts" 'face 'vigil-status-heading)
              (propertize "   P shows them all" 'face 'shadow) "\n")
      (dolist (turn (last turns vigil-status-recent))
        (insert (propertize
                 (concat (vigil-status--turn-line turn) "\n")
                 'vigil-status-turn (plist-get turn :index))
                (propertize
                 (format "      %s%s\n" (vigil-status--counts (plist-get turn :calls))
                         (if (plist-get turn :reply) "" "; no reply yet"))
                 'face 'shadow
                 'vigil-status-turn (plist-get turn :index))))
      (when vigil-status--root
        (insert "\n" (propertize "Commits since it began" 'face 'vigil-status-heading)
                (propertize "   b shows them among the prompts" 'face 'shadow) "\n")
        (if vigil-status--commits
            (dolist (commit (last vigil-status--commits 8))
              (vigil-status--insert-commit commit "  "))
          (insert "  None.\n"))))))

(defun vigil-status--insert-commit (commit indent)
  "Insert the line COMMIT goes by, after INDENT."
  (insert (propertize
           (concat indent
                   (vigil-status--clock (plist-get commit :time)) "  "
                   (propertize (substring (plist-get commit :hash) 0 7)
                               'face 'vigil-status-commit)
                   " " (plist-get commit :subject)
                   (if (plist-get commit :refs)
                       (propertize (format "  (%s)" (plist-get commit :refs))
                                   'face 'shadow)
                     "")
                   (if (plist-get commit :versions)
                       (propertize (format "  changelog: %s"
                                           (string-join (plist-get commit :versions) ", "))
                                   'face 'success)
                     "")
                   "\n")
           'vigil-status-commit (plist-get commit :hash))))

(defun vigil-status--insert-prompts ()
  "Insert the prompts view: each prompt, and under it what it led to."
  (let ((last (car (last vigil-status--turns))))
    (unless vigil-status--turns
      (insert "No prompt of this session has been reported.\n"))
    (dolist (turn vigil-status--turns)
      (let* ((prompt (plist-get turn :prompt))
             (reply (plist-get turn :reply))
             (after (nth 2 (vigil-status--built-after turn)))
             (heading (point)))
        (insert (propertize
                 (concat (vigil-status--turn-line turn)
                         (propertize
                          (concat (format "   %d call%s"
                                          (length (plist-get turn :calls))
                                          (if (= 1 (length (plist-get turn :calls))) "" "s"))
                                  (if after
                                      (concat "   " (vigil-status--changes-said after))
                                    ""))
                          'face 'shadow)
                         "\n")
                 'vigil-status-turn (plist-get turn :index)
                 'vigil-status-heading t
                 'vigil-status-text (vigil-survey-step-text prompt)))
        (add-face-text-property heading (+ heading 2) 'vigil-status-heading)
        (let ((body (point)))
          (insert (propertize
                   (format "    %s\n\n" (vigil-status--counts (plist-get turn :calls)))
                   'face 'shadow
                   'vigil-status-turn (plist-get turn :index)))
          (insert (propertize
                   (concat (vigil-status--indented (vigil-survey-step-text prompt) 4)
                           "\n\n")
                   'vigil-status-turn (plist-get turn :index)
                   'vigil-status-text (vigil-survey-step-text prompt)))
          (dolist (call (plist-get turn :calls))
            (insert (vigil-status--call-line call (plist-get turn :start))))
          (insert (if (plist-get turn :calls) "\n" "")
                  (if reply
                      (propertize
                       (concat (vigil-status--indented (vigil-survey-step-text reply) 4)
                               "\n")
                       'face 'font-lock-doc-face
                       'vigil-status-turn (plist-get turn :index)
                       'vigil-status-text (vigil-survey-step-text reply))
                    (propertize "    No reply yet.\n" 'face 'shadow)))
          ;; Every turn but the last begins folded: the list is the prompts.
          (vigil-review--make-fold (1- body) (1- (point))
                                   (count-lines body (point)) 'turn
                                   (not (eq turn last))))
        (insert "\n")))))

(defun vigil-status--insert-answers ()
  "Insert the answers view: the replies alone."
  (let ((without 0))
    (dolist (turn vigil-status--turns)
      (if-let* ((reply (plist-get turn :reply))
                (text (vigil-survey-step-text reply)))
          (let ((heading (point)))
            (insert (propertize
                     (format "%2d  %s  to “%s”\n" (plist-get turn :index)
                             (vigil-status--clock (vigil-survey-step-time reply))
                             (vigil-base-one-line
                              (or (vigil-survey-step-text (plist-get turn :prompt)) "") 70))
                     'vigil-status-turn (plist-get turn :index)
                     'vigil-status-heading t
                     'vigil-status-text text))
            (add-face-text-property heading (1- (point)) 'vigil-status-heading)
            (let ((body (point)))
              (insert (propertize (concat (vigil-status--indented text 2) "\n")
                                  'vigil-status-turn (plist-get turn :index)
                                  'vigil-status-text text))
              (vigil-review--make-fold (1- body) (1- (point))
                                       (count-lines body (point)) 'turn nil))
            (insert "\n"))
        (cl-incf without)))
    (when (> without 0)
      (insert (propertize (format "%d prompt%s no reply yet.\n" without
                                  (if (= without 1) " has" "s have"))
                          'face 'shadow)))
    (insert (propertize
             "Only the reply that ended each turn is kept: not what the agent said between calls.\n"
             'face 'shadow))))

(defun vigil-status--insert-commands ()
  "Insert the commands view: every command, when, and for how long."
  (let (rows (total 0))
    (dolist (turn vigil-status--turns)
      (dolist (call (plist-get turn :calls))
        (when (eq (vigil-survey-step-kind call) 'command)
          (push (cons turn call) rows)
          (cl-incf total (or (vigil-status--took call) 0)))))
    (setq rows (nreverse rows))
    (when vigil-status--by-duration
      (setq rows (sort rows (lambda (a b)
                              (> (or (vigil-status--took (cdr a)) 0)
                                 (or (vigil-status--took (cdr b)) 0))))))
    (insert (format "%d command%s, %s in all, %d failed, %d reported no end.  "
                    (length rows) (if (= 1 (length rows)) "" "s")
                    (vigil-status--duration total)
                    (cl-count 'failed rows
                              :key (lambda (row) (vigil-survey-step-status (cdr row))))
                    (cl-count-if (lambda (row) (gethash (cdr row) vigil-status--unended))
                                 rows))
            (propertize (if vigil-status--by-duration
                            "Longest first; D lists them as they ran.\n\n"
                          "As they ran; D lists the longest first.\n\n")
                        'face 'shadow)
            (propertize (format "%-6s  %-12s  %7s  %s\n" "Prompt" "When" "Took" "Command")
                        'face 'vigil-status-heading))
    (pcase-dolist (`(,turn . ,call) rows)
      (progn
        (insert (propertize
                 (format "%-6d  %-12s  %7s  %s%s%s\n"
                         (plist-get turn :index)
                         (vigil-status--clock (vigil-survey-step-time call))
                         (vigil-status--duration (vigil-status--took call))
                         (if (vigil-survey-step-agent call) "↳ " "")
                         (vigil-base-one-line (or (vigil-survey-step-text call) "") 100)
                         (vigil-status--state-said call))
                 'vigil-status-call (vigil-survey-step-id call)
                 'vigil-status-turn (plist-get turn :index)))))))

(defun vigil-status--insert-build ()
  "Insert the build view: prompts and commits, in the order they happened."
  (let ((events (sort (append
                       (mapcar (lambda (turn) (cons (plist-get turn :start) turn))
                               vigil-status--turns)
                       (mapcar (lambda (commit) (cons (plist-get commit :time) commit))
                               vigil-status--commits))
                      (lambda (a b) (< (car a) (car b))))))
    (cond
     ((null vigil-status--root)
      (insert "This session works in no repository: there are no commits to set its prompts against.\n\n"))
     ((null vigil-status--commits)
      (insert (propertize "No commit has been made since it began.\n\n" 'face 'shadow))))
    (pcase-dolist (`(,_ . ,event) events)
      (if (plist-get event :hash)
          (vigil-status--insert-commit event "      ● ")
        (let ((after (nth 2 (vigil-status--built-after event)))
              (start (point)))
          (insert (propertize
                   (concat (vigil-status--turn-line event 70)
                           (propertize (if after
                                           (concat "   " (vigil-status--changes-said after))
                                         "")
                                       'face 'shadow)
                           "\n")
                   'vigil-status-turn (plist-get event :index)
                   'vigil-status-heading t
                   'vigil-status-text (vigil-survey-step-text (plist-get event :prompt))))
          (add-face-text-property start (+ start 2) 'vigil-status-heading))))
    (when (and vigil-status--root
               (file-exists-p (expand-file-name vigil-status-changelog vigil-status--root)))
      (insert "\n"
              (propertize
               (format "A commit that added a version to %s says which.  RET on a commit shows it; d on a prompt, what changed after it.\n"
                       vigil-status-changelog)
               'face 'shadow)))))

(defun vigil-status--render ()
  "Draw this buffer again, in the view it is in, from what was last read."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (remove-overlays)
    (erase-buffer)
    (vigil-status--insert-top)
    (pcase vigil-status--view
      ('prompts (vigil-status--insert-prompts))
      ('answers (vigil-status--insert-answers))
      ('commands (vigil-status--insert-commands))
      ('build (vigil-status--insert-build))
      (_ (vigil-status--insert-status)))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun vigil-status--read ()
  "Read the session again: its turns, what it built, and the commits since."
  (let* ((session vigil-status--session)
         (root (vigil-status--find-root session))
         (turns (vigil-status-turns session)))
    (setq vigil-status--root root
          vigil-status--turns turns
          vigil-status--built (and root (vigil-status--read-built root session))
          vigil-status--commits (and root turns
                                     (vigil-status-commits
                                      root (plist-get (car turns) :start))))
    (when root (setq default-directory root))))

;;;; Commands of the buffer

(defun vigil-status-refresh ()
  "Read the session again, and draw this buffer."
  (interactive)
  (vigil-status--read)
  (vigil-status--render))

(defun vigil-status--show (view &optional turn)
  "Show VIEW of this session; at the turn of index TURN, where one is named."
  (unless (derived-mode-p 'vigil-status-mode)
    (vigil (vigil-status--session-here)))
  (setq vigil-status--view view)
  (vigil-status--render)
  (goto-char (point-min))
  (if turn
      (when-let* ((found (text-property-any (point-min) (point-max)
                                            'vigil-status-turn turn)))
        (goto-char found)
        (dolist (fold (vigil-review--folds (line-end-position) (1+ (line-end-position))))
          (vigil-review--fold fold nil)))
    (forward-line 3)))

(defun vigil-status-show-status ()
  "Show the session in short."
  (interactive)
  (vigil-status--show 'status))

(defun vigil-status-show-prompts ()
  "Show each prompt of the session, and under it what it led to."
  (interactive)
  (vigil-status--show 'prompts (get-text-property (point) 'vigil-status-turn)))

(defun vigil-status-show-answers ()
  "Show the session's replies alone."
  (interactive)
  (vigil-status--show 'answers (get-text-property (point) 'vigil-status-turn)))

(defun vigil-status-show-commands ()
  "Show every command the session ran, when, and for how long."
  (interactive)
  (vigil-status--show 'commands))

(defun vigil-status-show-build ()
  "Show the session's prompts and the repository's commits, in order."
  (interactive)
  (vigil-status--show 'build (get-text-property (point) 'vigil-status-turn)))

(defun vigil-status-by-duration ()
  "List the commands longest first, or as they ran."
  (interactive)
  (setq vigil-status--by-duration (not vigil-status--by-duration))
  (vigil-status--show 'commands))

(defun vigil-status--show-commit (hash)
  "Show the commit HASH of this session's repository."
  (let ((default-directory vigil-status--root))
    (if (fboundp 'magit-show-commit)
        (magit-show-commit hash)
      (let ((text (vigil-git vigil-status--root "show" "--stat" "-p" hash)))
        (with-current-buffer (get-buffer-create (format "*vigil commit: %s*"
                                                        (substring hash 0 7)))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (or text ""))
            (goto-char (point-min)))
          (diff-mode)
          (setq buffer-read-only t)
          (pop-to-buffer (current-buffer)))))))

(defun vigil-status--call (action)
  "Do ACTION, a command of vigil-embark.el's, to the call at point."
  (let ((id (or (get-text-property (point) 'vigil-status-call)
                (user-error "No call here"))))
    (vigil-status--agent-or-error)
    (unless (and (require 'vigil nil t) (require 'vigil-embark nil t))
      (user-error "A call is shown by vigil.el, which could not be loaded"))
    (funcall action (concat vigil-status--session "/" id))))

(defun vigil-status-act ()
  "Open what is at point: a call, a commit, or a prompt and what it led to."
  (interactive)
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond
     ((get-text-property (point) 'vigil-status-call)
      (vigil-status--call #'vigil-embark-inspect))
     (commit (vigil-status--show-commit commit))
     ((and turn (vigil-review--fold-here)) (vigil-review-toggle))
     (turn (vigil-status--show 'prompts turn))
     (t (user-error "Nothing to open here")))))

(defun vigil-status-goto ()
  "Go to the line of the conversation where the call at point shows."
  (interactive)
  (vigil-status--call #'vigil-embark-goto))

(defun vigil-status-copy ()
  "Copy the prompt or the reply at point."
  (interactive)
  (let ((text (or (get-text-property (point) 'vigil-status-text)
                  (user-error "Neither a prompt nor a reply here"))))
    (kill-new text)
    (message "Copied %d characters" (length text))))

(defun vigil-status-diff ()
  "Show what changed after the prompt at point, or the commit at point."
  (interactive)
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond
     (commit (vigil-status--show-commit commit))
     (turn
      (let ((entry (or (vigil-status--built-after
                        (cl-find turn vigil-status--turns
                                 :key (lambda (turn) (plist-get turn :index))))
                       (user-error "No snapshot was kept of this prompt"))))
        (vigil-snapshot-show vigil-status--root (nth 1 entry))))
     (t (user-error "Neither a prompt nor a commit here")))))

(defun vigil-status-next-heading (&optional backward)
  "Go to the next prompt's line; the one before, with BACKWARD."
  (interactive)
  (let ((position (point)) found)
    (save-excursion
      (while (and (not found)
                  (eq 0 (forward-line (if backward -1 1)))
                  (not (if backward (bobp) (eobp))))
        (when (get-text-property (point) 'vigil-status-heading)
          (setq found (point))))
      (when (and backward (not found) (bobp)
                 (get-text-property (point) 'vigil-status-heading))
        (setq found (point))))
    (goto-char (or found position))
    (unless found (message "No more prompts"))))

(defun vigil-status-previous-heading ()
  "Go to the prompt's line before this one."
  (interactive)
  (vigil-status-next-heading t))

;;;; The rest of vigil, for this session

(defun vigil-status--session-here ()
  "The session this buffer is of, or is the agent of; or an error."
  (or vigil-status--session
      (and (boundp 'cooked-host-name) (stringp cooked-host-name) cooked-host-name)
      (user-error "No session here: M-x vigil chooses one")))

(defun vigil-status-review ()
  "Show what this session built, against what was there when it began."
  (interactive)
  (let* ((session (vigil-status--session-here))
         (root (or vigil-status--root (vigil-status--find-root session)
                   (user-error "%s works in no repository" session)))
         (beginning (or (cl-find session (vigil-review-sessions root)
                                 :key (lambda (s) (plist-get s :host)) :test #'equal)
                        (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                    session))))
    (vigil-review--open root beginning)))

(defun vigil-status-context ()
  "Show everything that has entered this session's agent's context."
  (interactive)
  (let ((agent (vigil-status--agent-or-error)))
    (require 'vigil)
    (vigil-context agent)))

(defun vigil-status-turn ()
  "Show a turn of this session, call by call, where its conversation is."
  (interactive)
  (let ((agent (vigil-status--agent-or-error)))
    (require 'vigil)
    (pop-to-buffer agent)
    (call-interactively #'vigil-turn)))

(defun vigil-status-focus ()
  "Show only the prompts and replies in this session's conversation, or all."
  (interactive)
  (let ((agent (vigil-status--agent-or-error)))
    (require 'vigil)
    (require 'vigil-transcript)
    (pop-to-buffer agent)
    (call-interactively #'vigil-focus-mode)))

(defun vigil-status-paste-prompt ()
  "Choose an earlier prompt of this session, and paste it at its input."
  (interactive)
  (let ((agent (vigil-status--agent-or-error)))
    (require 'vigil)
    (pop-to-buffer agent)
    (call-interactively #'vigil-prompts)))

(defun vigil-status-graph ()
  "Draw this session's turns as a graph, every one there is a record of."
  (interactive)
  (require 'vigil-graph)
  (vigil-graph (vigil-status--session-here) 0))

(defun vigil-status-codebase ()
  "Show where this session's repository is changing."
  (interactive)
  (require 'vigil-codebase)
  (vigil-codebase (or vigil-status--root default-directory)))

(defun vigil-status-running ()
  "List the commands agents started that are still going."
  (interactive)
  (require 'vigil)
  (call-interactively #'vigil-running))

(defun vigil-status-archive ()
  "List every conversation kept."
  (interactive)
  (require 'vigil-archive)
  (call-interactively #'vigil-archive))

(defun vigil-status-switch ()
  "Show another session."
  (interactive)
  (vigil (vigil-status--read-session t)))

;;;###autoload (autoload 'vigil-menu "vigil-status" nil t)
(transient-define-prefix vigil-menu ()
  "Every way of looking at a session, and the rest of vigil."
  [["This session"
    ("s" "Status" vigil-status-show-status)
    ("P" "Prompts, and what each led to" vigil-status-show-prompts)
    ("a" "Answers alone" vigil-status-show-answers)
    ("c" "Commands, and how long" vigil-status-show-commands)
    ("b" "Build: prompts and commits" vigil-status-show-build)]
   ["Elsewhere"
    ("r" "Review what it built" vigil-status-review)
    ("x" "Context" vigil-status-context)
    ("t" "A turn, call by call" vigil-status-turn)
    ("G" "Graph of its turns" vigil-status-graph)
    ("f" "Focus its conversation" vigil-status-focus)
    ("y" "Paste an earlier prompt" vigil-status-paste-prompt)]
   ["Not of one session"
    ("R" "Running commands" vigil-status-running)
    ("C" "Where the repository is changing" vigil-status-codebase)
    ("A" "Archive" vigil-status-archive)
    ("S" "Another session" vigil-status-switch)]])

(defvar vigil-status-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'vigil-status-show-status)
    (define-key map (kbd "P") #'vigil-status-show-prompts)
    (define-key map (kbd "a") #'vigil-status-show-answers)
    (define-key map (kbd "c") #'vigil-status-show-commands)
    (define-key map (kbd "b") #'vigil-status-show-build)
    (define-key map (kbd "r") #'vigil-status-review)
    (define-key map (kbd "x") #'vigil-status-context)
    (define-key map (kbd "t") #'vigil-status-turn)
    (define-key map (kbd "G") #'vigil-status-graph)
    (define-key map (kbd "f") #'vigil-status-focus)
    (define-key map (kbd "y") #'vigil-status-paste-prompt)
    (define-key map (kbd "R") #'vigil-status-running)
    (define-key map (kbd "C") #'vigil-status-codebase)
    (define-key map (kbd "A") #'vigil-status-archive)
    (define-key map (kbd "S") #'vigil-status-switch)
    (define-key map (kbd "?") #'vigil-menu)
    (define-key map (kbd "h") #'vigil-menu)
    (define-key map (kbd "RET") #'vigil-status-act)
    (define-key map (kbd "TAB") #'vigil-review-toggle)
    (define-key map (kbd "<backtab>") #'vigil-review-toggle-all)
    (define-key map (kbd "o") #'vigil-status-goto)
    (define-key map (kbd "w") #'vigil-status-copy)
    (define-key map (kbd "d") #'vigil-status-diff)
    (define-key map (kbd "D") #'vigil-status-by-duration)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "M-n") #'vigil-status-next-heading)
    (define-key map (kbd "M-p") #'vigil-status-previous-heading)
    (define-key map (kbd "g") #'vigil-status-refresh)
    map)
  "Keys of a session's buffer.")

(define-derived-mode vigil-status-mode special-mode "Vigil"
  "A session, and every way of looking at it.
\\<vigil-status-mode-map>Five views: \\[vigil-status-show-status] its status, \\[vigil-status-show-prompts] its prompts and what each led to,
\\[vigil-status-show-answers] its replies alone, \\[vigil-status-show-commands] its commands and how long they took, \\[vigil-status-show-build] its
prompts among the repository's commits.  \\[vigil-menu] shows these and the rest of
vigil in a menu.

\\[vigil-status-act] opens what is at point: a call, a commit, a prompt.  \\[vigil-review-toggle] folds and
unfolds, \\[vigil-status-copy] copies the prompt or reply at point, \\[vigil-status-diff] shows what changed
after a prompt, and \\[vigil-status-refresh] reads the session again."
  (setq truncate-lines nil
        word-wrap t))

(defun vigil-status--read-session (&optional ask)
  "The session to show: this buffer's, or one asked for.
Asked for with ASK, or where this buffer is of none."
  (or (and (not ask) vigil-status--session)
      (and (not ask) (boundp 'cooked-host-name) (stringp cooked-host-name)
           cooked-host-name)
      (let* ((directory (vigil-survey--root))
             ;; The one last heard of first.
             (sessions (sort (copy-sequence (vigil-survey-sessions))
                             (lambda (a b)
                               (time-less-p
                                (file-attribute-modification-time
                                 (file-attributes (expand-file-name b directory)))
                                (file-attribute-modification-time
                                 (file-attributes (expand-file-name a directory)))))))
             (table (lambda (string predicate action)
                      (if (eq action 'metadata)
                          '(metadata (display-sort-function . identity)
                                     (cycle-sort-function . identity))
                        (complete-with-action action sessions string predicate)))))
        (unless sessions (user-error "No session has reported anything yet"))
        (completing-read "Session: " table nil t))))

;;;###autoload
(defun vigil (session)
  "Show SESSION, and every way of looking at it.
In an agent's buffer, that agent's session; elsewhere, or with a prefix
argument, one asked for.  \\<vigil-status-mode-map>\\[vigil-menu] there shows what there is."
  (interactive (list (vigil-status--read-session current-prefix-arg)))
  (let ((buffer (get-buffer-create (format "*vigil: %s*" session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vigil-status-mode)
        (vigil-status-mode))
      (setq vigil-status--session session)
      (vigil-status--read)
      (vigil-status--render))
    (pop-to-buffer buffer)
    buffer))

(provide 'vigil-status)
;;; vigil-status.el ends here
