;;; vigil.el --- An agent's tool calls, to inspect and to review -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (cooked "1.0"))
;; Keywords: tools, processes

;;; Commentary:

;; What an agent did, shown the way Emacs shows things: every command it ran
;; and every file it changed, one key away.
;;
;; Claude Code reports each tool call to a hook, before and after it runs, and
;; likewise each prompt, subagent, session start and the reply ending a turn.
;; `vigil install-hooks' (bin/vigil) puts `vigil hook' on those events in
;; Claude Code's settings, and `vigil hook' writes each report, as Claude Code
;; wrote it, to a file of its own under `vigil-directory'/<session>/ -- for an
;; agent running in one of cooked's hosted sessions, which is told the
;; session's name (COOKED_HOST_SESSION).  A buffer attached to that session
;; has the same name in `cooked-host-name', and that is the whole of how the
;; two find each other: nothing here knows what started the session.
;;
;; This file is the half that needs no terminal.  For each such buffer it
;; watches the session's directory and:
;;
;; - inspects a call in a small frame over the selected one (cooked-popup.el):
;;   a command highlighted as shell, with what it printed; an edit as a diff,
;;   in `diff-mode'.  There, `]' and `[' step to the next and previous call,
;;   `v' visits the file an edit changed, and `q' closes it.
;;   A command is laid out to be read (vigil-command.el): long chains broken
;;   before their operators, the Python in `python3 -c' or a heredoc taken
;;   out and highlighted, laid out by ruff; `e' says what each program and
;;   option is, from the manuals here, and `t' shows it as it was given.
;;   A command still running is shown as it prints, where the agent runs its
;;   commands through bin/vigil-shell (`vigil install-shell') and cooked keeps
;;   them (cooked-run.el); `r' shows that for a command that has finished.
;; - shows everything that has entered the agent's context in `vigil-context':
;;   prompts, every call with its full result, subagents' tasks and results
;;   with their calls folded under them, session starts and the reply ending
;;   each turn -- one heading each, TAB to unfold, RET to inspect.  It also
;;   says what hooks do not report, and so what is not there.
;; - offers the prompts given to agents on this machine, to give again
;;   (`vigil-prompts').
;;
;; vigil-transcript.el is the other half: where each call shows in the
;; agent's own terminal, marked there, and the conversation with the work
;; folded away.  vigil-archive.el reads the archive `vigil hook' keeps of
;; every session.
;;
;; Subagents are tied together only by what the reports say: every event from
;; inside one carries its `agent_id', `SubagentStart' and `SubagentStop' carry
;; it too, and the Agent call that launched it names it in its result
;; (`agentId').  A foreground subagent's Agent call has no result until the
;; subagent is done, so until then the subagent is shown as a group of its
;; own, and joins its Agent call when that result names it.  Nothing is
;; guessed.
;;
;; A report is data.  It is parsed as JSON and shown; nothing in it is ever
;; evaluated, and the frames showing it are read-only.  The reports stay
;; where `vigil hook' wrote them, in a directory of the user's own: nothing
;; here sends anything anywhere.
;;
;;   (require 'vigil)
;;   (vigil-setup)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'tabulated-list)
(require 'ansi-color)
(require 'diff-mode)
(require 'cooked-popup)
(require 'json)
(require 'outline)
(require 'vigil-base)
(require 'vigil-command)
(require 'vigil-pi)

(autoload 'vigil-running "vigil-running"
  "List the commands agents started that are still going, and what they are doing."
  t)
(autoload 'vigil-turn "vigil-turn"
  "Show the turn of the call nearest point, call by call, and that call in it."
  t)
(autoload 'vigil "vigil-status"
  "Show a session, and every way of looking at it."
  t)
(autoload 'vigil-live "vigil-status"
  "Show the files a session is changing now, and what is changing in each."
  t)
(autoload 'vigil-menu "vigil-status"
  "Every way of looking at a session, and the rest of vigil."
  t)
(autoload 'vigil-review "vigil-review"
  "Show what a session built, against what was there when it began."
  t)

(declare-function cooked-paste-string "cooked-keys")
(declare-function cooked-popup-showing-p "cooked-popup")
(declare-function cooked-runs "cooked-run")
(declare-function cooked-run-buffer "cooked-run")
(defvar cooked-host-name)
(defvar cooked-host-attach-hook)

(defvar vigil-changed-hook nil
  "Run in an agent's buffer when new reports from its session have been read.")

(defgroup vigil nil
  "An agent's tool calls, to inspect and to review."
  :group 'tools
  :prefix "vigil-")

(defcustom vigil-directory (vigil-base-data-directory "records")
  "Where `vigil hook' keeps each session's reports.
The program's VIGIL_RECORDS_DIR: a directory for each session, named for it."
  :type 'directory)

;;;; Calls

(cl-defstruct (vigil-call (:constructor vigil-call--make) (:copier nil))
  "One tool call, as its reports describe it."
  id name input response cwd start end duration
  (context nil :documentation "The tokens of context it was made in, if its report says.")
  (agent nil :documentation "The id of the subagent it was made by, if any.")
  (subagent nil :documentation "For a call that launched one, its subagent.")
  (annotation nil :documentation "Its mark in the conversation, if found.")
  (tries 0 :documentation "How many times its line has been looked for.")
  (unreadable nil :documentation "Whether its report could not be parsed."))

(cl-defstruct (vigil-subagent (:constructor vigil-subagent--make) (:copier nil))
  "A subagent, as its own events and the calls it made describe it."
  id type start end result transcript
  (call nil :documentation "The Agent call that launched it, once reported.")
  (interrupted nil :documentation "Whether its agent, waiting for it, went on
without it: was prompted, or replied, with nothing yet heard of its end.")
  (calls nil :documentation "The calls it made, oldest first."))

(cl-defstruct (vigil--prompt (:constructor vigil--prompt-make)
                                     (:copier nil))
  "A prompt the agent was given."
  text time)

(cl-defstruct (vigil-edit (:constructor vigil-edit--make) (:copier nil))
  "A file as one call left it, and as it was before.
BEFORE and AFTER are the whole text, or nil where it is not known: the
report of an edit has the file as it was before, and what it was turned into
is worked out here.  Where nothing touched the file between two edits, the
first's AFTER is the second's BEFORE, the same string, kept once."
  call before after)

(defvar vigil-call-changed-function nil
  "A function that says which files a call that is no edit changed.
Called with the call; gives their names, as the repository names them, or
nil.  A command's, from the snapshots kept around it: see vigil-effects.el.")

(defvar vigil-call-body-functions nil
  "Functions that add to what is shown of a call being inspected.
Each is called with the call, at the end of what is shown of it so far, and
inserts what it has to add, or nothing.")

(defun vigil--call-when (call)
  "When CALL was done; or, never reported done, when it began."
  (or (vigil-call-end call) (vigil-call-start call) 0))

(defun vigil--changed-note (call)
  "A few words on the files CALL changed, or nil if it is not known to have changed any."
  (when-let* ((names (and vigil-call-changed-function
                          (funcall vigil-call-changed-function call))))
    (concat "changed " (string-join (seq-take names 2) ", ")
            (if (cddr names) (format " and %d more" (- (length names) 2)) ""))))

(defvar-local vigil--edits nil
  "This agent's edits by the file's true name (`file-truename'): a hash
table of lists of `vigil-edit', oldest first.")

(defvar vigil-edits-made 0
  "How many times any agent's edits have changed: one more for each edit
taken, and for each agent's record started afresh.")

(defvar-local vigil--prompts nil
  "The prompts this agent has been given, oldest first.")

(defvar-local vigil--notes nil
  "Session starts and the replies that ended turns, oldest first.
Each a plist: :time, :kind (`session' or `reply'), :text.")

(defvar-local vigil--transcript-read 0
  "In a buffer holding a transcript: how many bytes of it were read.")

(defvar-local vigil--transcript nil
  "The transcript the reports name: Claude Code's own record of the session.")

(defvar-local vigil--subagents nil
  "This agent buffer's subagents by id: a hash table.")

(defvar-local vigil--calls nil
  "This agent buffer's calls by id: a hash table.")

(defvar-local vigil--order nil
  "This agent buffer's calls, oldest first.")

(defvar-local vigil--seen nil
  "Report files already read, as a hash table.")

(defvar-local vigil--watch nil
  "The `file-notify' descriptor watching this agent's reports.")

(defvar-local vigil--timer nil
  "The timer that reads new reports, if one is due.")

(defun vigil--session-name (&optional buffer)
  "The name of the hosted session BUFFER is attached to, default the current one.
Nil where it is attached to none, or cooked's host is not there to say."
  (when-let* (((boundp 'cooked-host-name))
              (name (buffer-local-value 'cooked-host-name (or buffer (current-buffer))))
              ((stringp name)))
    name))

(defun vigil--agent-directory (&optional buffer)
  "The directory of reports for the agent of BUFFER, default the current one."
  (when-let* ((name (vigil--session-name buffer))
              ((not (string-match-p "/" name))))
    (expand-file-name name vigil-directory)))

(defun vigil--subagent (id)
  "The subagent ID, made if this is the first that is heard of it."
  (or (gethash id vigil--subagents)
      (puthash id (vigil-subagent--make :id id) vigil--subagents)))

(defun vigil--launcher-p (call)
  "Whether CALL launches a subagent."
  (member (vigil-call-name call) '("Agent" "Task")))

(defun vigil--link (subagent call)
  "Make CALL the Agent call that launched SUBAGENT, as CALL's result says."
  (setf (vigil-subagent-call subagent) call
        (vigil-call-subagent call) subagent))

(defun vigil--subagent-background-p (subagent)
  "Whether SUBAGENT's agent did not wait for it, as its launching call says."
  (let* ((call (vigil-subagent-call subagent))
         (response (and call (vigil-call-response call))))
    (and (consp response)
         (equal (alist-get 'status response) "async_launched"))))

(defun vigil--leave-subagents ()
  "Mark this buffer's subagents that were waited for and are not done.
Called when their agent is prompted, or replies: it waits for them no more,
so they were interrupted, and would otherwise be shown running for good.
One that is heard of again is unmarked."
  (when vigil--subagents
    (maphash (lambda (_id subagent)
               (unless (or (vigil-subagent-end subagent)
                           (vigil--subagent-background-p subagent))
                 (setf (vigil-subagent-interrupted subagent) t)))
             vigil--subagents)))

(defun vigil--take-subagent-event (report event time)
  "Read REPORT, a SubagentStart or SubagentStop EVENT seen at TIME."
  (let ((id (alist-get 'agent_id report)))
    (when (stringp id)
      (let ((subagent (vigil--subagent id)))
        (setf (vigil-subagent-interrupted subagent) nil
              (vigil-subagent-type subagent)
              (or (alist-get 'agent_type report) (vigil-subagent-type subagent)))
        (if (equal event "SubagentStart")
            (setf (vigil-subagent-start subagent) time)
          (setf (vigil-subagent-end subagent) time
                (vigil-subagent-result subagent)
                (alist-get 'last_assistant_message report)
                (vigil-subagent-transcript subagent)
                (alist-get 'agent_transcript_path report))
          (unless (vigil-subagent-start subagent)
            (setf (vigil-subagent-start subagent) time)))))))

(defun vigil--in-our-words (report)
  "REPORT as the rest of vigil reads one: in Claude Code's words.
An agent that is not Claude Code says which it is; see vigil-pi.el."
  (if (equal (alist-get 'agent report) "pi")
      (vigil-pi-report report)
    report))

(defun vigil--write-patch (call response)
  "RESPONSE, what CALL gave back, with the patch a Write made if it lacks one.
Where it says only what the file was before: an agent whose Write reports
nothing of what it replaced."
  (if-let* (((equal (vigil-call-name call) "Write"))
            ((consp response))
            ((not (alist-get 'structuredPatch response)))
            ((not (equal (alist-get 'type response) "create")))
            (before (alist-get 'originalFile response))
            ((stringp before))
            (after (alist-get 'content (vigil-call-input call)))
            ((stringp after))
            (patch (vigil-pi-patch (vigil--diff-output before after "-u"))))
      (cons (cons 'structuredPatch patch) response)
    response))

(defun vigil--take (file)
  "Read the report FILE into this buffer's calls and subagents."
  (vigil--take-report (vigil-base-json-file file)
                              (vigil-base-report-time file)
                              (file-name-nondirectory file)))

(defun vigil--take-report (report time name)
  "Read REPORT, an event seen at TIME, into this buffer's state.
NAME tells an unreadable report (REPORT nil) apart from others."
  (let* ((report (vigil-base-settled (vigil--in-our-words report)))
         (event (alist-get 'hook_event_name report)))
    (when (and (stringp (alist-get 'transcript_path report))
               (null (alist-get 'agent_id report)))
      (setq vigil--transcript (alist-get 'transcript_path report)))
    (cond
     ((member event '("SubagentStart" "SubagentStop"))
      (vigil--take-subagent-event report event time))
     ((and (member event '("SessionStart" "Stop")) (null (alist-get 'agent_id report)))
      (vigil--leave-subagents)
      (setq vigil--notes
            (nconc vigil--notes
                   (list (list :time time
                               :kind (if (equal event "Stop") 'reply 'session)
                               :text (if (equal event "Stop")
                                         (alist-get 'last_assistant_message report)
                                       (alist-get 'source report)))))))
     ((equal event "UserPromptSubmit")
      (let ((text (alist-get 'prompt report)))
        (when (and (stringp text) (null (alist-get 'agent_id report)))
          (vigil--leave-subagents)
          (setq vigil--prompts
                (nconc vigil--prompts
                       (list (vigil--prompt-make :text text :time time)))))))
     ;; A tool call, or a file that did not read, which is shown as one.
     ;; Any other event is nothing to show here.
     ((or (null report) (member event '("PreToolUse" "PostToolUse")))
      (vigil--take-call report name time event)))))

(defun vigil--take-call (report name time event)
  "Read REPORT, the tool call EVENT named NAME at TIME, or nil if unreadable."
  (let* ((id (or (and report (let ((id (alist-get 'tool_use_id report)))
                               (and (stringp id) id)))
                 name))
         (call (or (gethash id vigil--calls)
                   (let ((call (vigil-call--make :id id :start time)))
                     (puthash id call vigil--calls)
                     (setq vigil--order
                           (nconc vigil--order (list call)))
                     call))))
    (if (null report)
        (setf (vigil-call-unreadable call) t
              (vigil-call-name call) (or (vigil-call-name call) "?"))
      (setf (vigil-call-name call) (or (alist-get 'tool_name report)
                                         (vigil-call-name call) "?")
            (vigil-call-input call) (or (alist-get 'tool_input report)
                                          (vigil-call-input call))
            (vigil-call-cwd call) (or (alist-get 'cwd report)
                                        (vigil-call-cwd call))
            (vigil-call-context call) (or (let ((tokens (alist-get 'context_tokens report)))
                                            (and (numberp tokens) tokens))
                                          (vigil-call-context call)))
      (let ((agent (alist-get 'agent_id report)))
        (when (and (stringp agent) (not (vigil-call-agent call)))
          (let ((subagent (vigil--subagent agent)))
            (setf (vigil-call-agent call) agent
                  (vigil-subagent-interrupted subagent) nil
                  (vigil-subagent-type subagent)
                  (or (vigil-subagent-type subagent) (alist-get 'agent_type report))
                  (vigil-subagent-calls subagent)
                  (nconc (vigil-subagent-calls subagent) (list call)))
            (unless (vigil-subagent-start subagent)
              (setf (vigil-subagent-start subagent) time)))))
      (if (equal event "PreToolUse")
          (setf (vigil-call-start call) (min time (vigil-call-start call)))
        (let ((response (vigil--write-patch call (alist-get 'tool_response report))))
          (vigil--take-edit call response)
          ;; The whole file before an edit is not shown, and can be large:
          ;; what is needed of it is kept by `vigil--take-edit'.
          (when (consp response)
            (setq response (assq-delete-all 'originalFile (copy-sequence response))))
          (setf (vigil-call-response call) (or response t)
                (vigil-call-end call) time
                (vigil-call-duration call)
                (let ((ms (alist-get 'duration_ms report)))
                  (and (numberp ms) (/ ms 1000.0))))
          (let ((launched (and (consp response) (alist-get 'agentId response))))
            (when (and (stringp launched) (vigil--launcher-p call))
              (vigil--link (vigil--subagent launched) call))))))
    call))

(defun vigil--scan (buffer)
  "Read the reports BUFFER's agent has written since the last scan."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq vigil--timer nil)
      (when-let* ((directory (vigil--agent-directory))
                  ((file-directory-p directory)))
        (let* ((new (cl-remove-if (lambda (file) (gethash file vigil--seen))
                                  (directory-files directory t "\\.json\\'" t)))
               (new (sort new (lambda (a b) (< (vigil-base-report-time a)
                                               (vigil-base-report-time b))))))
          (when new
            (dolist (file new)
              (puthash file t vigil--seen)
              (vigil--take file))
            (run-hooks 'vigil-changed-hook)
            (vigil--refresh-context buffer)))))))

(defun vigil--schedule (buffer &optional delay)
  "Scan BUFFER's reports after DELAY seconds, unless a scan is already due."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless vigil--timer
        (setq vigil--timer
              (run-with-timer (or delay 0.05) nil #'vigil--scan buffer))))))

(defun vigil--relative (file cwd)
  "FILE relative to CWD when it is under it, else FILE."
  (let ((root (and (stringp cwd) (file-name-as-directory (expand-file-name cwd)))))
    (if (and root (stringp file) (string-prefix-p root (expand-file-name file)))
        (substring (expand-file-name file) (length root))
      file)))

(defun vigil--clip (text n)
  "The first line of TEXT, trimmed, and at most N characters of it."
  (when (stringp text)
    (let ((line (string-trim (car (split-string (string-trim text) "\n")))))
      (and (> (length line) 0)
           (substring line 0 (min n (length line)))))))

;;;; Showing a call

(defun vigil--subagent-status (subagent)
  "A word for how SUBAGENT went."
  (let* ((call (vigil-subagent-call subagent))
         (response (and call (consp (vigil-call-response call))
                        (vigil-call-response call))))
    (cond ((alist-get 'is_error response) "failed")
          ((alist-get 'interrupted response) "interrupted")
          ((vigil-subagent-end subagent) "done")
          ((equal (alist-get 'status response) "completed") "done")
          ((vigil-subagent-interrupted subagent) "interrupted")
          (t "running"))))

(defun vigil--subagent-progress (subagent)
  "How far SUBAGENT has got, while it runs: \"7 calls  ·  Bash pytest -x\".
How many calls it has made, and what the last is about.  Nil once it is no
longer running, or before its first call."
  (when-let* (((equal (vigil--subagent-status subagent) "running"))
              (calls (vigil-subagent-calls subagent))
              (last (car (last calls))))
    (format "%d call%s  ·  %s"
            (length calls) (if (cdr calls) "s" "")
            (string-trim (format "%s %s" (vigil-call-name last)
                                 (or (vigil--clip (vigil--summary last) 60) ""))))))

(defun vigil--state (item)
  "How ITEM, a call or a subagent, went and how long it took, for a heading.
With how far it has got, for a subagent still running."
  (let* ((subagent (if (vigil-subagent-p item) item (vigil-call-subagent item)))
         (progress (and subagent (vigil--subagent-progress subagent))))
    (concat (if (vigil-subagent-p item)
                (format "  ·  %s %s" (vigil--subagent-status item)
                        (vigil--subagent-took item))
              (format "  ·  %s %s" (vigil--status item) (vigil--took item)))
            (if progress (concat " ·  " progress) ""))))

(defun vigil--subagent-took (subagent)
  "How long SUBAGENT took, as text."
  (let* ((call (vigil-subagent-call subagent))
         (response (and call (consp (vigil-call-response call))
                        (vigil-call-response call)))
         (ms (alist-get 'totalDurationMs response))
         (start (vigil-subagent-start subagent))
         (end (vigil-subagent-end subagent)))
    (cond ((numberp ms) (format "%.1fs" (/ ms 1000.0)))
          ((and start end) (format "%.1fs" (- end start)))
          (t ""))))

(defun vigil--status (call)
  "A word for how CALL went."
  (let ((response (vigil-call-response call)))
    (cond ((vigil-call-unreadable call) "unreadable")
          ((vigil-call-subagent call)
           (vigil--subagent-status (vigil-call-subagent call)))
          ((null response) "running")
          ((and (consp response) (alist-get 'interrupted response)) "interrupted")
          ((and (consp response) (numberp (alist-get 'exit_code response))
                (/= 0 (alist-get 'exit_code response)))
           (format "exit %d" (alist-get 'exit_code response)))
          ((and (consp response) (alist-get 'is_error response)) "failed")
          (t "done"))))

(defun vigil--took (call)
  "How long CALL took, as text."
  (if (vigil-call-subagent call)
      (vigil--subagent-took (vigil-call-subagent call))
    (let ((seconds (or (vigil-call-duration call)
                       (and (vigil-call-end call) (vigil-call-start call)
                            (- (vigil-call-end call) (vigil-call-start call))))))
      (if seconds (format "%.1fs" seconds) ""))))

(defun vigil--summary (call)
  "What CALL was about, in a few words."
  (let ((input (vigil-call-input call)))
    (or (vigil--clip (alist-get 'command input) 200)
        (let ((path (or (alist-get 'file_path input) (alist-get 'notebook_path input))))
          (and (stringp path) (vigil--relative path (vigil-call-cwd call))))
        (vigil--clip (alist-get 'pattern input) 200)
        (vigil--clip (alist-get 'url input) 200)
        (vigil--clip (alist-get 'query input) 200)
        (vigil--clip (alist-get 'subject input) 200)
        (and (alist-get 'todos input)
             (format "%d todos" (length (alist-get 'todos input))))
        (vigil--clip (alist-get 'description input) 200)
        (vigil--clip (alist-get 'prompt input) 200)
        "")))

(defun vigil--base64-p (text)
  "Whether TEXT is a long run of base64: an image or a file, not words."
  (and (stringp text)
       (> (length text) 1000)
       ;; Asked the other way round: no character outside base64's.  A
       ;; regexp matching the whole of a long run could overflow.
       (not (string-match-p "[^A-Za-z0-9+/=\n]" text))))

(defun vigil--jsonable (value)
  "VALUE, read from a report with arrays as lists, with its arrays as vectors.
What `json-serialize' needs to write it back: a list there is an object.
For showing: a long run of base64 is said, not shown."
  (cond ((and (consp value) (consp (car value)) (symbolp (caar value)))
         (mapcar (lambda (pair) (cons (car pair) (vigil--jsonable (cdr pair))))
                 value))
        ((consp value) (vconcat (mapcar #'vigil--jsonable value)))
        ((vigil--base64-p value)
         (format "<base64: %d bytes, not shown>" (/ (* 3 (length value)) 4)))
        (t value)))

(defun vigil--json (value)
  "VALUE, read from a report, as indented JSON text."
  (with-temp-buffer
    (insert (json-serialize (vigil--jsonable value)
                            :null-object nil :false-object :false))
    (ignore-errors (json-pretty-print-buffer))
    (buffer-string)))

(defun vigil--lines (text prefix)
  "TEXT's lines, each after PREFIX, as one string ending in a newline."
  (if (or (null text) (equal text ""))
      ""
    (concat (mapconcat (lambda (line) (concat prefix line))
                       (split-string (string-remove-suffix "\n" text) "\n")
                       "\n")
            "\n")))

(defun vigil-diff (call)
  "The unified diff of the edit CALL made, as text, or nil if it made none."
  (let* ((input (vigil-call-input call))
         (response (and (consp (vigil-call-response call)) (vigil-call-response call)))
         ;; One that was refused changed nothing, whatever it asked for.
         (input (and (not (alist-get 'is_error response)) input))
         (file (or (alist-get 'file_path input) (alist-get 'filePath response) "file"))
         (name (vigil--relative file (vigil-call-cwd call)))
         (patch (alist-get 'structuredPatch response))
         (created (or (equal (alist-get 'type response) "create")
                      (and (equal (vigil-call-name call) "Write") (null response)))))
    (cond
     ((and (consp patch) (cl-every #'consp patch))
      (concat (format "--- a/%s\n+++ b/%s\n" name name)
              (mapconcat
               (lambda (hunk)
                 (concat (format "@@ -%s,%s +%s,%s @@\n"
                                 (alist-get 'oldStart hunk) (alist-get 'oldLines hunk)
                                 (alist-get 'newStart hunk) (alist-get 'newLines hunk))
                         (mapconcat #'identity (alist-get 'lines hunk) "\n")
                         "\n"))
               patch "")))
     ((and created (stringp (alist-get 'content input)))
      (let ((body (vigil--lines (alist-get 'content input) "+")))
        (format "--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n%s"
                name (cl-count ?\n body) body)))
     (t
      ;; No patch reported: the replacement asked for, without line numbers.
      (let ((edits (or (alist-get 'edits input)
                       (and (alist-get 'old_string input) (list input)))))
        (when edits
          (concat (format "--- a/%s\n+++ b/%s\n" name name)
                  (mapconcat
                   (lambda (edit)
                     (let ((old (vigil--lines (alist-get 'old_string edit) "-"))
                           (new (vigil--lines (alist-get 'new_string edit) "+")))
                       (format "@@ -1,%d +1,%d @@\n%s%s"
                               (cl-count ?\n old) (cl-count ?\n new) old new)))
                   edits ""))))))))

;;;; Edits: each file as the agent left it

;; Each edit's report has the file as it was before (`originalFile') and the
;; change (the replacement asked for, and the patch it made).  From those, the
;; file as the edit left it is worked out, and kept with it: enough to say,
;; later, which call wrote each line of a file (vigil-edits.el), and what a
;; turn changed altogether.

(defcustom vigil-diff-program "diff"
  "The program that compares two versions of a file, line by line.
POSIX diff: it is given -U0 or -u, a file and `-' for its standard input."
  :type 'string)

(defun vigil--text-lines (text)
  "TEXT as a list of its lines, with no empty one after a final newline."
  (if (or (null text) (string-empty-p text))
      nil
    (let ((lines (split-string text "\n")))
      (if (string-suffix-p "\n" text) (butlast lines) lines))))

(defun vigil--replace (text old new all)
  "TEXT with OLD replaced by NEW: the first OLD, or ALL of them; nil if none."
  (when (and (stringp old) (stringp new) (not (string-empty-p old)))
    (when-let* ((at (string-search old text)))
      (if all
          (string-replace old new text)
        (concat (substring text 0 at) new (substring text (+ at (length old))))))))

(defun vigil--apply-hunks (old owners hunks owner)
  "Lines OLD, with OWNERS one per line, changed as HUNKS say: (NEW . NEW-OWNERS).
HUNKS are (START . LINES), in the order of the lines they change, as a
unified diff has them:
START is the first old line the hunk covers, counted from 1, or where it has
none, the line it goes after; LINES are prefixed with a space, `-' or `+'.
Each line HUNKS add is owned by OWNER; the rest keep theirs.  Nil if HUNKS
do not fit OLD."
  (let ((old (vconcat old))
        (owners (vconcat owners))
        (i 0) new new-owners)
    (catch 'misfit
      (dolist (hunk hunks)
        (let* ((lines (cdr hunk))
               (covers (cl-count-if (lambda (line)
                                      (or (string-empty-p line)
                                          (memq (aref line 0) '(?\s ?-))))
                                    lines))
               (at (if (zerop covers) (car hunk) (1- (car hunk)))))
          (unless (and (integerp at) (<= i at (length old)))
            (throw 'misfit nil))
          (while (< i at)
            (push (aref old i) new)
            (push (aref owners i) new-owners)
            (cl-incf i))
          (dolist (line lines)
            (let ((kind (if (string-empty-p line) ?\s (aref line 0)))
                  (text (if (string-empty-p line) "" (substring line 1))))
              (pcase kind
                ((or ?\s ?-)
                 (unless (and (< i (length old)) (equal (aref old i) text))
                   (throw 'misfit nil))
                 (when (eq kind ?\s)
                   (push text new)
                   (push (aref owners i) new-owners))
                 (cl-incf i))
                (?+ (push text new)
                    (push owner new-owners))
                ;; "\ No newline at end of file", and anything else: not a line.
                (_ nil))))))
      (while (< i (length old))
        (push (aref old i) new)
        (push (aref owners i) new-owners)
        (cl-incf i))
      (cons (nreverse new) (nreverse new-owners)))))

(defun vigil--diff-output (old new &rest arguments)
  "What `vigil-diff-program' says, given ARGUMENTS, of the texts OLD and NEW.
Nil if it could not say: it failed, or is not there.  OLD is written to a
file only its owner can read, deleted after; NEW is given on standard input."
  (let ((file (with-file-modes #o600 (make-temp-file "vigil-diff"))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region old nil file nil 'silent))
          (with-temp-buffer
            (insert new)
            (let* ((coding-system-for-read 'utf-8-unix)
                   (coding-system-for-write 'utf-8-unix)
                   (status (ignore-errors
                             (apply #'call-process-region (point-min) (point-max)
                                    vigil-diff-program t t nil
                                    (append arguments (list "--" file "-"))))))
              ;; 0, the same; 1, different; anything else, trouble.
              (and (memq status '(0 1)) (buffer-string)))))
      (delete-file file))))

(defun vigil--join-lines (lines)
  "LINES as text, each ended by a newline."
  (mapconcat (lambda (line) (concat line "\n")) lines ""))

(defun vigil--line-hunks (old new)
  "Hunks that make the lines NEW of the lines OLD, as `vigil--apply-hunks' takes.
What the two begin and end with alike is set aside first; only where both
still have lines in between is `vigil-diff-program' asked, and if it cannot
say -- or says what does not make NEW of OLD -- all of those are taken to
have changed.  They always make NEW of OLD."
  (let* ((old-n (length old)) (new-n (length new))
         (head 0) (tail 0))
    (let ((a old) (b new))
      (while (and a b (equal (car a) (car b)))
        (setq a (cdr a) b (cdr b))
        (cl-incf head)))
    (let ((a (reverse (nthcdr head old))) (b (reverse (nthcdr head new))))
      (while (and a b (equal (car a) (car b)))
        (setq a (cdr a) b (cdr b))
        (cl-incf tail)))
    (let ((gone (cl-subseq old head (- old-n tail)))
          (came (cl-subseq new head (- new-n tail))))
      (cond
       ((and (null gone) (null came)) nil)
       ((null gone)
        (list (cons head (mapcar (lambda (line) (concat "+" line)) came))))
       ((null came)
        (list (cons (1+ head) (mapcar (lambda (line) (concat "-" line)) gone))))
       (t
        (let* ((diff (vigil--diff-output (vigil--join-lines gone)
                                         (vigil--join-lines came)
                                         "-U0"))
               (hunks (and diff (vigil--parse-hunks diff)))
               (fit (and hunks (vigil--apply-hunks gone (make-list (length gone) nil)
                                                   hunks nil))))
          (if (and fit (equal (car fit) came))
              (mapcar (lambda (hunk) (cons (+ head (car hunk)) (cdr hunk))) hunks)
            ;; No diff to be had, or one that does not say this: all changed.
            (list (cons (1+ head)
                        (append (mapcar (lambda (line) (concat "-" line)) gone)
                                (mapcar (lambda (line) (concat "+" line)) came)))))))))))

(defun vigil--parse-hunks (diff)
  "The hunks of DIFF, a unified diff as text, as `vigil--apply-hunks' takes them."
  (let (hunks hunk)
    (dolist (line (split-string diff "\n"))
      (cond
       ((string-match "\\`@@ -\\([0-9]+\\)" line)
        (when hunk (push (nreverse hunk) hunks))
        (setq hunk (list (string-to-number (match-string 1 line)))))
       ((and hunk (string-match-p "\\`[-+ ]" line))
        (push line hunk))))
    (when hunk (push (nreverse hunk) hunks))
    (nreverse hunks)))

(defun vigil--patch-hunks (response)
  "The hunks of the patch RESPONSE reports, as `vigil--apply-hunks' takes them."
  (let ((patch (and (consp response) (alist-get 'structuredPatch response))))
    (when (and (consp patch) (cl-every #'consp patch))
      (mapcar (lambda (hunk)
                (cons (alist-get 'oldStart hunk)
                      (cl-remove-if-not #'stringp (alist-get 'lines hunk))))
              patch))))

(defun vigil--edit-after (call before response)
  "The text of CALL's file once it was done, from BEFORE and RESPONSE.
Nil where that cannot be worked out."
  (let ((input (vigil-call-input call)))
    (if (equal (vigil-call-name call) "Write")
        (let ((content (alist-get 'content input)))
          (and (stringp content) content))
      (when (stringp before)
        (or
         ;; The replacements asked for, made as Claude Code makes them.
         (let ((text before))
           (dolist (edit (or (alist-get 'edits input) (list input)) text)
             (setq text (and text
                             (vigil--replace text
                                             (alist-get 'old_string edit)
                                             (alist-get 'new_string edit)
                                             (alist-get 'replace_all edit))))))
         ;; Failing that -- what was asked for was matched loosely -- the
         ;; patch it reports.
         (when-let* ((hunks (vigil--patch-hunks response))
                     (lines (vigil--text-lines before))
                     (applied (vigil--apply-hunks lines (make-list (length lines) nil)
                                                  hunks nil)))
           (concat (string-join (car applied) "\n")
                   (if (string-suffix-p "\n" before) "\n" ""))))))))

(defun vigil--take-edit (call response)
  "Keep what CALL, a call that is done with RESPONSE, made of a file, if any."
  (when (and (member (vigil-call-name call) '("Edit" "Write" "MultiEdit"))
             (consp response)
             (not (alist-get 'is_error response)))
    (let* ((input (vigil-call-input call))
           (name (or (alist-get 'file_path input) (alist-get 'filePath response)))
           (file (and (stringp name)
                      (file-truename
                       (expand-file-name name (or (vigil-call-cwd call) "/")))))
           (original (alist-get 'originalFile response))
           ;; Unknown (nil) where the report was cut short, as a big one is.
           (before (cond ((stringp original) original)
                         ;; Made new, so nothing before it.
                         ((equal (alist-get 'type response) "create") "")))
           (previous (and file (car (last (gethash file vigil--edits))))))
      (when file
        ;; The same text as the last edit left it: keep it once.
        (when (and previous (equal before (vigil-edit-after previous)))
          (setq before (vigil-edit-after previous)))
        (puthash file
                 (nconc (gethash file vigil--edits)
                        (list (vigil-edit--make
                               :call call :before before
                               :after (vigil--edit-after call before response))))
                 vigil--edits)
        (cl-incf vigil-edits-made)))))

(defun vigil-edits-of (agent)
  "AGENT's edits, as a hash table of lists by file; see `vigil--edits'."
  (and (buffer-live-p agent) (buffer-local-value 'vigil--edits agent)))

(defvar-local vigil--popup-call nil "The call this buffer shows.")

(defvar-local vigil--popup-agent nil "The agent buffer the call is from.")

(defvar vigil-popup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "]") #'vigil-next-call)
    (define-key map (kbd "[") #'vigil-previous-call)
    (define-key map (kbd "r") #'vigil-show-run)
    (define-key map (kbd "e") #'vigil-toggle-explain)
    (define-key map (kbd "t") #'vigil-toggle-as-given)
    (define-key map (kbd "s") #'vigil-toggle-scripts)
    map)
  "Keys of a buffer inspecting a call, besides those of `cooked-popup-mode'.")

(define-minor-mode vigil-popup-mode
  "Keys for a buffer inspecting an agent's tool call.
With `cooked-popup-mode', whose \\`q' closes it and whose \\`v' visits the
file the call changed.
\\{vigil-popup-mode-map}"
  :lighter nil)

(define-derived-mode vigil-view-mode special-mode "Tool call"
  "Showing one of an agent's tool calls."
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  (setq truncate-lines nil)
  ;; A line too long for the frame goes on under its own indentation.
  (setq-local word-wrap t)
  (when (fboundp 'visual-wrap-prefix-mode)
    (visual-wrap-prefix-mode 1)))

(defun vigil--time (seconds)
  "SECONDS since the epoch as a time of day; with the day, if not today."
  (and (numberp seconds) (> seconds 0)
       (format-time-string (if (equal (format-time-string "%F" seconds)
                                      (format-time-string "%F"))
                               "%H:%M:%S"
                             "%b %e %H:%M:%S")
                           seconds)))

(defun vigil--for (seconds)
  "SECONDS, as how long something went or has gone: 42s, 3m05s, 2h10m."
  (let ((s (floor seconds)))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (% s 60)))
          (t (format "%dh%02dm" (/ s 3600) (% (/ s 60) 60))))))

(defun vigil--injected-p (text)
  "Whether TEXT is a prompt the agent gave itself, not one it was given.
A background task reporting back: it stays inside the turn it comes in."
  (and (stringp text) (string-prefix-p "<task-notification>" text)))

(defun vigil--user-prompts (prompts)
  "PROMPTS without those the agent gave itself: the ones that begin turns."
  (cl-remove-if (lambda (prompt) (vigil--injected-p (vigil--prompt-text prompt)))
                prompts))

(defun vigil--turn (time prompts)
  "Which turn something at TIME was in: how many of PROMPTS came before it.
Only prompts the agent was given count, not those it gave itself."
  (cl-count-if (lambda (prompt) (<= (or (vigil--prompt-time prompt) 0) time))
               (vigil--user-prompts prompts)))

(defun vigil--whereabouts (calls agent)
  "When CALLS, one or a run of them, ran, and how far into AGENT's conversation.
As pieces of a header line: the time the first began; the turn it was in
\(the prompts given before it, of all given so far); and its place among
the calls of that turn, and among all the agent's calls."
  (let* ((live (buffer-live-p agent))
         (order (and live (buffer-local-value 'vigil--order agent)))
         (prompts (and live (buffer-local-value 'vigil--prompts agent)))
         (start (vigil-call-start (car calls)))
         (turn (and start (vigil--turn start prompts)))
         (first (cl-position (car calls) order))
         (last (or (cl-position (car (last calls)) order) first))
         ;; The calls of the same turn, as positions in ORDER.
         (in-turn (and first turn
                       (cl-loop for call in order for i from 0
                                when (eql (vigil--turn (or (vigil-call-start call) 0)
                                                       prompts)
                                          turn)
                                collect i)))
         (span (lambda (a b n) (if (= a b) (format "%d/%d" a n) (format "%d–%d/%d" a b n)))))
    (delq nil
          (list (vigil--time start)
                (and turn (> turn 0)
                     (format "turn %d/%d" turn (length (vigil--user-prompts prompts))))
                (and first
                     (concat (if (= first last) "call " "calls ")
                             (if (and in-turn (> turn 0))
                                 (format "%s (%s)"
                                         (funcall span (1+ (cl-position first in-turn))
                                                  (1+ (or (cl-position last in-turn)
                                                          (cl-position first in-turn)))
                                                  (length in-turn))
                                         (funcall span (1+ first) (1+ last) (length order)))
                               (funcall span (1+ first) (1+ last) (length order)))))))))

(defcustom vigil-transcript-limit (* 256 1024 1024)
  "The biggest transcript read for the context of calls, in bytes.
A bigger one is not read, and its calls' context is not shown."
  :type 'integer
  :group 'vigil)

(defun vigil--forget-transcript ()
  "Let go of what was read of this buffer's transcripts, its subagents' too."
  (when (stringp vigil--transcript)
    (let ((prefix (concat " *vigil transcript "
                          (file-name-sans-extension vigil--transcript))))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p prefix (buffer-name buffer))
          (kill-buffer buffer))))))

(defun vigil--transcript-buffer (file)
  "A buffer holding FILE, a transcript, as far as it has been written.
Kept, and only what was written since read again, as a transcript grows.
Nil if FILE is over `vigil-transcript-limit'."
  (let ((size (file-attribute-size (file-attributes file))))
    (and (numberp size) (<= size vigil-transcript-limit)
         (vigil--transcript-read-into
          (get-buffer-create (concat " *vigil transcript " file "*")) file size))))

(defun vigil--transcript-read-into (buffer file size)
  "BUFFER, holding FILE's whole lines up to SIZE bytes, read as bytes.
Only what it did not hold yet is read; a line still being written is left
for the next time."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when (or (< size vigil--transcript-read) enable-multibyte-characters)
        (set-buffer-multibyte nil)
        (erase-buffer)
        (setq vigil--transcript-read 0))
      (when (> size vigil--transcript-read)
        (goto-char (point-max))
        (let ((start (point)))
          (insert-file-contents-literally file nil vigil--transcript-read size)
          (goto-char (point-max))
          (if (search-backward "\n" start t)
              (delete-region (1+ (point)) (point-max))
            (delete-region start (point-max)))
          (setq vigil--transcript-read (+ vigil--transcript-read
                                          (- (point-max) start)))))))
  buffer)

(defun vigil--context (call agent)
  "How many tokens of context AGENT's model had read when it made CALL.
What the request that made it was given, from scratch or from the cache,
as the call's own report says, or else as Claude Code's transcript has it;
nil where that is not known.  A subagent's call, its subagent's: in a
context of its own."
  (if (not (vigil-call-p call))
      (vigil--context-from-transcript call agent)
    ;; Found in the transcript once, and kept: every row of a turn asks,
    ;; each time it is drawn.
    (or (vigil-call-context call)
        (setf (vigil-call-context call)
              (vigil--context-from-transcript call agent)))))

(defun vigil--context-from-transcript (call agent)
  "The tokens of context AGENT's transcript says CALL was made in, or nil."
  (when-let* (((vigil-call-p call))
              (id (vigil-call-id call))
              ((stringp id))
              ((buffer-live-p agent))
              (main (buffer-local-value 'vigil--transcript agent))
              ((stringp main))
              (file (if-let* ((sub (vigil-call-agent call)))
                        (or (let ((subagent (gethash sub (buffer-local-value
                                                          'vigil--subagents agent))))
                              (and subagent (vigil-subagent-transcript subagent)))
                            (expand-file-name (format "subagents/agent-%s.jsonl" sub)
                                              (file-name-sans-extension main)))
                      main))
              ((file-readable-p file))
              (transcript (vigil--transcript-buffer file)))
    (with-current-buffer transcript
      (save-excursion
        (goto-char (point-max))
        ;; The call's id is in other entries too: the last that is the
        ;; model's message, with what its request used.
        (let ((needle (format "\"type\":\"tool_use\",\"id\":\"%s\"" id))
              (tokens nil))
          (while (and (not tokens) (search-backward needle nil t))
            (let* ((entry (ignore-errors
                            (json-parse-string
                             (decode-coding-string
                              (buffer-substring (line-beginning-position) (line-end-position))
                              'utf-8)
                             :object-type 'alist :null-object nil :false-object nil)))
                   (usage (and (equal (alist-get 'type entry) "assistant")
                               (alist-get 'usage (alist-get 'message entry)))))
              (when usage
                (setq tokens (+ (or (alist-get 'input_tokens usage) 0)
                                (or (alist-get 'cache_creation_input_tokens usage) 0)
                                (or (alist-get 'cache_read_input_tokens usage) 0))))))
          tokens)))))

(defun vigil--tokens (n)
  "N tokens, shortly: 950, 55k, 1.2M."
  (cond ((< n 1000) (format "%d" n))
        ((< n 1000000) (format "%dk" (round n 1000)))
        (t (format "%.1fM" (/ n 1e6)))))

(defun vigil--header (item calls agent)
  "The header line of a buffer showing ITEM, AGENT's: what it is, when and where.
CALLS are its calls -- one, a run of them, or none for a subagent alone.
Its keys are in the mode line, out of the way: see `vigil--footer'."
  (let* ((call (and (vigil-call-p item) item))
         (cwd (and calls (vigil-call-cwd (car calls))))
         (pieces
          (append
           (cond (call (list (vigil-call-name call)
                             (vigil--status call)
                             (let ((took (vigil--took call)))
                               (and (not (equal took "")) took))))
                 ((vigil--group-p item) (list (format "%d calls" (length item))))
                 (t (list "Subagent" (vigil--subagent-status item))))
           (and calls (vigil--whereabouts calls agent))
           (when-let* ((tokens (and call (vigil--context call agent))))
             (list (concat (vigil--tokens tokens) " context")))
           (and (stringp cwd) (list (abbreviate-file-name cwd))))))
    ;; A header line reads `%' as a construct of its own.
    (string-replace "%" "%%" (string-join (delq nil pieces) "  ·  "))))

(defun vigil--footer (item)
  "The mode line of a buffer showing ITEM: its keys."
  (concat " q close  ] next  [ previous  o conversation"
          (and (vigil-call-p item)
               (stringp (alist-get 'command (vigil-call-input item)))
               "  e explain  t as given  s scripts  r as it printed")))

(defun vigil--section (title)
  "Insert a section heading saying TITLE."
  (insert (propertize title 'face 'bold) "\n"))

(defun vigil--insert-json (value)
  "Insert VALUE, read from a report, as highlighted JSON."
  (insert (vigil-command-fontify (vigil--json value)
                                  (if (fboundp 'js-json-mode) #'js-json-mode #'js-mode))
          "\n"))

(defun vigil--insert-prose (text)
  "Insert TEXT, which is markdown, highlighted as such where that is possible."
  (insert (if (fboundp 'markdown-mode)
              (vigil-command-fontify text #'markdown-mode)
            text)
          "\n"))

(defun vigil--response-text (response)
  "The text a response carries, from its `content' blocks or its `result'."
  (let ((content (and (consp response) (alist-get 'content response))))
    (cond ((stringp content) content)
          ((consp content)
           (mapconcat (lambda (block)
                        (or (and (consp block) (alist-get 'text block)) ""))
                      content "\n"))
          ((stringp (alist-get 'result response)) (alist-get 'result response)))))

(defun vigil--colours (text)
  "TEXT with its terminal colours as faces, and the sequences for them gone."
  (with-temp-buffer
    (insert text)
    (let ((ansi-color-apply-face-function
           (lambda (beg end face)
             (when face (put-text-property beg end 'face face)))))
      (ansi-color-apply-on-region (point-min) (point-max)))
    (buffer-string)))

(defvar vigil-explain-commands nil
  "Whether a command being inspected says what its programs and options are.
Toggled with \\`e' there; see `vigil-command-explain'.")

(defvar vigil-commands-as-given nil
  "Whether a command being inspected is shown exactly as it was given.
Rather than laid out by `vigil-command-tidy'.  Toggled with \\`t' there.")

(defvar vigil-show-scripts t
  "Whether a command inspected is shown with the scripts it names.
The files as they are now, under the command; \\`s' turns it on and off.")

(defvar vigil--tidy nil
  "Whether commands are drawn laid out and explained, which takes shfmt.
Only in the frame inspecting calls: the context draws every call at once.")

(defun vigil--render-bash (input response &optional directory)
  "Insert a command, INPUT, and what it printed, RESPONSE.
Inspected, laid out and with the programs inside it taken out, unless
`vigil-commands-as-given'; explained, with `vigil-explain-commands'; and
with the scripts it names, read against DIRECTORY, with `vigil-show-scripts'."
  (let* ((command (alist-get 'command input))
         (tidy (and vigil--tidy (not vigil-commands-as-given)
                    (vigil-command-tidy command)))
         (blocks (plist-get tidy :blocks))
         (explain (and vigil--tidy vigil-explain-commands)))
    (insert (propertize "$ " 'face 'shadow)
            (if tidy
                (replace-regexp-in-string "\n" "\n  " (plist-get tidy :shell) t t)
              (vigil-command-fontify command #'sh-mode))
            "\n")
    (when-let* ((description (alist-get 'description input)))
      (insert (propertize (concat "# " description "\n") 'face 'shadow)))
    (when explain
      (insert "\n")
      (vigil-command-insert-explanation command))
    (dolist (block blocks)
      (insert "\n" (car block) "\n" (cdr block) "\n"))
    (insert "\n")
    (when (or blocks explain)
      (vigil--section "Output"))
    (cond
     ((null response) (insert (propertize "(still running)\n" 'face 'shadow)))
     ((vigil--background-p response)
      (insert (propertize (format "(left running in the background, as task %s: %s)\n"
                                  (alist-get 'backgroundTaskId response)
                                  "r shows what it prints, where that is kept")
                          'face 'shadow)))
     ((consp response)
      (let ((out (alist-get 'stdout response))
            (err (alist-get 'stderr response)))
        (when (and (stringp out) (> (length out) 0))
          (insert (vigil--colours out) "\n"))
        (when (and (stringp err) (> (length err) 0))
          (insert (propertize (ansi-color-filter-apply err) 'face 'error) "\n"))
        (when (alist-get 'interrupted response)
          (insert (propertize "(interrupted)\n" 'face 'warning)))))
     ;; An agent that reports what a command printed as one piece of text.
     ((stringp response) (insert (vigil--colours response) "\n")))
    ;; Last: what the command printed is what is looked for first.
    (when-let* (((and vigil--tidy vigil-show-scripts))
                (scripts (ignore-errors (vigil-command-scripts command directory))))
      (insert "\n")
      (vigil--section "Scripts")
      (vigil-command-insert-scripts scripts))))

(defun vigil--render-subagent (subagent call)
  "Insert what SUBAGENT was asked, what it did and what it said.
CALL is the Agent call that launched it, if known."
  (let* ((input (and call (vigil-call-input call)))
         (response (and call (consp (vigil-call-response call))
                        (vigil-call-response call)))
         (result (or (vigil--response-text response)
                     (and subagent (vigil-subagent-result subagent)))))
    (insert (propertize (format "%s  [%s]\n"
                                (or (alist-get 'description input) "Subagent")
                                (or (and subagent (vigil-subagent-type subagent))
                                    (alist-get 'subagent_type input) "?"))
                        'face 'bold)
            (propertize (string-join
                         (delq nil (list (and subagent (vigil--subagent-status subagent))
                                         (and subagent
                                              (let ((took (vigil--subagent-took subagent)))
                                                (and (not (equal took "")) took)))
                                         (and subagent (vigil--subagent-progress subagent))
                                         (let ((model (alist-get 'resolvedModel response)))
                                           (and (stringp model) model))
                                         (and (equal (alist-get 'status response) "async_launched")
                                              "in the background")))
                         "  ·  ")
                        'face 'shadow)
            "\n\n")
    (when (stringp (alist-get 'prompt input))
      (vigil--section "Task")
      (vigil--insert-prose (alist-get 'prompt input))
      (insert "\n"))
    (vigil--section "Result")
    (if (and (stringp result) (> (length result) 0))
        (vigil--insert-prose result)
      (insert (propertize "(not reported yet)\n" 'face 'shadow)))
    (when (and subagent (vigil-subagent-calls subagent))
      (insert "\n")
      (vigil--section (format "Calls (%d)" (length (vigil-subagent-calls subagent))))
      (dolist (inner (vigil-subagent-calls subagent))
        (insert (format "  %-10s %-8s %s\n" (vigil-call-name inner)
                        (vigil--status inner) (vigil--summary inner)))))))

(defun vigil--render-todos (todos)
  "Insert TODOS, a todo list as TodoWrite gives it."
  (dolist (todo todos)
    (let ((status (alist-get 'status todo)))
      (insert (pcase status
                ("completed" (propertize "[x] " 'face 'success))
                ("in_progress" (propertize "[-] " 'face 'warning))
                (_ "[ ] "))
              (or (alist-get 'content todo) (alist-get 'subject todo) "")
              "\n"))))

(defun vigil--render-web (name input response)
  "Insert the WebFetch or WebSearch call NAME: INPUT, and RESPONSE."
  (let ((target (or (alist-get 'url input) (alist-get 'query input))))
    (insert (propertize (format "%s  %s\n" name (or target "")) 'face 'bold))
    (when-let* ((prompt (alist-get 'prompt input)))
      (insert (propertize (concat prompt "\n") 'face 'shadow)))
    (insert "\n")
    (let ((text (vigil--response-text response))
          (results (and (consp response) (alist-get 'results response))))
      (cond
       ((null response) (insert (propertize "(still running)\n" 'face 'shadow)))
       ((and (stringp text) (> (length text) 0)) (vigil--insert-prose text))
       ((and (consp results) (cl-every #'consp results))
        (dolist (result results)
          (if (and (consp result) (or (alist-get 'title result) (alist-get 'url result)))
              (insert "- " (or (alist-get 'title result) "") "\n  "
                      (propertize (or (alist-get 'url result) "") 'face 'link) "\n")
            (vigil--insert-json result))))
       (t (vigil--insert-json response))))))

(defun vigil--insert-image (file)
  "Insert the image FILE, as a Read call reports one, and what it is.
FILE carries the image as base64, its type and its dimensions.  Scaled to
fit the frame; where images cannot be shown, only what it is."
  (let* ((data (ignore-errors (base64-decode-string (alist-get 'base64 file))))
         (frame (or (frame-parent) (selected-frame)))
         (image (and data (display-images-p)
                     (ignore-errors
                       (create-image data nil t
                                     :max-width (* (min 110 (frame-width frame))
                                                   (frame-char-width frame))
                                     :max-height (/ (frame-pixel-height frame) 2)))))
         (dimensions (alist-get 'dimensions file))
         (size (alist-get 'originalSize file)))
    (if image
        (progn (insert-image image "[image]") (insert "\n"))
      (insert (propertize "(the image is not shown here)\n" 'face 'shadow)))
    (insert (propertize
             (string-join
              (delq nil (list (alist-get 'type file)
                              (and (alist-get 'originalWidth dimensions)
                                   (format "%d×%d" (alist-get 'originalWidth dimensions)
                                           (alist-get 'originalHeight dimensions)))
                              (and (numberp size) (file-size-human-readable size))
                              (and (alist-get 'displayWidth dimensions)
                                   (not (equal (alist-get 'displayWidth dimensions)
                                               (alist-get 'originalWidth dimensions)))
                                   (format "seen by the agent at %d×%d"
                                           (alist-get 'displayWidth dimensions)
                                           (alist-get 'displayHeight dimensions)))))
              "  ·  ")
             'face 'shadow)
            "\n")))

(defun vigil--render-read (input response)
  "Insert the file a Read call read: INPUT, and RESPONSE.
A text file highlighted in its mode; an image, as the image."
  (let* ((file (alist-get 'file_path input))
         (read (and (consp response) (alist-get 'file response)))
         (content (and (consp read) (alist-get 'content read)))
         (mode (and (stringp file) (assoc-default file auto-mode-alist #'string-match))))
    (insert (propertize (or file "") 'face 'bold) "\n\n")
    (cond ((stringp content)
           (insert (if (and (symbolp mode) (fboundp mode))
                       (vigil-command-fontify content mode)
                     content)))
          ((and (consp read) (stringp (alist-get 'base64 read)))
           (vigil--insert-image read))
          (t (vigil--insert-json response)))))

(defun vigil--render-generic (input response)
  "Insert INPUT and RESPONSE of a call nothing here knows, as JSON."
  (vigil--section "Input")
  (vigil--insert-json input)
  (insert "\n")
  (vigil--section "Result")
  (cond ((null response) (insert (propertize "(still running)\n" 'face 'shadow)))
        ((consp response) (vigil--insert-json response))
        ((stringp response) (insert response "\n"))))

(defun vigil--render-grep (input response)
  "Insert what a search found: INPUT's pattern, and the files or lines in RESPONSE."
  (insert (propertize (format "%s\n" (or (alist-get 'pattern input) "")) 'face 'bold))
  (when-let* ((path (alist-get 'path input)))
    (insert (propertize (format "in %s\n" path) 'face 'shadow)))
  (insert "\n")
  (let ((files (and (consp response) (alist-get 'filenames response)))
        (content (and (consp response) (alist-get 'content response))))
    (cond ((null response) (insert (propertize "(still running)\n" 'face 'shadow)))
          ((stringp content) (insert content "\n"))
          ((and (consp files) (cl-every #'stringp files))
           (dolist (file files) (insert file "\n")))
          (t (vigil--insert-json response)))))

(defun vigil--insert-body (call)
  "Insert what CALL was given and what it gave back, drawn for its kind.
Whatever goes wrong drawing one kind of call, the call is still shown, as
JSON."
  (let* ((name (vigil-call-name call))
         (input (vigil-call-input call))
         (response (vigil-call-response call))
         (start (point)))
    (condition-case-unless-debug nil
        (cond
         ((vigil-call-unreadable call)
          (insert (propertize "The report of this call could not be read.\n"
                              'face 'warning)))
         ((or (vigil-call-subagent call) (vigil--launcher-p call))
          (vigil--render-subagent (vigil-call-subagent call) call))
         ((and (member name '("Edit" "MultiEdit" "Write")) (vigil-diff call))
          (insert (vigil-command-fontify (vigil-diff call) #'diff-mode)))
         ((stringp (alist-get 'command input))
          (vigil--render-bash input response (vigil-call-cwd call)))
         ((equal name "TodoWrite")
          (vigil--render-todos (alist-get 'todos input)))
         ((member name '("WebFetch" "WebSearch"))
          (vigil--render-web name input response))
         ((equal name "Read")
          (vigil--render-read input response))
         ((member name '("Grep" "Glob"))
          (vigil--render-grep input response))
         (t (vigil--render-generic input response)))
      ;; A report in a shape its renderer does not know is shown as it is.
      ;; With `debug-on-error', the renderer's own failure is shown instead.
      (error
       (delete-region start (point))
       (vigil--render-generic input response)))
    ;; What else is known of it: never the reason it is not shown.
    (dolist (more vigil-call-body-functions)
      (let ((from (point)))
        (condition-case-unless-debug nil
            (funcall more call)
          (error (delete-region from (point))))))))

(defun vigil--group-p (item)
  "Whether ITEM is a group of calls marked on one line."
  (and (consp item) (vigil-call-p (car item))))

(defun vigil--item-call (item)
  "The call ITEM stands for: a call, a group of them or a subagent.
A group is its first call, and a subagent the call that launched it; nil
where that is not known yet, or ITEM is none of these."
  (cond ((vigil-call-p item) item)
        ((vigil-subagent-p item) (vigil-subagent-call item))
        ((vigil--group-p item) (car item))))

(defun vigil--render (item &optional agent)
  "Fill the current buffer with ITEM: a call, a group of calls, or a subagent.
Of the agent buffer AGENT, if known: its header says how far into AGENT's
conversation ITEM is.
An edit alone is shown in `diff-mode'; everything else in a read-only view
drawn for its kind."
  (let* ((inhibit-read-only t)
         (vigil--tidy t)
         (call (cond ((vigil-call-p item) item)
                     ((vigil-subagent-p item) (vigil-subagent-call item))))
         (diff (and call (member (vigil-call-name call) '("Edit" "MultiEdit" "Write"))
                    (vigil-diff call))))
    (if diff
        (progn (diff-mode) (erase-buffer) (insert diff))
      (vigil-view-mode)
      (erase-buffer)
      (cond
       ((vigil--group-p item)
        (dolist (inner item)
          (insert (propertize (format "%s  %s" (vigil-call-name inner)
                                      (vigil--summary inner))
                              'face 'bold)
                  (propertize (format "  ·  %s %s\n" (vigil--status inner)
                                      (vigil--took inner))
                              'face 'shadow))
          (vigil--insert-body inner)
          (insert "\n")))
       (call (vigil--insert-body call))
       (t (vigil--render-subagent item nil))))
    (when (and call (stringp (vigil-call-cwd call)))
      (setq default-directory (file-name-as-directory (vigil-call-cwd call))))
    (vigil--link-files (point-min) (point-max) default-directory)
    (setq buffer-read-only t
          header-line-format
          (vigil--header item (cond (call (list call)) ((vigil--group-p item) item)) agent))
    (setq-local mode-line-format (vigil--footer item))
    (setq-local cooked-popup-visit-function #'vigil--visit-call-file)
    (cooked-popup-mode 1)
    (vigil-popup-mode 1)
    (goto-char (point-min))))

(defun vigil--buffer ()
  "The buffer calls are inspected in."
  (get-buffer-create "*vigil call*"))

(defun vigil--run-for (call agent)
  "The run of CALL's command in AGENT's session, if one was kept.
Where the agent runs its commands through `cooked-host run' (bin/vigil-shell
has Claude Code do so), cooked keeps what each prints as it comes, under the
command as its label.  A report says the same command and when: the run of
that name which began nearest the call is its run."
  (when-let* (((vigil-call-p call))
              (command (alist-get 'command (vigil-call-input call)))
              ((stringp command))
              ((buffer-live-p agent))
              ((boundp 'cooked-host-name))
              (session (buffer-local-value 'cooked-host-name agent))
              ((require 'cooked-run nil t)))
    (let ((start (or (vigil-call-start call) 0))
          (end (vigil-call-end call))
          (best nil))
      (dolist (run (cooked-runs session))
        (let ((began (plist-get run :started)))
          (when (and (equal (plist-get run :label) command)
                     (numberp began)
                     ;; The report of a call is written beside the call, not
                     ;; before it: either may be the earlier by a little.
                     (> began (- start 5))
                     (or (null end) (< began (+ end 1)))
                     (or (null best)
                         (< (abs (- began start))
                            (abs (- (plist-get best :started) start)))))
            (setq best run))))
      best)))

(defvar-local vigil--followed nil
  "Calls already asked whether their command was followed: a hash table.")

(defvar-local vigil--unfollowed 0
  "How many commands in a row were reported and not followed.")

(defvar-local vigil--unfollowed-warned nil
  "Whether this buffer has said that its agent's commands are not followed.")

(defcustom vigil-unfollowed-limit 3
  "How many commands in a row may go unfollowed before it is said.
Where the agent runs its commands through bin/vigil-shell.  One that is not
followed may be nothing -- a command written in a way its name was not
recognised by -- but none of several is the wrapper no longer knowing the
agent's commands when it sees them, or having nowhere to keep them."
  :type 'natnum)

(defun vigil--shell-since ()
  "Since when this buffer's agent has run its commands through vigil-shell.
A time, or nil if it does not: `vigil hook' says so with a file."
  (when-let* ((directory (vigil--agent-directory))
              (attributes (file-attributes (expand-file-name ".shell" directory))))
    (float-time (file-attribute-modification-time attributes))))

(defun vigil--check-followed ()
  "Say so, once, if this agent's commands have stopped being followed.
On `vigil-changed-hook'.  The hooks report every command the agent runs, and
that is documented; which of the things handed to bin/vigil-shell are those
commands is told by their shape, which is not.  So the reports are what the
runs are checked against: a command reported after the agent began running
them through vigil-shell should have a run."
  (when-let* ((since (vigil--shell-since))
              ((require 'cooked-run nil t)))
    (unless vigil--followed
      (setq vigil--followed (make-hash-table :test #'eq :weakness 'key)))
    (dolist (call vigil--order)
      (when (and (not (gethash call vigil--followed))
                 (vigil-call-response call)
                 (stringp (alist-get 'command (vigil-call-input call)))
                 (> (or (vigil-call-start call) 0) since))
        (puthash call t vigil--followed)
        (if (vigil--run-for call (current-buffer))
            (setq vigil--unfollowed 0)
          (cl-incf vigil--unfollowed))))
    (when (and (>= vigil--unfollowed vigil-unfollowed-limit)
               (not vigil--unfollowed-warned))
      (setq vigil--unfollowed-warned t)
      (display-warning
       'vigil
       (format "The last %d commands of the agent in %s ran, but were not kept as they
printed.  The commands themselves are unaffected.  Either Claude Code has
changed how it hands its commands to CLAUDE_CODE_SHELL_PREFIX -- bin/vigil-shell
tells them from its hooks by their shape, and needs to be taught the new one --
or cooked could not write its runs directory: `vigil install-shell' adds it to
the sandbox's allow-list, and `cooked-run-directory' says where it is."
               vigil--unfollowed (buffer-name))
       :warning))))

(add-hook 'vigil-changed-hook #'vigil--check-followed)

(defun vigil--inspect-run (call agent run)
  "Show RUN, what CALL's command prints as it prints it, with CALL's keys."
  (let ((buffer (cooked-run-buffer run)))
    ;; As a compilation shown last is: what `next-error' walks.
    (setq next-error-last-buffer buffer)
    (with-current-buffer buffer
      (setq vigil--popup-call call
            vigil--popup-agent agent)
      (cooked-popup-mode 1)
      (vigil-popup-mode 1)
      (setq-local mode-line-format
                  " q close  ] next  [ previous  o conversation  r report")
      (goto-char (point-max)))
    (cooked-popup-buffer buffer)))

(defun vigil--inspect-report (call agent)
  "Show CALL of AGENT as its report has it, in the buffer calls are drawn in."
  (let ((buffer (vigil--buffer)))
    (with-current-buffer buffer
      (vigil--render call agent)
      (setq vigil--popup-call call
            vigil--popup-agent agent))
    (cooked-popup-buffer buffer)))

(defun vigil-show-run ()
  "Show what the command being inspected printed, as it came; again, its report.
All of it and in the order it came, where the report of the call may have
it cut short or in two halves; and still coming, if the command is running."
  (interactive)
  (let ((call vigil--popup-call) (agent vigil--popup-agent))
    (if (derived-mode-p 'cooked-run-mode)
        (vigil--inspect-report call agent)
      (let ((run (vigil--run-for call agent)))
        (unless run
          (user-error "Nothing was kept of this call beyond its report"))
        (vigil--inspect-run call agent run)))))

(defvar vigil-inspect-functions nil
  "Called with a call, a group of them or a subagent, and its agent buffer.
Each time one is put on show to be inspected, once it is on show.
vigil-transcript.el shows there where it is in the conversation.")

(defvar vigil--continuing nil
  "While `vigil-inspect-functions' run: whether a pop-up was already up.
A call stepped to, or opened from another pop-up, continues what was being
looked at; one opened from anywhere else starts afresh.")

(defun vigil--popup-up-p ()
  "Whether the selected window is a pop-up's: what is done here continues it."
  (and (fboundp 'cooked-popup-showing-p)
       (cooked-popup-showing-p (window-buffer))))

(defun vigil--background-p (response)
  "Whether RESPONSE is that of a command the agent left running in the background.
Such a report comes as soon as the command starts, saying only which task it is."
  (and (consp response) (alist-get 'backgroundTaskId response) t))

(defun vigil-inspect (call &optional agent)
  "Inspect CALL, a tool call or a subagent of the agent buffer AGENT.
In a frame over this one.  A command that has not finished, or that was left
running in the background, is shown as it prints, where that is kept: its
report has none of it.  See `vigil--run-for'.  Returns the buffer shown.
Then runs `vigil-inspect-functions'."
  (let* ((agent (or agent (current-buffer)))
         (vigil--continuing (vigil--popup-up-p))
         (run (and (vigil-call-p call)
                   (or (null (vigil-call-response call))
                       (vigil--background-p (vigil-call-response call)))
                   (vigil--run-for call agent))))
    (prog1 (if run
               (vigil--inspect-run call agent run)
             (vigil--inspect-report call agent))
      (run-hook-with-args 'vigil-inspect-functions call agent))))

(defun vigil--step (n)
  "Inspect the call N after the one shown; before it, if N is negative.
From a file opened out of a call, the call after or before that one."
  (let* ((agent vigil--popup-agent)
         (order (and (buffer-live-p agent)
                     (buffer-local-value 'vigil--order agent)))
         (shown vigil--popup-call)
         (current (cond ((vigil-subagent-p shown) (vigil-subagent-call shown))
                        ((vigil--group-p shown)
                         (if (> n 0) (car (last shown)) (car shown)))
                        (t shown)))
         (index (cl-position current order))
         (target (and index (nth (+ index n) order))))
    (unless (and target (>= (+ index n) 0))
      (user-error "No %s call" (if (> n 0) "later" "earlier")))
    (vigil-inspect target agent)))

(defun vigil--redraw ()
  "Draw the call being inspected again, where it was."
  (let ((line (line-number-at-pos))
        (start (and (get-buffer-window) (window-start (get-buffer-window)))))
    (vigil-inspect vigil--popup-call vigil--popup-agent)
    (goto-char (point-min))
    (forward-line (1- line))
    (when start
      (set-window-start (get-buffer-window) (min start (point-max))))))

(defun vigil-toggle-explain ()
  "Say, or stop saying, what the programs and options of a command are.
For every command inspected from now on, too: see `vigil-explain-commands'."
  (interactive)
  (setq vigil-explain-commands (not vigil-explain-commands))
  (vigil--redraw)
  (message "Commands %sexplained" (if vigil-explain-commands "" "not ")))

(defun vigil-toggle-as-given ()
  "Show commands exactly as given, or laid out to be read.
For every command inspected from now on, too: see `vigil-commands-as-given'."
  (interactive)
  (setq vigil-commands-as-given (not vigil-commands-as-given))
  (vigil--redraw)
  (message "Commands shown %s" (if vigil-commands-as-given "as given" "laid out")))

(defun vigil-toggle-scripts ()
  "Show, or stop showing, the scripts a command names under it.
For every command inspected from now on, too: see `vigil-show-scripts'."
  (interactive)
  (setq vigil-show-scripts (not vigil-show-scripts))
  (vigil--redraw)
  (message "Scripts %sshown" (if vigil-show-scripts "" "not ")))

(defun vigil-next-call ()
  "Inspect the agent's next tool call."
  (interactive)
  (vigil--step 1))

(defun vigil-previous-call ()
  "Inspect the agent's previous tool call."
  (interactive)
  (vigil--step -1))

(defun vigil--call-place (call)
  "The file CALL was about and where it first changed it: (FILE . LINE).
LINE is nil where its report says none, as for a file only read; nil
altogether where CALL names no file."
  (when-let* (((vigil-call-p call))
              (input (vigil-call-input call))
              (file (or (alist-get 'file_path input) (alist-get 'notebook_path input)))
              ((stringp file)))
    (let ((response (vigil-call-response call)))
      (cons file (and (consp response)
                      (alist-get 'newStart
                                 (car-safe (alist-get 'structuredPatch response))))))))

(defun vigil--visit-place (place)
  "Visit PLACE, a (FILE . LINE) of `vigil--call-place', in another window."
  (find-file-other-window (car place))
  (when (numberp (cdr place))
    (goto-char (point-min))
    (forward-line (1- (cdr place))))
  (current-buffer))

(defun vigil--visit-call-file ()
  "Visit the file the call being inspected changed, at its first change.
The `cooked-popup-visit-function' of a buffer inspecting a call."
  (let ((place (vigil--call-place vigil--popup-call)))
    (unless (and place (file-exists-p (car place)))
      (user-error "No file to visit"))
    (cooked-popup-quit)
    (vigil--visit-place place)))

;;;; Files

(defcustom vigil-browse-extensions '("html" "htm" "xhtml")
  "Extensions of files that open in a browser rather than in a pop-up.
Through `browse-url-of-file', so the system's default browser."
  :type '(repeat string)
  :group 'vigil)

(defun vigil-preview-file (file &optional line col)
  "Show FILE at LINE and COL: a page in the browser, anything else in a pop-up.
See `vigil-browse-extensions' and `cooked-popup-file'.  Opened from a
call being inspected, the file's buffer keeps that call's keys: \\`]' and \\`['
step to the calls after and before it, and \\`o' goes to its line."
  (if (member (downcase (or (file-name-extension file) ""))
              vigil-browse-extensions)
      (browse-url-of-file (expand-file-name file))
    (let ((call vigil--popup-call)
          (agent vigil--popup-agent)
          (buffer (cooked-popup-file file line col)))
      (when (and buffer call)
        (with-current-buffer buffer
          (setq vigil--popup-call call
                vigil--popup-agent agent
                header-line-format
                (concat header-line-format "  ] next call  [ previous call"))
          (vigil-popup-mode 1)))
      buffer)))

(defun vigil--open-file (file line col)
  "Preview FILE at LINE and COL from an agent buffer.
The agent buffer's `cooked-file-open-function'."
  (vigil-preview-file file line col)
  t)

(defconst vigil--file-regexp
  (concat "\\(?:~\\|\\.\\.?\\)?/[[:alnum:]_.~+@%=,/-]*[[:alnum:]_~+@%=-]"
          "\\|[[:alnum:]_.-]+/[[:alnum:]_./-]*\\.[[:alnum:]]+")
  "What a file name in a pop-up or the context buffer looks like.
Absolute, home- or dot-relative paths, and relative ones with a directory
and an extension.  Only those that name a file that exists become links.")

(defconst vigil--name-run-regexp "[[:alnum:]_.~+@%=,/-]+"
  "A run of the characters `vigil--file-regexp' is made of; a file name is in one.")

(defun vigil--file-names (end)
  "Move to the end of the next file name before END, and match it; nil if none.
Looked for only inside runs of the characters a name is made of, and none
in a run longer than a name can be: on a long one -- base64, a minified
line -- `vigil--file-regexp' backtracks for long, or runs out of stack."
  (let ((found nil))
    (while (and (not found) (re-search-forward vigil--name-run-regexp end t))
      (let ((run-end (match-end 0)))
        (when (<= (- run-end (match-beginning 0)) 1024)
          (goto-char (match-beginning 0))
          (unless (setq found (re-search-forward vigil--file-regexp run-end t))
            (goto-char run-end)))))
    found))

(defun vigil--link-files (beg end directory)
  "Make the names of existing files between BEG and END links to a preview.
Relative names are read against DIRECTORY.  Each name is asked about once."
  (when (< (- end beg) 2000000)
    (let ((known (make-hash-table :test #'equal))
          (case-fold-search nil)
          (count 0))
      (save-excursion
        (goto-char beg)
        (while (and (< count 5000) (vigil--file-names end))
          (cl-incf count)
          (progn
            (let* ((from (match-beginning 0))
                   (to (match-end 0))
                   (name (match-string-no-properties 0))
                   (file (expand-file-name name directory))
                   (exists (with-memoization (gethash file known)
                             (if (and (file-regular-p file) (file-readable-p file))
                                 'yes 'no)))
                   (line nil) (col nil))
              (when (and (eq exists 'yes)
                         (not (get-text-property from 'button)))
                (when (looking-at ":\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?")
                  (setq line (string-to-number (match-string 1))
                        col (and (match-string 2) (string-to-number (match-string 2)))
                        to (match-end 0))
                  (goto-char to))
                (make-text-button
                 from to
                 'action (lambda (_) (vigil-preview-file file line col))
                 'follow-link t
                 'help-echo (format "RET, mouse-1: preview %s" (abbreviate-file-name file)))))))))))

;;;; Everything the agent was given

(defvar-local vigil-mode nil)   ; defined with the mode, below

(defvar-local vigil--context-agent nil "The agent buffer this context is of.")

(defvar-local vigil--context-title nil
  "What the context is of, said at its top; by default its agent buffer's name.")

(defvar-local vigil--bodies nil "Drawn bodies of finished calls, by call.")

(defconst vigil--not-reported
  "Not reported by hooks, and so not here: the system prompt, CLAUDE.md and
memory files, the summary a compaction leaves (a session start marked
\"compact\" is where one happened), and the agent's own words between
tool calls.  Claude Code's transcript has all of it; it is not read here."
  "What the context buffer says it cannot show.")

(defvar vigil-context-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-context-inspect)
    (define-key map (kbd "n") #'outline-next-visible-heading)
    (define-key map (kbd "p") #'outline-previous-visible-heading)
    (define-key map (kbd "g") #'vigil-context-refresh)
    map)
  "Keys of `vigil-context-mode'.")

(define-derived-mode vigil-context-mode special-mode "Context"
  "Everything that has entered an agent's context, oldest first.
Each entry is a heading; TAB folds it, S-TAB folds them all.
\\{vigil-context-mode-map}"
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  (setq-local outline-regexp "\\*+ ")
  (setq-local outline-level (lambda () (- (match-end 0) (match-beginning 0) 1)))
  (setq-local outline-minor-mode-cycle t)
  (setq vigil--bodies (make-hash-table :test #'eq :weakness 'key))
  (outline-minor-mode 1))

(defun vigil--indent (text depth)
  "TEXT with every line indented for DEPTH, so no line of it reads as a heading."
  (replace-regexp-in-string "^" (make-string (* 2 depth) ?\s) text))

(defun vigil--body (call)
  "CALL's body, drawn once it has finished and then kept."
  (or (gethash call vigil--bodies)
      (let ((body (with-temp-buffer
                    (vigil--insert-body call)
                    (buffer-string))))
        (when (vigil-call-response call)
          (puthash call body vigil--bodies))
        body)))

(defun vigil--context-entries (agent)
  "What has entered AGENT's context, as (TIME KEY HEADING BODY ITEM CHILDREN).
Oldest first.  CHILDREN, for a subagent, are its calls in the same shape."
  (let* ((call-entry
          (lambda (call)
            (list (vigil-call-start call) (vigil-call-id call)
                  (format "%s  %s" (vigil-call-name call) (vigil--summary call))
                  (lambda () (vigil--body call))
                  call nil)))
         (subagent-entry
          (lambda (subagent)
            (let ((call (vigil-subagent-call subagent)))
              (list (or (and call (vigil-call-start call))
                        (vigil-subagent-start subagent) 0)
                    (concat "agent:" (vigil-subagent-id subagent))
                    (format "Agent  [%s] %s" (or (vigil-subagent-type subagent) "?")
                            (or (and call (alist-get 'description (vigil-call-input call)))
                                (vigil-subagent-id subagent)))
                    (lambda () (with-temp-buffer
                                 (vigil--render-subagent subagent call)
                                 (buffer-string)))
                    (or call subagent)
                    (mapcar call-entry (vigil-subagent-calls subagent))))))
         (entries nil)
         (prompts 0)
         (notes 0))
    (with-current-buffer agent
      (dolist (prompt vigil--prompts)
        (push (list (or (vigil--prompt-time prompt) 0) (format "prompt:%d" (cl-incf prompts))
                    "Prompt" (let ((text (vigil--prompt-text prompt)))
                               (lambda () (concat text "\n")))
                    nil nil)
              entries))
      (dolist (note vigil--notes)
        (push (list (plist-get note :time) (format "note:%d" (cl-incf notes))
                    (if (eq (plist-get note :kind) 'session)
                        (format "Session start (%s)" (or (plist-get note :text) "?"))
                      "Reply")
                    (let ((text (and (eq (plist-get note :kind) 'reply)
                                     (plist-get note :text))))
                      (lambda () (if (stringp text) (concat text "\n") "")))
                    nil nil)
              entries))
      (dolist (call vigil--order)
        (unless (vigil-call-agent call)
          (push (if (vigil-call-subagent call)
                    (funcall subagent-entry (vigil-call-subagent call))
                  (funcall call-entry call))
                entries)))
      (when vigil--subagents
        (maphash (lambda (_id subagent)
                   (unless (vigil-subagent-call subagent)
                     (push (funcall subagent-entry subagent) entries)))
                 vigil--subagents)))
    (sort (nreverse entries) (lambda (a b) (< (car a) (car b))))))

(defun vigil--context-insert (entry depth)
  "Insert ENTRY, a heading and its body, DEPTH deep."
  (pcase-let ((`(,time ,key ,heading ,body ,item ,children) entry))
    (let ((start (point)))
      (insert (make-string depth ?*) " "
              (format-time-string "%H:%M:%S" time) "  " heading
              (if (or (vigil-call-p item) (vigil-subagent-p item))
                  (propertize (vigil--state item) 'face 'shadow)
                "")
              "\n")
      (put-text-property start (point) 'vigil-key key)
      (put-text-property start (point) 'vigil-item item)
      (add-face-text-property start (1- (point)) 'bold t)
      (let ((text (funcall body)))
        (unless (equal text "")
          (insert (vigil--indent (string-remove-suffix "\n" text) depth) "\n")))
      (dolist (child children)
        (vigil--context-insert child (1+ depth))))))

(defun vigil--context-open-keys ()
  "The keys of the entries whose bodies are showing."
  (let (keys)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ " nil t)
        (when (and (get-text-property (point) 'vigil-key)
                   (not (outline-invisible-p (line-end-position))))
          (push (get-text-property (point) 'vigil-key) keys))))
    keys))

(defun vigil--context-goto-key (key)
  "Move to the heading of the entry KEY, if there is one."
  (when-let* ((match (save-excursion
                       (goto-char (point-min))
                       (text-property-search-forward 'vigil-key key t))))
    (goto-char (prop-match-beginning match))))

(defun vigil--context-render ()
  "Draw this context buffer again, keeping what was open and where point was."
  (let* ((inhibit-read-only t)
         (open (vigil--context-open-keys))
         (following (>= (point) (1- (point-max))))
         (here (save-excursion
                 (end-of-line)
                 (and (re-search-backward "^\\*+ " nil t)
                      (get-text-property (point) 'vigil-key))))
         (agent vigil--context-agent)
         (transcript (buffer-local-value 'vigil--transcript agent)))
    (erase-buffer)
    (insert (propertize (format "What %s has been given, oldest first, as its hooks report it.\n"
                                (or vigil--context-title (buffer-name agent)))
                        'face 'bold)
            (propertize vigil--not-reported 'face 'shadow) "\n")
    (when (stringp transcript)
      (insert (propertize "Transcript: " 'face 'shadow))
      (insert-text-button transcript 'action (lambda (_) (find-file-read-only transcript))
                          'follow-link t)
      (insert "\n"))
    (insert "\n")
    (dolist (entry (vigil--context-entries agent))
      (vigil--context-insert entry 1))
    (vigil--link-files (point-min) (point-max)
                               (buffer-local-value 'default-directory agent))
    (outline-hide-sublevels 1)
    (dolist (key open)
      (when (vigil--context-goto-key key)
        (outline-show-entry)
        (outline-show-children)))
    (cond (following (goto-char (point-max)))
          ((and here (vigil--context-goto-key here)))
          (t (goto-char (point-min))))))

(defun vigil--refresh-context (agent)
  "Bring AGENT's context buffer up to date, if it has one."
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'vigil-context-mode)
               (eq (buffer-local-value 'vigil--context-agent buffer) agent))
      (with-current-buffer buffer
        (let ((windows (get-buffer-window-list buffer nil t)))
          (vigil--context-render)
          (dolist (window windows) (set-window-point window (point))))))))

(defun vigil-context-refresh ()
  "Read the agent's newest reports and draw this context again."
  (interactive)
  (unless (buffer-live-p vigil--context-agent)
    (user-error "This agent's buffer is gone: there is nothing newer to read"))
  (vigil--scan vigil--context-agent)
  (vigil--context-render))

(defun vigil--agent-buffers ()
  "The agent buffers whose calls are kept."
  (cl-remove-if-not (lambda (buffer)
                      (buffer-local-value 'vigil-mode buffer))
                    (buffer-list)))

(defun vigil--session-buffer (session)
  "The live agent buffer of the hosted session named SESSION, if there is one."
  (cl-find-if (lambda (buffer) (equal (vigil--session-name buffer) session))
              (vigil--agent-buffers)))

;;;###autoload

(defun vigil-context (&optional agent)
  "Show everything that has entered AGENT's context, by default this buffer's.
Asks which agent when this is not an agent's buffer."
  (interactive)
  (let ((agent (or agent
                   (and vigil-mode (current-buffer))
                   (let ((buffers (vigil--agent-buffers)))
                     (cond ((null buffers) (user-error "No agent's context is kept"))
                           ((null (cdr buffers)) (car buffers))
                           (t (get-buffer (completing-read "Agent: "
                                                           (mapcar #'buffer-name buffers)
                                                           nil t))))))))
    (vigil--scan agent)
    (let ((buffer (get-buffer-create (format "*context: %s*" (buffer-name agent)))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'vigil-context-mode)
          (vigil-context-mode))
        (setq vigil--context-agent agent)
        (vigil--context-render))
      (pop-to-buffer buffer)
      buffer)))

(defun vigil--context-item ()
  "The call or subagent of the entry at point, if it is one."
  (save-excursion
    (end-of-line)
    (and (re-search-backward "^\\*+ " nil t)
         (get-text-property (point) 'vigil-item))))

(defun vigil-context-inspect ()
  "Inspect the call or subagent at point in a frame; fold anything else."
  (interactive)
  (if-let* ((item (vigil--context-item)))
      (vigil-inspect item vigil--context-agent)
    (outline-toggle-children)))

;;;; Prompts

(defcustom vigil-prompt-history
  (expand-file-name "vigil/prompts.jsonl" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Where `vigil hook' keeps every prompt given to an agent here.
The program's VIGIL_PROMPT_HISTORY."
  :type 'file)

(defun vigil--prompt-history ()
  "The prompts in `vigil-prompt-history', newest first.
Each a plist: :text, :host, :time, :cwd.  Repeats are kept once, newest; a
line that cannot be read is passed over, and so is what the agent gives
itself as a prompt (a background task reporting back)."
  (let ((seen (make-hash-table :test #'equal))
        (prompts nil))
    (when (file-readable-p vigil-prompt-history)
      (with-temp-buffer
        (insert-file-contents vigil-prompt-history)
        (goto-char (point-max))
        (while (= 0 (forward-line -1))
          (when-let* ((record (ignore-errors
                                (json-parse-string
                                 (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position))
                                 :object-type 'alist :null-object nil :false-object nil)))
                      (event (alist-get 'event record))
                      (text (alist-get 'prompt event))
                      ((stringp text))
                      ((not (vigil--injected-p text)))
                      ((not (gethash text seen))))
            (puthash text t seen)
            (push (list :text text :host (alist-get 'host record)
                        :time (alist-get 'time record) :cwd (alist-get 'cwd event))
                  prompts)))))
    (nreverse prompts)))

(defun vigil--target-agent ()
  "The agent buffer a prompt from the history goes to."
  (cond (vigil-mode (current-buffer))
        ((buffer-live-p vigil--context-agent) vigil--context-agent)
        ((cl-find-if (lambda (buffer) (get-buffer-window buffer 'visible))
                     (vigil--agent-buffers)))
        ((car (vigil--agent-buffers)))
        (t (user-error "No agent buffer to give the prompt to"))))

;;;###autoload

(defun vigil-prompts (&optional all)
  "Choose one of the prompts given to this agent, and paste it at its input.
Newest first; with ALL (\\[universal-argument]), the prompts given to every agent
on this machine.  The prompt is pasted, not submitted."
  (interactive "P")
  (let* ((agent (vigil--target-agent))
         (host (buffer-local-value 'cooked-host-name agent))
         (prompts (cl-remove-if-not
                   (lambda (prompt) (or all (equal (plist-get prompt :host) host)))
                   (vigil--prompt-history)))
         (table (make-hash-table :test #'equal))
         (candidates
          (mapcar (lambda (prompt)
                    (let ((shown (replace-regexp-in-string
                                  "\n" " \u21b5 " (string-trim (plist-get prompt :text)))))
                      (while (gethash shown table) (setq shown (concat shown " ")))
                      (puthash shown prompt table)
                      shown))
                  prompts)))
    (unless candidates
      (user-error "No prompts%s yet" (if all "" " for this agent")))
    (let* ((annotate
            (lambda (shown)
              (when-let* ((prompt (gethash shown table)))
                (propertize
                 (format "  %s  %s%s"
                         (if (plist-get prompt :time)
                             (format-time-string "%Y-%m-%d %H:%M" (plist-get prompt :time))
                           "")
                         (or (plist-get prompt :host) "")
                         (if (plist-get prompt :cwd)
                             (concat "  " (abbreviate-file-name (plist-get prompt :cwd)))
                           ""))
                 'face 'completions-annotations))))
           (choice (completing-read
                    (if all "Prompt (all agents): " "Prompt: ")
                    (lambda (string predicate action)
                      (if (eq action 'metadata)
                          `(metadata (category . vigil-prompt)
                                     (display-sort-function . identity)
                                     (annotation-function . ,annotate))
                        (complete-with-action action candidates string predicate)))
                    nil t))
           (prompt (gethash choice table)))
      (when prompt
        (pop-to-buffer agent)
        (cooked-paste-string (plist-get prompt :text))))))

;;;; The mode

(defvar vigil-mode-map (make-sparse-keymap)
  "Keys of an agent's buffer.  A minor mode's map, so they outrank the map that
hands every other key to the agent: \\`C-c' is cooked's prefix already, and
nothing under it is the agent's.")

;; The session's buffer, and of it what is changing now: two keys away.
(define-key vigil-mode-map (kbd "C-c C-s") #'vigil)
(define-key vigil-mode-map (kbd "C-c C-w") #'vigil-live)

(define-minor-mode vigil-mode
  "Keep the tool calls of the agent in this buffer's session.
For a buffer attached to one of cooked's hosted sessions; turned on by
`vigil-setup' for every one an agent reports from."
  :lighter nil
  :keymap vigil-mode-map
  (if vigil-mode
      (let ((directory (vigil--agent-directory))
            (buffer (current-buffer)))
        (unless directory
          (setq vigil-mode nil)
          (user-error "This buffer is not attached to a hosted session"))
        ;; Turned on where it was on already: the one watch, not a second.
        (vigil--stop)
        (vigil--reset)
        (ignore-errors (with-file-modes #o700 (make-directory directory t)))
        (setq vigil--watch
              (ignore-errors
                (file-notify-add-watch directory '(change)
                                       (lambda (_event)
                                         (vigil--schedule buffer)))))
        (add-hook 'kill-buffer-hook #'vigil--stop nil t)
        ;; What was written before this buffer was: the output it replayed
        ;; may show some of it, which is looked for once it has arrived.
        (vigil--schedule buffer 0.5))
    (vigil--stop)))

(defun vigil--reset ()
  "Start this buffer's record of calls, prompts and subagents afresh."
  (vigil--forget-transcript)
  (setq vigil--calls (make-hash-table :test #'equal)
        vigil--prompts nil
        vigil--notes nil
        vigil--transcript nil
        vigil--subagents (make-hash-table :test #'equal)
        vigil--edits (make-hash-table :test #'equal)
        vigil-edits-made (1+ vigil-edits-made)
        vigil--seen (make-hash-table :test #'equal)
        vigil--order nil
        vigil--followed nil
        vigil--unfollowed 0
        vigil--unfollowed-warned nil))

(defun vigil--stop ()
  "Stop watching this buffer's session."
  (when vigil--watch
    (ignore-errors (file-notify-rm-watch vigil--watch)))
  (when vigil--timer (cancel-timer vigil--timer))
  (vigil--forget-transcript)
  (setq vigil--watch nil vigil--timer nil))

(defun vigil--maybe-enable (&optional buffer)
  "Turn on `vigil-mode' in BUFFER if an agent has reported from its session.
On `cooked-host-attach-hook', which is every way a buffer comes to be
attached to one: made for it, or brought back with a saved session of Emacs."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* (((not vigil-mode))
                (directory (vigil--agent-directory))
                ((file-directory-p directory)))
      ;; Said, not hidden: but not in the way of whatever attached the buffer.
      (with-demoted-errors "vigil: could not watch this agent: %S"
        (vigil-mode 1)))))

(defun vigil--enable-everywhere ()
  "Turn on `vigil-mode' in every buffer whose session an agent has reported from."
  (dolist (buffer (buffer-list))
    (when (and (local-variable-p 'cooked-host-name buffer)
               (not (buffer-local-value 'vigil-mode buffer)))
      (vigil--maybe-enable buffer))))

(defvar vigil--directory-watch nil
  "The `file-notify' descriptor watching `vigil-directory' for new sessions.")

(defvar vigil--directory-timer nil
  "The timer that looks for the buffer of a session that has just reported.")

(defun vigil--directory-changed (_event)
  "Look, shortly, for the buffer of a session an agent has first reported from.
An agent may be started in a session long after a buffer was attached to it."
  (unless vigil--directory-timer
    (setq vigil--directory-timer
          (run-with-timer 0.2 nil (lambda ()
                                    (setq vigil--directory-timer nil)
                                    (vigil--enable-everywhere))))))

;;;###autoload
(defun vigil-setup ()
  "Keep the tool calls of every agent in a hosted session, from now on."
  (require 'vigil-transcript)
  (require 'vigil-turn)
  (require 'vigil-edits)
  (require 'vigil-effects)
  (require 'vigil-compile)
  (add-hook 'cooked-host-attach-hook #'vigil--maybe-enable)
  (ignore-errors (with-file-modes #o700 (make-directory vigil-directory t)))
  (unless vigil--directory-watch
    (setq vigil--directory-watch
          (ignore-errors
            (file-notify-add-watch vigil-directory '(change)
                                   #'vigil--directory-changed))))
  (vigil--enable-everywhere))

(provide 'vigil)
;;; vigil.el ends here
