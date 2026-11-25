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
(require 'vigil-ui)
(require 'vigil-command)
(require 'vigil-purpose)
(require 'filenotify)

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

(defcustom vigil-status-live-files 12
  "How many of the files changing now have their diff laid out."
  :type 'integer)

(defcustom vigil-status-detail t
  "Whether what is at point is shown in full in a window beside the list.
The buffer is then lists alone: a prompt's calls and reply, a file's diff
and a commit's changes are beside it, and follow point.  Without it they
are under their lines, folded.  \\<vigil-status-mode-map>\\[vigil-status-toggle-detail] changes it for one buffer."
  :type 'boolean)

(defcustom vigil-status-strip-width 24
  "How many characters wide the longest turn's timeline is, in a list."
  :type 'integer)

(defcustom vigil-status-looking-programs
  '("cat" "head" "tail" "less" "more" "bat" "grep" "egrep" "fgrep" "rg" "ag" "ls"
    "wc" "stat" "file" "du" "df" "tree" "nl" "sort" "uniq" "cut" "tr" "xxd" "hexdump"
    "md5" "shasum" "sha256sum" "diff" "cmp" "comm" "find" "fd" "basename" "dirname"
    "realpath" "readlink" "test" "[" "[[" "cd" "pushd" "popd" "echo" "printf" "jq" "yq"
    "which" "type" "command" "pwd" "date" "true" "false" "env" "printenv" "sed" "awk"
    "git" "column" "fold" "rev" "tac" "seq" "expr" "sleep" "uname" "whoami" "id"
    "ps" "pgrep" "lsof" "otool" "strings" "nm")
  "Programs that only look: a command of these alone is a look, not a command.
`sed' counts unless it edits in place, `find' unless it deletes or runs
something, and `git' only with one of `vigil-status-looking-git'.  A command
that writes a file with a redirection, or that changed a file, is not one
whatever its programs."
  :type '(repeat string))

(defcustom vigil-status-looking-git
  '("log" "status" "diff" "show" "rev-parse" "ls-files" "ls-tree" "for-each-ref"
    "reflog" "describe" "blame" "grep" "cat-file" "shortlog" "rev-list" "merge-base"
    "name-rev" "whatchanged" "count-objects" "check-ignore" "var" "version" "help")
  "What `git' is asked that only looks."
  :type '(repeat string))

(defcustom vigil-status-writing-programs
  '("cp" "mv" "rm" "mkdir" "rmdir" "touch" "ln" "chmod" "chown" "tee" "patch"
    "install" "truncate" "unzip" "trash" "rsync" "dd")
  "Programs that write, move or remove files: a command of one is a write.
As is one that writes a file with a redirection, or edits one in place with
`sed -i'.  What a script does is not in its command's words: that is known
only by the files having differed after it."
  :type '(repeat string))

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

(defcustom vigil-status-refresh-delay 0.7
  "Seconds after an agent reports something that its session is read again."
  :type 'number)

(defface vigil-status-commit '((t :inherit font-lock-constant-face))
  "A commit's hash.")

(defconst vigil-status-views
  '((status "s" "Status") (prompts "P" "Prompts") (answers "a" "Answers")
    (commands "c" "Commands") (changes "l" "Changes") (build "b" "Build"))
  "The views of a session: each (VIEW KEY NAME).")

(defvar-local vigil-status--session nil "The session this buffer is of, by its name.")
(defvar-local vigil-status--root nil "The session's repository, or nil if it has none.")
(defvar-local vigil-status--view 'status "Which view is showing.")
(defvar-local vigil-status--by-duration nil "Whether commands are listed longest first.")
(defvar-local vigil-status--turns nil "The session's turns, as last read.")
(defvar-local vigil-status--built nil "What `vigil-status--read-built' last found.")
(defvar-local vigil-status--commits nil "The commits made since the session began.")
(defvar-local vigil-status--branch nil "The branch the session's repository is on.")
(defvar-local vigil-status--live nil "What `vigil-status--read-live' last found.")
(defvar-local vigil-status--since 'prompt
  "What changes are counted from as changing now: `prompt', the last, or `session'.")
(defvar-local vigil-status--follow t
  "Whether the changes view goes to what last changed, as it is read again.")
(defvar-local vigil-status--folds nil
  "How each fold of this buffer was left.
An alist of what names a fold and whether it was folded.")
(defvar-local vigil-status--known nil "What git was already asked, by what was asked.")
(defvar-local vigil-status--watch nil "The watch on this session's reports.")
(defvar-local vigil-status--timer nil "The timer that reads the session again, if due.")
(defvar-local vigil-status--detail nil
  "Whether this buffer shows what is at point beside it: see `vigil-status-detail'.")
(defvar-local vigil-status--detail-shown nil "What the window beside last showed.")
(defvar-local vigil-status--wrote nil
  "The calls a snapshot says changed files: by its id, the snapshot kept after.")
(defvar-local vigil-status--looks nil
  "Whether the list of commands has those that only looked in it.")
(defvar-local vigil-status--stale nil
  "Whether the agent has reported something this buffer has not read.")

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

(defun vigil-status--words (command)
  "The words and programs of COMMAND, as `vigil-history--words' gives them.
With one stream sent to another (`2>&1') taken out first: that names no
file and runs no program."
  (vigil-history--words
   (replace-regexp-in-string "[0-9]*>&[0-9-]+" " " command)))

(defun vigil-status-looks-p (command)
  "Whether COMMAND, a shell command as text, only looks, going by its words.
Every program it runs is one of `vigil-status-looking-programs', used so as
only to look; and it writes no file with a redirection."
  (when (and (stringp command) (not (string-empty-p (string-trim command))))
    (pcase-let ((`(,words . ,programs) (vigil-status--words command)))
      (and programs
           (not (cl-some (lambda (word) (eq (nth 2 word) 'written)) words))
           (cl-every (lambda (program) (member program vigil-status-looking-programs))
                     programs)
           (not (string-match-p
                 "\\_<sed\\_>[^|;&\n]*\\(?:[ \t]-[a-zA-Z]*i\\|--in-place\\)" command))
           (not (string-match-p "\\_<find\\_>[^|;&\n]*[ \t]-\\(?:delete\\|exec\\|ok\\)" command))
           (let ((start 0) (looks t))
             (while (and looks
                         (string-match
                          "\\_<git\\(?:[ \t]+-[cC][ \t]+[^ \t]+\\|[ \t]+--?[-a-z]+\\(?:=[^ \t]+\\)?\\)*[ \t]+\\([a-z][-a-z]*\\)"
                          command start))
               (setq start (match-end 0)
                     looks (and (member (match-string 1 command) vigil-status-looking-git)
                                t)))
             looks)))))

(defun vigil-status-writes-p (command)
  "Whether COMMAND, a shell command as text, writes files, going by its words.
It writes one with a redirection, runs one of
`vigil-status-writing-programs', or edits in place with `sed -i'.  Nil says
only that its words do not show it."
  (when (and (stringp command) (not (string-empty-p (string-trim command))))
    (pcase-let ((`(,words . ,programs) (vigil-status--words command)))
      (or (cl-some (lambda (word)
                     ;; What a redirection writes to: not a name in a heredoc,
                     ;; which is text handed to a program.
                     (and (eq (nth 2 word) 'written) (nth 1 word)))
                   words)
          (cl-some (lambda (program) (member program vigil-status-writing-programs))
                   programs)
          (and (string-match-p
                "\\_<sed\\_>[^|;&\n]*\\(?:[ \t]-[a-zA-Z]*i\\|--in-place\\)" command)
               t)))))

(defun vigil-status--kind (call)
  "What kind of call CALL is, a command being one of three.
`wrote', where a snapshot says the files differed after it, or its words
write a file: an agent writes files with commands as much as with its
editing tools.  `look', where neither, and its words only look.  And else
`command'."
  (let ((kind (vigil-survey-step-kind call)))
    (cond ((not (eq kind 'command)) kind)
          ((and vigil-status--wrote
                (gethash (vigil-survey-step-id call) vigil-status--wrote))
           'wrote)
          ((vigil-status-writes-p (vigil-survey-step-command call)) 'wrote)
          ((vigil-status-looks-p (vigil-survey-step-command call)) 'look)
          (t 'command))))

(defvar vigil-status--checked (make-hash-table :test #'equal)
  "What shellcheck said of each command, by its text.")

(defun vigil-status-check (command)
  "What shellcheck says of COMMAND, a shell command as text.
Each (LINE COLUMN LEVEL MESSAGE CODE), of the command as it was given; nil
where it says nothing, or is not there to ask."
  (when-let* (((stringp command))
              (program (and vigil-status-shellcheck
                            (executable-find vigil-status-shellcheck))))
    (vigil-command-remember
     vigil-status--checked command
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
    (when-let* ((notes (vigil-status-check command)))
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
it and the end of what it printed; and where that says nothing, that it
only looked, wrote something, or ran something.  With DEEP, a Python
program inside it is looked into as well: for one command, not for a list."
  (let* ((id (vigil-survey-step-id call))
         (key (list 'tags id deep (and vigil-status--wrote
                                       (gethash id vigil-status--wrote) t)
                    (vigil-survey-step-status call)))
         (known (and vigil-status--known (gethash key vigil-status--known))))
    (or known
        (let* ((command (vigil-survey-step-command call))
               (kind (vigil-status--kind call))
               (tags (or (ignore-errors
                           (vigil-purpose-tags command (vigil-status--call-changed call)
                                               (vigil-survey-step-result call)
                                               (not deep)))
                         nil))
               (wrote (cl-some (lambda (tag) (memq (car tag) '(code tests docs write)))
                               tags))
               (tags (cond
                      ;; It wrote, and which files is not known: outside the
                      ;; repository, or with no snapshot kept.
                      ((and (eq kind 'wrote) (not wrote))
                       (cons '(write . "by its words: which files, no snapshot says")
                             tags))
                      (tags)
                      ((eq kind 'look) '((look . "its programs only read")))
                      (t '((run . "it ran something no rule knows"))))))
          (when vigil-status--known (puthash key tags vigil-status--known))
          tags))))

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
                       :versions (let ((key (concat "versions " hash)))
                                   (if vigil-status--known
                                       (or (gethash key vigil-status--known)
                                           (puthash key (vigil-status--versions root hash)
                                                    vigil-status--known))
                                     (vigil-status--versions root hash))))
                 found)))))
    (sort found (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

;;;; Drawing

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

(defun vigil-status--set-lines ()
  "Say what this buffer is of in its header line, and its views in its tab line."
  (let ((escape (lambda (text) (replace-regexp-in-string "%" "%%" text))))
    (setq header-line-format
          (funcall escape
                   (concat " " (propertize vigil-status--session 'face 'vigil-ui-strong)
                           (propertize
                            (concat "   "
                                    (if vigil-status--root
                                        (abbreviate-file-name
                                         (directory-file-name vigil-status--root))
                                      "in no repository")
                                    (if vigil-status--branch
                                        (concat "   " vigil-status--branch) "")
                                    (if (vigil-status--agent vigil-status--session)
                                        "" "   not open in this Emacs"))
                            'face 'vigil-ui-dim)))
          tab-line-format
          (funcall escape
                   (vigil-ui-tabs vigil-status-views vigil-status--view
                                  (concat (propertize "?" 'face 'vigil-ui-key)
                                          " menu"))))))

(defun vigil-status--state-said (call)
  "How CALL went, where it did not simply end well: a word or two, or none."
  (cond ((eq (vigil-survey-step-status call) 'failed)
         (propertize "failed" 'face 'vigil-ui-bad))
        ((vigil-status--running-p call) (propertize "running" 'face 'vigil-ui-busy))
        ((gethash call vigil-status--unended)
         (propertize "no end" 'face 'vigil-ui-bad))
        (t "")))

(defconst vigil-status--strip-kinds
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

(defun vigil-status--strip-kind (call)
  "What kind CALL is drawn as in a timeline.
A command that wrote is drawn as a write; one that did not and ran tests or
a check, as a test; and else as what it is."
  (let ((kind (vigil-status--kind call)))
    (if (and (eq kind 'command)
             (cl-some (lambda (tag) (memq (car tag) '(test check)))
                      (vigil-status--tags call)))
        'test
      kind)))

(defun vigil-status--strip (turn cells)
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
              (cl-incf (alist-get (vigil-status--strip-kind call) sums 0) overlap))))
        (let* ((most (car (sort sums (lambda (x y) (> (cdr x) (cdr y))))))
               (kind (cond (failed 'failed)
                           ((and most (>= (cdr most) (/ share 3))) (car most))
                           (edited 'edit)))
               (drawn (or (assq kind vigil-status--strip-kinds)
                          (assq 'other vigil-status--strip-kinds))))
          (push (propertize (nth 1 drawn) 'face (nth 2 drawn)) parts))))
    (apply #'concat (nreverse parts))))

(defun vigil-status--strip-in-list (turn)
  "TURN's timeline as a list has it: as long as the turn was, among the turns.
The longest is `vigil-status-strip-width' characters, and none is under one."
  (let ((longest (apply #'max 0.001
                        (mapcar (lambda (turn)
                                  (- (plist-get turn :end) (plist-get turn :start)))
                                vigil-status--turns))))
    (vigil-status--strip
     turn
     (max 1 (round (* vigil-status-strip-width
                      (/ (- (plist-get turn :end) (plist-get turn :start)) longest)))))))

(defun vigil-status--strip-legend ()
  "What the characters of a timeline are, in a line."
  (concat
   (propertize "  " 'face 'vigil-ui-dim)
   (mapconcat (pcase-lambda (`(,_ ,character ,face ,name))
                (concat (propertize character 'face face)
                        (propertize (concat " " name) 'face 'vigil-ui-dim)))
              (seq-remove (lambda (kind) (memq (car kind) '(web look wrote)))
                          vigil-status--strip-kinds)
              "   ")))

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
         (vigil-status--strip-in-list turn)
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

(defun vigil-status--file-time (file)
  "When FILE of this session's repository was last written, or nil if it is gone."
  (when-let* ((attributes (file-attributes (expand-file-name file vigil-status--root))))
    (float-time (file-attribute-modification-time attributes))))

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
                           (t (vigil-status--changes-said changes))))))
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

(defun vigil-status--changes-said (changes)
  "CHANGES in a few words: how many files are new, changed and gone, and lines."
  (if (null changes)
      "Nothing differs."
    (pcase-let ((`(,new ,changed ,gone ,added ,removed) (vigil-review--totals changes)))
      (concat (string-join
               (delq nil (list (and (> new 0) (format "%d new" new))
                               (and (> changed 0) (format "%d changed" changed))
                               (and (> gone 0) (format "%d gone" gone))))
               ", ")
              "   " (vigil-ui-lines-changed added removed)))))

(defun vigil-status--folded-before (key default)
  "Whether the fold KEY names was folded when this buffer was last drawn.
DEFAULT where it was not there then."
  (let ((known (assoc key vigil-status--folds)))
    (if known (cdr known) default)))

(defun vigil-status--note-folds ()
  "Remember which folds of this buffer are folded, to draw them so again."
  (dolist (fold (vigil-review--folds))
    (when-let* ((key (overlay-get fold 'vigil-status-key)))
      (setf (alist-get key vigil-status--folds nil nil #'equal)
            (vigil-review--folded-p fold)))))

(defun vigil-status--make-fold (body key folded)
  "Fold what was inserted from BODY to point, under the line before BODY.
KEY names it, to remember how it was left; FOLDED is how it is to begin."
  (when (> (point) body)
    (overlay-put (vigil-review-mark-fold
                  (vigil-review--make-fold (1- body) (1- (point))
                                           (count-lines body (point)) 'turn
                                           (vigil-status--folded-before key folded)))
                 'vigil-status-key key)))

(defun vigil-status--label (text)
  "Insert TEXT as the name of a part of what a prompt led to."
  (insert (propertize (concat "    " text "\n") 'face 'vigil-ui-dim)))

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
      (insert "\n" (vigil-status--strip-legend) "\n"))))

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

;;;; What is changing now

(defun vigil-status--live-since ()
  "What the changes shown as changing now are counted from, in a few words."
  (let ((base (plist-get vigil-status--live :base)))
    (cond ((null base) "")
          ((eq vigil-status--since 'session)
           (format "since the session began at %s"
                   (vigil-status--clock (plist-get base :time))))
          (t (format "since the last prompt at %s"
                     (vigil-status--clock (plist-get base :time)))))))

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
         ("Changed" . ,(vigil-status--changes-said changes))
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

(defun vigil-status--file-line (file)
  "Where FILE's own line is in this buffer: the one its diff is under or beside."
  (let ((position (point-min)) found)
    (while (and position (not found))
      (if (and (get-text-property position 'vigil-status-heading)
               (equal (get-text-property position 'vigil-status-file) file))
          (setq found position)
        (setq position (next-single-property-change position 'vigil-status-heading))))
    found))

(defun vigil-status--follow-latest ()
  "Go to where the file last written last changed, and show it."
  (when-let* ((live vigil-status--live)
              (file (plist-get live :latest))
              (heading (vigil-status--file-line file)))
    (goto-char heading)
    (if vigil-status--detail
        ;; Its diff is beside: there, the line that is new.
        (progn
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (set-window-point window (point)))
          (vigil-status--detail-sync t)
          (vigil-status--detail-goto-diff (plist-get live :moved)))
      (dolist (fold (vigil-review--folds (line-end-position) (1+ (line-end-position))))
        (vigil-review--fold fold nil))
      (let ((target (and (plist-get live :moved)
                         (text-property-any heading (point-max) 'vigil-status-diff
                                            (plist-get live :moved)))))
        (when (and target (equal (get-text-property target 'vigil-status-file) file))
          (goto-char target)))
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (set-window-point window (point))
        (with-selected-window window (recenter))))))

;;;; What is at point, beside the list

(defconst vigil-status--shared
  '(vigil-status--session vigil-status--root vigil-status--turns vigil-status--built
    vigil-status--commits vigil-status--live vigil-status--branch vigil-status--known
    vigil-status--view vigil-status--wrote)
  "What a session's buffer knows that the window beside it draws from.")

(defvar-local vigil-status--detail-of nil "The session's buffer this one is beside.")
(defvar-local vigil-status--detail-thing nil "What this buffer shows: (KIND . WHAT).")

(defun vigil-status--thing ()
  "What is at point, to show beside the list: (KIND . WHAT), or nil.
A commit, a file, a call in the list of commands, or a turn: its answer
alone in the answers view."
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (file (get-text-property (point) 'vigil-status-file))
        (call (get-text-property (point) 'vigil-status-call))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond (commit (cons 'commit commit))
          (file (cons 'file file))
          ((and call (eq vigil-status--view 'commands)) (cons 'call call))
          (turn (cons (if (eq vigil-status--view 'answers) 'answer 'turn) turn)))))

(defun vigil-status--detail-buffer ()
  "The buffer that shows what is at point in this session's buffer."
  (let ((status (current-buffer))
        (buffer (get-buffer-create (format "*vigil detail: %s*" vigil-status--session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vigil-status-detail-mode)
        (vigil-status-detail-mode))
      (setq vigil-status--detail-of status))
    buffer))

(defun vigil-status--detail-header (&rest parts)
  "Say PARTS, strings or nil, in this buffer's header line."
  (setq header-line-format
        (replace-regexp-in-string
         "%" "%%"
         (concat " " (string-join (delq nil parts)
                                  (propertize "   " 'face 'vigil-ui-dim))))))

(defun vigil-status--detail-turn (turn answer)
  "Insert TURN, a turn of the session, in full; its ANSWER alone if non-nil."
  (let* ((reply (plist-get turn :reply))
         (after (nth 2 (vigil-status--built-after turn)))
         (width (vigil-ui-width)))
    (vigil-status--detail-header
     (propertize (format "Prompt %d" (plist-get turn :index)) 'face 'vigil-ui-strong)
     (vigil-status--clock (plist-get turn :start))
     (vigil-status--took-cell turn)
     (and (not answer) (vigil-status--counts (plist-get turn :calls)))
     (and after (not answer)
          (concat (vigil-ui-plural (length after) "file") " "
                  (cadr (vigil-status--turn-after turn)))))
    (if answer
        (progn
          (insert (propertize (concat (vigil-ui-cut (vigil-survey-step-text
                                                     (plist-get turn :prompt))
                                                    (- width 2))
                                      "\n\n")
                              'face 'vigil-ui-dim))
          (when reply
            (vigil-ui-block (vigil-ui-markdown (vigil-survey-step-text reply)) 0
                            'vigil-ui-dim
                            'vigil-status-turn (plist-get turn :index)
                            'vigil-status-text (vigil-survey-step-text reply))))
      ;; The turn as a timeline, as wide as there is room, from its
      ;; beginning to its end.
      (let* ((cells (max 10 (- width 4)))
             (took (vigil-status--took-cell turn)))
        (insert "  " (vigil-status--strip turn cells) "\n"
                (propertize (concat "  0"
                                    (make-string (max 1 (- cells 1 (string-width took))) ?\s)
                                    took "\n")
                            'face 'vigil-ui-dim)
                (vigil-status--strip-legend) "\n\n"))
      (when-let* ((commands (seq-filter (lambda (call)
                                          (eq (vigil-survey-step-kind call) 'command))
                                        (plist-get turn :calls))))
        (vigil-ui-sheet `(("Its commands" . ,(vigil-status--tally commands))))
        (insert "\n"))
      (vigil-status--insert-turn turn 0)
      (when after
        (insert (propertize "Changed after it\n" 'face 'vigil-ui-dim))
        (pcase-let ((`(,_ . ,rows)
                     (vigil-ui-table (vigil-status--changes-columns)
                                     (mapcar #'vigil-status--change-cells after)
                                     width)))
          (dolist (change after)
            (insert (propertize (concat (pop rows) "\n")
                                'vigil-status-file (plist-get change :file)))))))))

(defun vigil-status--detail-commit (hash)
  "Insert the commit HASH: what it says, and which files it changed."
  (let* ((commit (cl-find hash vigil-status--commits
                          :key (lambda (commit) (plist-get commit :hash)) :test #'equal))
         (text (vigil-git vigil-status--root "show" "--stat" "--format=%B" hash))
         (parts (split-string (or text "") "\n\n+ " t)))
    (vigil-status--detail-header
     (propertize (concat "Commit " (substring hash 0 7)) 'face 'vigil-ui-strong)
     (and commit (vigil-status--clock (plist-get commit :time)))
     (and commit (vigil-status--refs-said (plist-get commit :refs))))
    (when (plist-get commit :versions)
      (vigil-ui-sheet `(("Changelog" . ,(propertize
                                         (string-join (plist-get commit :versions) " ")
                                         'face 'vigil-ui-good))))
      (insert "\n"))
    (vigil-ui-block (string-trim (car parts)) 0 'vigil-ui-dim
                    'vigil-status-commit hash)
    (when (cdr parts)
      (insert "\n" (propertize "Changed\n" 'face 'vigil-ui-dim))
      (dolist (line (split-string (string-join (cdr parts) "\n") "\n" t))
        (insert "  " (string-trim-left line) "\n")))))

(defun vigil-status--detail-file (file)
  "Insert FILE: what is changing in it now, as a diff."
  (let* ((live vigil-status--live)
         (change (cl-find file (plist-get live :changes)
                          :key (lambda (change) (plist-get change :file)) :test #'equal))
         (time (vigil-status--file-time file))
         (lines (and live (gethash file (plist-get live :diffs)))))
    (vigil-status--detail-header
     (propertize file 'face 'vigil-ui-strong)
     (and change (vigil-ui-lines-changed (plist-get change :added)
                                         (plist-get change :removed)))
     (and time (vigil-status--ago time))
     (and live (vigil-status--live-since)))
    (cond
     (lines (vigil-status--insert-diff file lines))
     (change
      ;; One whose diff was not kept: asked of git now.
      (vigil-status--insert-diff
       file (split-string
             (or (vigil-git vigil-status--root "diff" "--no-renames"
                            (plist-get (plist-get live :base) :commit)
                            (plist-get (plist-get live :to) :commit) "--" file)
                 "")
             "\n")))
     (t (insert (propertize "It does not differ now from when changes are counted from.\n"
                            'face 'vigil-ui-dim))))))

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

(defun vigil-status--detail-call (id)
  "Insert the call ID: a command of the session, and how it went."
  (let (found)
    (dolist (turn vigil-status--turns)
      (dolist (call (plist-get turn :calls))
        (when (equal (vigil-survey-step-id call) id)
          (setq found (cons turn call)))))
    (pcase-let ((`(,turn . ,call) found))
      (when call
        (vigil-status--detail-header
         (propertize (or (vigil-survey-step-name call) "Call") 'face 'vigil-ui-strong)
         (vigil-status--clock (vigil-survey-step-time call))
         (vigil-status--duration (vigil-status--took call))
         (let ((state (vigil-status--state-said call)))
           (and (not (string-empty-p state)) state)))
        (let* ((command (vigil-survey-step-command call))
               (said (vigil-survey-step-text call)))
          ;; Why, in its agent's words, where it said: not the command again.
          (when (or (null command)
                    (not (equal said (vigil-survey--line command 120))))
            (vigil-ui-block (or said "") 0 'vigil-ui-kind-command
                            'vigil-status-call id)
            (insert "\n"))
          (when command
            (vigil-status--insert-command command id)
            (vigil-status--insert-purpose call)))
        (vigil-ui-sheet
         `(("Prompt" . ,(format "%d  %s" (plist-get turn :index)
                                (vigil-ui-cut (vigil-survey-step-text (plist-get turn :prompt))
                                              (- (vigil-ui-width) 14))))
           ("Began" . ,(format "%s, %s into the turn"
                               (vigil-status--clock (vigil-survey-step-time call) t)
                               (vigil-status--duration
                                (max 0 (- (vigil-survey-step-time call)
                                          (plist-get turn :start))))))
           ("Took" . ,(let ((took (vigil-status--duration (vigil-status--took call))))
                        (if (string-empty-p took) "not known: it reported no end" took)))
           ))
        (insert "\n" (propertize "RET opens the call, with what it printed, where its agent is open.\n"
                                 'face 'vigil-ui-dim))))))

(defun vigil-status--detail-render ()
  "Draw this buffer, the one beside a session's, again."
  (let ((inhibit-read-only t)
        (thing vigil-status--detail-thing))
    (remove-overlays)
    (erase-buffer)
    (vigil-ui-begin)
    (setq header-line-format nil)
    (pcase thing
      (`(,(or 'turn 'answer) . ,index)
       (when-let* ((turn (cl-find index vigil-status--turns
                                  :key (lambda (turn) (plist-get turn :index)))))
         (vigil-status--detail-turn turn (eq (car thing) 'answer))))
      (`(commit . ,hash) (vigil-status--detail-commit hash))
      (`(file . ,file) (vigil-status--detail-file file))
      (`(call . ,id) (vigil-status--detail-call id))
      (_ (insert (propertize "What is at point in the list is shown here.\n"
                             'face 'vigil-ui-dim))))
    (goto-char (point-min))
    ;; From its beginning, in every window it shows in: a window keeps its
    ;; own place, which was in what was here before.
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-point window (point-min))
      (set-window-start window (point-min)))))

(defun vigil-status--detail-draw (thing)
  "Draw THING, what is at point in this session's buffer, in the buffer beside.
Gives that buffer."
  (let ((values (mapcar #'symbol-value vigil-status--shared))
        (buffer (vigil-status--detail-buffer)))
    (with-current-buffer buffer
      (cl-mapc #'set vigil-status--shared values)
      (setq vigil-status--detail-thing thing
            default-directory (or vigil-status--root default-directory))
      (vigil-status--detail-render))
    buffer))

(defun vigil-status--detail-window (buffer)
  "Show BUFFER beside this session's buffer, if that is on screen: its window.
To the right where there is room for two side by side, and else below."
  (or (get-buffer-window buffer)
      (when-let* ((window (get-buffer-window (current-buffer))))
        (ignore-errors
          (display-buffer
           buffer
           `((display-buffer-in-direction)
             (window . ,window)
             (direction . ,(if (>= (window-total-width window) 150) 'right 'below))
             (window-width . 0.55)
             (window-height . 0.6)))))))

(defun vigil-status--detail-sync (&optional again)
  "Show what is at point beside this buffer, if it is not what is shown.
With AGAIN, even if it is: what there is to say of it has changed."
  (when (and vigil-status--detail (derived-mode-p 'vigil-status-mode))
    (when-let* ((thing (vigil-status--thing))
                ((or again (not (equal thing vigil-status--detail-shown)))))
      (setq vigil-status--detail-shown thing)
      (vigil-status--detail-window (vigil-status--detail-draw thing)))))

(defun vigil-status--detail-goto-diff (line)
  "In the window beside, go to LINE of the diff shown, counting from 0."
  (when-let* ((line line)
              (buffer (get-buffer (format "*vigil detail: %s*" vigil-status--session))))
    (with-current-buffer buffer
      (when-let* ((target (text-property-any (point-min) (point-max)
                                             'vigil-status-diff line)))
        (goto-char target)
        (dolist (window (get-buffer-window-list buffer nil t))
          (set-window-point window target)
          (with-selected-window window (recenter)))))))

(defun vigil-status--detail-close ()
  "Close the window beside this session's buffer, and its buffer."
  (when-let* ((buffer (get-buffer (format "*vigil detail: %s*" vigil-status--session))))
    (dolist (window (get-buffer-window-list buffer nil t))
      (ignore-errors (delete-window window)))
    (kill-buffer buffer))
  (setq vigil-status--detail-shown nil))

(defun vigil-status--render ()
  "Draw this buffer again, in the view it is in, from what was last read."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (column (current-column)))
    (vigil-status--note-folds)
    (remove-overlays)
    (erase-buffer)
    (vigil-ui-begin)
    (vigil-status--set-lines)
    (pcase vigil-status--view
      ('prompts (vigil-status--insert-prompts))
      ('answers (vigil-status--insert-answers))
      ('commands (vigil-status--insert-commands))
      ('changes (vigil-status--insert-changes))
      ('build (vigil-status--insert-build))
      (_ (vigil-status--insert-status)))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    ;; What is beside is of what was there before.
    (setq vigil-status--detail-shown nil)))

(defun vigil-status--changes (root a b)
  "The files that differ between the commits A and B of ROOT, asked of git once."
  (if (null vigil-status--known)
      (vigil-review-changes root a b)
    (let ((key (concat a b)))
      (or (gethash key vigil-status--known)
          (puthash key (vigil-review-changes root a b) vigil-status--known)))))

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

;;;; Reading again as the agent works

(defun vigil-status--watch ()
  "Read this session again whenever its agent reports something."
  (vigil-status--unwatch)
  (when-let* ((directory (vigil-survey--directory vigil-status--session))
              ((file-directory-p directory))
              (buffer (current-buffer)))
    (setq vigil-status--watch
          (ignore-errors
            (file-notify-add-watch
             directory '(change)
             (lambda (_event)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer (vigil-status--soon)))))))))

(defun vigil-status--unwatch ()
  "Stop reading this session again as its agent reports."
  (when vigil-status--watch
    (ignore-errors (file-notify-rm-watch vigil-status--watch))
    (setq vigil-status--watch nil))
  (when (timerp vigil-status--timer)
    (cancel-timer vigil-status--timer)
    (setq vigil-status--timer nil)))

(defun vigil-status--soon ()
  "Read this session again in a moment, once: reports come several at a time."
  (unless (timerp vigil-status--timer)
    (let ((buffer (current-buffer)))
      (setq vigil-status--timer
            (run-with-timer
             vigil-status-refresh-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq vigil-status--timer nil)
                   ;; Only what is looked at is worth reading again.
                   (if (get-buffer-window buffer t)
                       (ignore-errors (vigil-status--auto))
                     (setq vigil-status--stale t))))))))))

(defun vigil-status--auto ()
  "Read the session again and draw it, leaving the reader where they are.
In the changes view, while following, going to what last changed."
  (setq vigil-status--stale nil)
  (vigil-status--read)
  (let ((starts (mapcar (lambda (window)
                          (cons window (line-number-at-pos (window-start window))))
                        (get-buffer-window-list (current-buffer) nil t))))
    (vigil-status--render)
    (if (and (eq vigil-status--view 'changes) vigil-status--follow)
        (vigil-status--follow-latest)
      (pcase-dolist (`(,window . ,line) starts)
        (set-window-start window (save-excursion (goto-char (point-min))
                                                 (forward-line (1- line))
                                                 (point))
                          t)
        (set-window-point window (point)))
      (vigil-status--detail-sync t))))

;;;; Commands of the buffer

(defun vigil-status-refresh ()
  "Read the session again, and draw this buffer."
  (interactive)
  (vigil-status--read)
  (vigil-status--render))

(defun vigil-status--show (view &optional turn)
  "Show VIEW of this session; at the turn of index TURN, where one is named.
With the detail and no turn named, at the first line of the view there is
something to see of: the last prompt, command or commit, the file last
written."
  (unless (derived-mode-p 'vigil-status-mode)
    (vigil (vigil-status--session-here)))
  (setq vigil-status--view view)
  (when vigil-status--stale
    (setq vigil-status--stale nil)
    (vigil-status--read))
  (vigil-status--render)
  (goto-char (point-min))
  (if-let* ((turn turn)
            (found (text-property-any (point-min) (point-max)
                                      'vigil-status-turn turn)))
      (progn
        (goto-char found)
        (dolist (fold (vigil-review--folds (line-end-position) (1+ (line-end-position))))
          (vigil-review--fold fold nil)))
    (when vigil-status--detail
      (pcase view
        ((or 'prompts 'answers 'changes 'commands 'build)
         (while (and (not (eobp)) (not (vigil-status--thing)))
           (forward-line 1))))
      (unless (vigil-status--thing) (goto-char (point-min)))))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point)))
  (vigil-status--detail-sync))

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

(defun vigil-status-show-changes ()
  "Show the files changing now, and what is changing in each."
  (interactive)
  (vigil-status--show 'changes)
  (when vigil-status--follow (vigil-status--follow-latest)))

(defun vigil-status-toggle-detail ()
  "Show what is at point in a window beside the list; or under its line."
  (interactive)
  (setq vigil-status--detail (not vigil-status--detail))
  (unless vigil-status--detail (vigil-status--detail-close))
  (vigil-status--show vigil-status--view (get-text-property (point) 'vigil-status-turn))
  (message (if vigil-status--detail
               "What is at point is shown beside the list"
             "What a line led to is under it, folded")))

(defun vigil-status-quit ()
  "Leave this session's buffer, and the window beside it."
  (interactive)
  (vigil-status--detail-close)
  (quit-window))

(defun vigil-status-toggle-follow ()
  "Follow the last change as it is made, in the changes view; or stop."
  (interactive)
  (setq vigil-status--follow (not vigil-status--follow))
  (vigil-status-show-changes)
  (message (if vigil-status--follow
               "Following the last change"
             "Not following: the buffer stays where you leave it")))

(defun vigil-status-toggle-since ()
  "Count what is changing from the last prompt, or from the session's beginning."
  (interactive)
  (setq vigil-status--since (if (eq vigil-status--since 'session) 'prompt 'session))
  (vigil-status--read)
  (vigil-status-show-changes))

(defun vigil-status--visit (file &optional line)
  "Visit FILE of this session's repository, at LINE if one is named."
  (let ((name (expand-file-name file vigil-status--root)))
    (unless (file-exists-p name) (user-error "%s is not there now" file))
    (find-file-other-window name)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun vigil-status-toggle-looks ()
  "List the commands that only looked among the others, or leave them out."
  (interactive)
  (setq vigil-status--looks (not vigil-status--looks))
  (vigil-status--show 'commands))

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
     ;; A line of a diff is its file at that line; a file's own line is its
     ;; diff, here or in the view that has it.
     ((get-text-property (point) 'vigil-status-line)
      (vigil-status--visit (get-text-property (point) 'vigil-status-file)
                           (get-text-property (point) 'vigil-status-line)))
     ((and (get-text-property (point) 'vigil-status-file) (vigil-review--fold-here))
      (vigil-review-toggle))
     ((and (get-text-property (point) 'vigil-status-file) vigil-status--detail
           (derived-mode-p 'vigil-status-mode))
      (vigil-status--detail-select))
     ((get-text-property (point) 'vigil-status-file)
      (let ((file (get-text-property (point) 'vigil-status-file)))
        (if (eq vigil-status--view 'changes)
            (vigil-status--goto-file file)
          (setf (alist-get (list 'changes file) vigil-status--folds nil nil #'equal) nil)
          (vigil-status--show 'changes)
          (vigil-status--goto-file file))))
     ((and turn (vigil-review--fold-here)) (vigil-review-toggle))
     ;; What is beside is what there is to open: go there.
     ((and turn vigil-status--detail (derived-mode-p 'vigil-status-mode)
           (memq vigil-status--view '(prompts answers build)))
      (vigil-status--detail-select))
     (turn (vigil-status--show 'prompts turn))
     (t (user-error "Nothing to open here")))))

(defun vigil-status--detail-select ()
  "Go to the window beside, where what is at point is shown."
  (vigil-status--detail-sync)
  (when-let* ((buffer (get-buffer (format "*vigil detail: %s*" vigil-status--session)))
              (window (or (get-buffer-window buffer)
                          (vigil-status--detail-window buffer))))
    (select-window window)))

(defun vigil-status--goto-file (file)
  "Go to FILE's own line in the changes view, and show its diff."
  (let ((position (point-min)) found)
    (while (and position (not found))
      (if (and (get-text-property position 'vigil-status-heading)
               (equal (get-text-property position 'vigil-status-file) file))
          (setq found position)
        (setq position (next-single-property-change position 'vigil-status-heading))))
    (when found
      (goto-char found)
      (dolist (fold (vigil-review--folds (line-end-position) (1+ (line-end-position))))
        (vigil-review--fold fold nil))
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (set-window-point window (point))
        (with-selected-window window (recenter 1))))))

(defun vigil-status-visit ()
  "Visit the file at point, at the line of it that point is on."
  (interactive)
  (if-let* ((file (get-text-property (point) 'vigil-status-file)))
      (vigil-status--visit file (get-text-property (point) 'vigil-status-line))
    (vigil-status-goto)))

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
        ;; Between this prompt's snapshot and the next prompt's: a message
        ;; sent while the agent worked has its own share of the turn.
        (vigil-review--show-diff vigil-status--root (nth 3 entry) (nth 4 entry) nil
                                 (format "Changed after prompt %d of %s, until the next"
                                         turn vigil-status--session))))
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
    ("l" "Changes: what is changing now" vigil-status-show-changes)
    ("b" "Build: prompts and commits" vigil-status-show-build)
    ("v" "Beside the list, or under its lines" vigil-status-toggle-detail)]
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

(defvar vigil-status-mode-map (make-sparse-keymap)
  "Keys of a session's buffer.")

;; Set each time the file is loaded, so that loading it again gives a
;; buffer that is already open the keys that are new.
(define-key vigil-status-mode-map (kbd "s") #'vigil-status-show-status)
(define-key vigil-status-mode-map (kbd "P") #'vigil-status-show-prompts)
(define-key vigil-status-mode-map (kbd "a") #'vigil-status-show-answers)
(define-key vigil-status-mode-map (kbd "c") #'vigil-status-show-commands)
(define-key vigil-status-mode-map (kbd "b") #'vigil-status-show-build)
(define-key vigil-status-mode-map (kbd "r") #'vigil-status-review)
(define-key vigil-status-mode-map (kbd "x") #'vigil-status-context)
(define-key vigil-status-mode-map (kbd "t") #'vigil-status-turn)
(define-key vigil-status-mode-map (kbd "G") #'vigil-status-graph)
(define-key vigil-status-mode-map (kbd "f") #'vigil-status-focus)
(define-key vigil-status-mode-map (kbd "y") #'vigil-status-paste-prompt)
(define-key vigil-status-mode-map (kbd "R") #'vigil-status-running)
(define-key vigil-status-mode-map (kbd "C") #'vigil-status-codebase)
(define-key vigil-status-mode-map (kbd "A") #'vigil-status-archive)
(define-key vigil-status-mode-map (kbd "S") #'vigil-status-switch)
(define-key vigil-status-mode-map (kbd "?") #'vigil-menu)
(define-key vigil-status-mode-map (kbd "h") #'vigil-menu)
(define-key vigil-status-mode-map (kbd "RET") #'vigil-status-act)
(define-key vigil-status-mode-map (kbd "TAB") #'vigil-review-toggle)
(define-key vigil-status-mode-map (kbd "<backtab>") #'vigil-review-toggle-all)
(define-key vigil-status-mode-map (kbd "o") #'vigil-status-visit)
(define-key vigil-status-mode-map (kbd "l") #'vigil-status-show-changes)
(define-key vigil-status-mode-map (kbd "v") #'vigil-status-toggle-detail)
(define-key vigil-status-mode-map (kbd "L") #'vigil-status-toggle-looks)
(define-key vigil-status-mode-map (kbd "q") #'vigil-status-quit)
(define-key vigil-status-mode-map (kbd "F") #'vigil-status-toggle-follow)
(define-key vigil-status-mode-map (kbd "T") #'vigil-status-toggle-since)
(define-key vigil-status-mode-map (kbd "w") #'vigil-status-copy)
(define-key vigil-status-mode-map (kbd "d") #'vigil-status-diff)
(define-key vigil-status-mode-map (kbd "D") #'vigil-status-by-duration)
(define-key vigil-status-mode-map (kbd "n") #'next-line)
(define-key vigil-status-mode-map (kbd "p") #'previous-line)
(define-key vigil-status-mode-map (kbd "M-n") #'vigil-status-next-heading)
(define-key vigil-status-mode-map (kbd "M-p") #'vigil-status-previous-heading)
(define-key vigil-status-mode-map (kbd "g") #'vigil-status-refresh)

(define-derived-mode vigil-status-mode special-mode "Vigil"
  "A session, and every way of looking at it.
\\<vigil-status-mode-map>Five views: \\[vigil-status-show-status] its status, \\[vigil-status-show-prompts] its prompts and what each led to,
\\[vigil-status-show-answers] its replies alone, \\[vigil-status-show-commands] its commands and how long they took, \\[vigil-status-show-build] its
prompts among the repository's commits.  \\[vigil-menu] shows these and the rest of
vigil in a menu.

\\[vigil-status-act] opens what is at point: a call, a commit, a prompt.  \\[vigil-review-toggle] folds and
unfolds, \\[vigil-status-copy] copies the prompt or reply at point, \\[vigil-status-diff] shows what changed
after a prompt, and \\[vigil-status-refresh] reads the session again."
  (vigil-ui-fit #'vigil-status--render)
  (setq vigil-status--detail vigil-status-detail)
  (add-hook 'post-command-hook #'vigil-status--detail-sync nil t)
  (add-hook 'kill-buffer-hook #'vigil-status--unwatch nil t)
  (add-hook 'kill-buffer-hook #'vigil-status--detail-close nil t))

(defvar vigil-status-detail-mode-map (make-sparse-keymap)
  "Keys of the buffer beside a session's.")

(define-key vigil-status-detail-mode-map (kbd "RET") #'vigil-status-act)
(define-key vigil-status-detail-mode-map (kbd "o") #'vigil-status-visit)
(define-key vigil-status-detail-mode-map (kbd "w") #'vigil-status-copy)
(define-key vigil-status-detail-mode-map (kbd "n") #'next-line)
(define-key vigil-status-detail-mode-map (kbd "p") #'previous-line)

(define-derived-mode vigil-status-detail-mode special-mode "Vigil detail"
  "What is at point in a session's buffer, in full, beside it.
\\<vigil-status-detail-mode-map>It follows point there.  \\[vigil-status-act] opens what is at point here: a call, or a
line of a diff in its file.  \\[vigil-status-copy] copies the prompt or reply at point.
\\[quit-window] leaves it."
  (vigil-ui-fit #'vigil-status--detail-render))

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
      (vigil-status--watch))
    (pop-to-buffer buffer)
    ;; Drawn once it shows, so that it is laid out to its window.
    (with-current-buffer buffer
      (vigil-status--render)
      (vigil-status--detail-sync))
    buffer))

;;;###autoload
(defun vigil-live (session)
  "Show the files SESSION is changing now, and what is changing in each.
Read again as its agent works, and following the last change.  In an
agent's buffer, that agent's session; elsewhere, or with a prefix argument,
one asked for."
  (interactive (list (vigil-status--read-session current-prefix-arg)))
  (with-current-buffer (vigil session)
    (vigil-status-show-changes)))

(provide 'vigil-status)
;;; vigil-status.el ends here
