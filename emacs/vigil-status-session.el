;;; vigil-status-session.el --- What `M-x vigil' reads of a session -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil' (vigil-status.el) shows a session.  This is what it knows of
;; one, with nothing of how it is shown:
;;
;; - every option `M-x vigil' has, in one place;
;; - what a session's buffer holds: what was last read of it;
;; - its turns: each prompt, the calls it led to, the reply;
;; - what each command was for (vigil-purpose.el), and so what kind it is;
;; - where it is: its agent's buffer, its repository;
;; - what it built, from the snapshots kept of it (vigil-review.el);
;; - the commits made since it began;
;; - what is changing now.
;;
;; It reads a session's reports by its name (vigil-survey.el), so it needs
;; no agent's buffer, and it only reads.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-base)
(require 'vigil-git)
(require 'vigil-survey)
(require 'vigil-review)
(require 'vigil-purpose)

(defvar cooked-host-name)

;;;; Options

(defgroup vigil-status nil
  "One place to begin from: a session, and its views."
  :group 'vigil)

;; What is read.

(defcustom vigil-status-changelog "CHANGELOG.md"
  "The file a repository's changelog is in, from its top."
  :type 'string)

(defcustom vigil-status-live-files 12
  "How many of the files changing now have their diff laid out."
  :type 'integer)

(defcustom vigil-status-refresh-delay 0.7
  "Seconds after an agent reports something that its session is read again."
  :type 'number)

;; How it is laid out.

(defcustom vigil-status-detail t
  "Whether what is at point is shown in full in a window beside the list.
The buffer is then lists alone: a prompt's calls and reply, a file's diff
and a commit's changes are beside it, and follow point.  Without it they
are under their lines, folded.  \\<vigil-status-mode-map>\\[vigil-status-toggle-detail] changes it for one buffer."
  :type 'boolean)

(defcustom vigil-status-recent 3
  "How many of a session's last prompts its status names."
  :type 'integer)

(define-obsolete-variable-alias 'vigil-status-strip-width
  'vigil-status-timeline-width "0.8.0")

(defcustom vigil-status-timeline-width 24
  "How many characters wide the longest turn's timeline is, in a list."
  :type 'integer)

;; How a command is shown.

(defcustom vigil-status-tidy t
  "Whether a command is shown laid out to be read, where it is shown whole.
Parsed and printed again by shfmt, its long chains broken, the programs
inside it taken out to blocks of their own and each highlighted in its
language (`vigil-command-tidy').  Otherwise, and without shfmt, as it was
given.  What is copied is always the command as it was given."
  :type 'boolean)

(defcustom vigil-status-shellcheck "shellcheck"
  "The shellcheck program, which a command shown whole is checked with.
Nil to check none.  The command is given to it as text; nothing is run."
  :type '(choice (const :tag "Check nothing" nil) string))

(defcustom vigil-status-shellcheck-level "warning"
  "The least serious thing shellcheck is to say: error, warning, info or style."
  :type '(choice (const "error") (const "warning") (const "info") (const "style")))

(defface vigil-status-commit '((t :inherit font-lock-constant-face))
  "A commit's hash.")

;;;; What a session's buffer holds

;; The session, and what was last read of it.

(defvar-local vigil-status--session nil "The session this buffer is of, by its name.")
(defvar-local vigil-status--root nil "The session's repository, or nil if it has none.")
(defvar-local vigil-status--branch nil "The branch the session's repository is on.")
(defvar-local vigil-status--turns nil "The session's turns, as last read.")
(defvar-local vigil-status--built nil "What `vigil-status--read-built' last found.")
(defvar-local vigil-status--commits nil "The commits made since the session began.")
(defvar-local vigil-status--live nil "What `vigil-status--read-live' last found.")
(defvar-local vigil-status--wrote nil
  "The calls a snapshot says changed files: by its id, the snapshot kept after.")
(defvar-local vigil-status--known nil "What git was already asked, by what was asked.")

;; How it is being looked at.

(defvar-local vigil-status--view 'status "Which view is showing.")
(defvar-local vigil-status--detail nil
  "Whether this buffer shows what is at point beside it: see `vigil-status-detail'.")
(defvar-local vigil-status--detail-shown nil "What the window beside last showed.")
(defvar-local vigil-status--by-duration nil "Whether commands are listed longest first.")
(defvar-local vigil-status--looks nil
  "Whether the list of commands has those that only looked in it.")
(defvar-local vigil-status--since 'prompt
  "What changes are counted from as changing now: `prompt', the last, or `session'.")
(defvar-local vigil-status--follow t
  "Whether the changes view goes to what last changed, as it is read again.")
(defvar-local vigil-status--folds nil
  "How each fold of this buffer was left.
An alist of what names a fold and whether it was folded.")

;; Reading it again.

(defvar-local vigil-status--watch nil "The watch on this session's reports.")
(defvar-local vigil-status--timer nil "The timer that reads the session again, if due.")
(defvar-local vigil-status--stale nil
  "Whether the agent has reported something this buffer has not read.")

;;;; Its turns

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

;;;; What a command was for

(defun vigil-status--remember (key make)
  "What MAKE, a function of no arguments, gives: asked once, kept by KEY.
In `vigil-status--known', for as long as this buffer; where there is no
such table, asked each time."
  (if (null vigil-status--known)
      (funcall make)
    (let ((known (gethash key vigil-status--known 'unasked)))
      (if (eq known 'unasked)
          (puthash key (funcall make) vigil-status--known)
        known))))

(defun vigil-status--changes (root a b)
  "The files that differ between the commits A and B of ROOT, asked of git once."
  (vigil-status--remember (list 'changes a b)
                          (lambda () (vigil-review-changes root a b))))

(defun vigil-status--call-changed (call)
  "The names of the files that differed after the command CALL, where known.
From the snapshot kept after it, against the one kept before."
  (when-let* ((snapshot (and vigil-status--wrote
                             (gethash (vigil-survey-step-id call) vigil-status--wrote)))
              ((listp snapshot))
              (before (plist-get snapshot :before))
              (root vigil-status--root))
    (mapcar (lambda (change) (plist-get change :file))
            (vigil-status--changes root before (plist-get snapshot :commit)))))

(defun vigil-status--tags (call &optional deep)
  "What the command CALL was for: ((TAG . WHY)...), never nil.
As `vigil-purpose-tags' says, from its words, the files that differed after
it and the end of what it printed.  With DEEP, a Python program inside it
is looked into as well: for one command, not for a list."
  (let* ((id (vigil-survey-step-id call))
         (wrote (and vigil-status--wrote (gethash id vigil-status--wrote) t)))
    (vigil-status--remember
     (list 'tags id deep wrote (vigil-survey-step-status call))
     (lambda ()
       (let ((tags (or (ignore-errors
                         (vigil-purpose-tags (vigil-survey-step-command call)
                                             (vigil-status--call-changed call)
                                             (vigil-survey-step-result call)
                                             (not deep)))
                       (list (cons 'run "it ran something no rule knows")))))
         ;; A snapshot says the files differed, and not which: it wrote,
         ;; whatever its words.
         (if (and wrote
                  (not (cl-some (lambda (tag) (memq (car tag) '(code tests docs write)))
                                tags)))
             (cons (cons 'write "a snapshot says the files differed after it")
                   (seq-remove (lambda (tag) (memq (car tag) '(look run))) tags))
           tags))))))

(defun vigil-status--kind (call)
  "What kind of call CALL is, a command being one of three by what it was for.
`wrote', where it wrote files: an agent writes them with commands as much
as with its editing tools.  `look', where it only looked.  And else
`command'."
  (let ((kind (vigil-survey-step-kind call)))
    (if (not (eq kind 'command))
        kind
      (let ((tags (mapcar #'car (vigil-status--tags call))))
        (cond ((cl-intersection tags '(code tests docs write)) 'wrote)
              ((memq 'look tags) 'look)
              (t 'command))))))

;;;; Where a session is

(defun vigil-status--agent (session)
  "The buffer SESSION's agent is in, in this Emacs; or nil."
  (and (boundp 'cooked-host-name)
       (cl-find-if (lambda (buffer)
                     (and (local-variable-p 'cooked-host-name buffer)
                          (equal (buffer-local-value 'cooked-host-name buffer) session)))
                   (buffer-list))))

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

;;;; What it built

(defun vigil-status--span (root session)
  "What the snapshots of ROOT hold of SESSION, from its latest beginning.
As `vigil-review-span' says it; nil where none is kept."
  (ignore-errors
    (when-let* ((from (plist-get
                       (cl-find session (vigil-review-sessions root)
                                :key (lambda (s) (plist-get s :host)) :test #'equal)
                       :from)))
      (vigil-review-span root from))))

(defun vigil-status--prompt-snapshots (span)
  "The snapshots of SPAN kept when a prompt was given, every one, in order.
A message sent while the agent is at work is a prompt, and has its own: it
is kept under the id of the prompt that began the turn, and so is not among
SPAN's :prompts, which are one a turn."
  (seq-filter (lambda (snapshot)
                (equal (plist-get snapshot :event) "UserPromptSubmit"))
              (plist-get span :order)))

(defun vigil-status--read-built (root span)
  "What SPAN, a session's snapshots of ROOT, says it built: a plist.
:changes, the files that differ since its latest beginning; :prompts, for
each prompt a snapshot was kept of, (TIME ID CHANGES FROM TO): when it was
given, its turn's id, what changed after it and before the next prompt,
and the two commits that is the difference of."
  (ignore-errors
    (let ((prompts (vigil-status--prompt-snapshots span))
          (from (plist-get span :from))
          (to (plist-get span :to))
          found)
      (while prompts
        (let* ((prompt (pop prompts))
               (a (plist-get prompt :commit))
               (b (plist-get (or (car prompts) to) :commit)))
          (push (list (plist-get prompt :time) (plist-get prompt :prompt)
                      (vigil-status--changes root a b) a b)
                found)))
      (list :changes (vigil-status--changes root (plist-get from :commit)
                                            (plist-get to :commit))
            :prompts (nreverse found)))))

(defun vigil-status--built-after (turn)
  "What the snapshots say of TURN's prompt: (TIME ID CHANGES FROM TO), or nil.
The one kept within a few seconds of when the prompt was given."
  (cl-find-if (lambda (entry) (< (abs (- (car entry) (plist-get turn :start))) 5))
              (plist-get vigil-status--built :prompts)))

;;;; The commits since it began

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
                       :versions (vigil-status--remember
                                  (list 'versions hash)
                                  (lambda () (vigil-status--versions root hash))))
                 found)))))
    (sort found (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

;;;; What is changing now

(defun vigil-status--file-time (file)
  "When FILE of this session's repository was last written, or nil if it is gone."
  (when-let* ((attributes (file-attributes (expand-file-name file vigil-status--root))))
    (float-time (file-attribute-modification-time attributes))))

(defun vigil-status--read-live (root span)
  "What is changing now in ROOT, of the session SPAN is of: a plist, or nil.
:base, the snapshot counted from: the one kept at its last prompt, or with
`vigil-status--since' `session' the one it began at; :to, the files as they
are now; :changes, the files that differ, the last written first; :diffs,
each one's diff, by its name; :latest, the one last written; :moved, where
its diff first differs from when this was last asked: a line of the diff,
counting from 0."
  (when-let* ((span span)
              (to (plist-get span :to))
              (base (or (and (not (eq vigil-status--since 'session))
                             (car (last (vigil-status--prompt-snapshots span))))
                        (plist-get span :from))))
    (let* ((changes (vigil-status--changes root (plist-get base :commit)
                                           (plist-get to :commit)))
           (changes (sort (copy-sequence changes)
                          (lambda (a b)
                            (> (or (vigil-status--file-time (plist-get a :file)) 0)
                               (or (vigil-status--file-time (plist-get b :file)) 0)))))
           (before (plist-get vigil-status--live :diffs))
           (diffs (make-hash-table :test #'equal))
           (latest (plist-get (car changes) :file))
           (moved nil))
      (dolist (change (seq-take changes vigil-status-live-files))
        (let ((file (plist-get change :file)))
          (puthash file
                   (split-string
                    (or (vigil-git root "diff" "--no-renames" (plist-get base :commit)
                                   (plist-get to :commit) "--" file)
                        "")
                    "\n")
                   diffs)))
      (when-let* ((file latest)
                  (new (gethash file diffs))
                  (old (and before (gethash file before))))
        (let ((line 0))
          ;; Which blobs, and how many lines a hunk has, change with any
          ;; change: it is the first line of the files that differs that is
          ;; looked for.
          (while (and new old
                      (or (equal (car new) (car old))
                          (string-match-p "\\`\\(?:@@\\|index \\)" (car new))))
            (setq new (cdr new) old (cdr old) line (1+ line)))
          (when (or new old) (setq moved line))))
      (list :base base :to to :changes changes :diffs diffs :latest latest :moved moved
            :time (float-time)))))

;;;; Reading all of it

(defun vigil-status--read ()
  "Read the session again: its turns, what it built, and the commits since."
  (let* ((session vigil-status--session)
         (root (vigil-status--find-root session))
         (turns (vigil-status-turns session))
         (span (and root (vigil-status--span root session))))
    (unless vigil-status--known
      (setq vigil-status--known (make-hash-table :test #'equal)))
    (setq vigil-status--root root
          vigil-status--turns turns
          vigil-status--branch (and root
                                    (when-let* ((branch (vigil-git root "rev-parse"
                                                                   "--abbrev-ref" "HEAD")))
                                      (string-trim branch)))
          vigil-status--wrote
          (let ((wrote (make-hash-table :test #'equal)))
            ;; One is kept after a command only where the files differed.
            (dolist (snapshot (plist-get span :order))
              (when (and (plist-get snapshot :call)
                         (member (plist-get snapshot :event)
                                 '("PostToolUse" "PostToolUseFailure")))
                (puthash (plist-get snapshot :call) snapshot wrote)))
            wrote)
          vigil-status--built (and span (vigil-status--read-built root span))
          vigil-status--live (and span (ignore-errors (vigil-status--read-live root span)))
          vigil-status--commits (and root turns
                                     (vigil-status-commits
                                      root (plist-get (car turns) :start))))
    (when root (setq default-directory root))))

(provide 'vigil-status-session)
;;; vigil-status-session.el ends here
