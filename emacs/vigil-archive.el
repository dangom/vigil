;;; vigil-archive.el --- Every session kept, to study and to build evals from -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `vigil hook' keeps every event Claude Code's activity hooks report
;; -- prompts, tool calls with their results, subagents, session starts, the
;; replies ending turns -- in an archive that nothing prunes:
;;
;;   $ARCHIVE_DIR/<YYYY>/<MM>/<session_id>.jsonl   one line per event:
;;       {"t": <epoch>, "host": <session or null>, "hosted": <bool>,
;;        "event": <the event, verbatim>}
;;   $ARCHIVE_DIR/index.jsonl                      one line per session
;;
;; This file reads it:
;;
;; - `vigil-archive': the sessions, newest first -- date, project, agent,
;;   branch, how many prompts and tool calls.  RET opens one in the same
;;   read-only context view as `vigil-context'; `e' exports it.
;; - `vigil-archive-export': a dataset for evals, one JSON line per prompt
;;   (schema in the README, and `vigil-archive--row' below).
;;
;; Like the rest, the archive is data: parsed and shown, never evaluated.  A
;; line that cannot be read is passed over, and an event of a kind nothing
;; here knows is kept in the files and left out of the views.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'vigil)

(defcustom vigil-archive-directory (vigil-base-data-directory "archive")
  "Where `vigil hook' keeps the archive.  The program's VIGIL_ARCHIVE_DIR."
  :type 'directory
  :group 'vigil)

;;;; Reading

(defun vigil-archive--lines (file)
  "The JSON objects on the lines of FILE, in order; unreadable lines skipped."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (values)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((value (vigil-base-json-string line)))
            (push value values)))
        (nreverse values)))))

(defvar vigil-archive--counts (make-hash-table :test #'equal)
  "Prompts and calls per session file: ((SIZE MODIFIED) PROMPTS . CALLS).")

(defun vigil-archive--tally (file)
  "The prompts and tool calls in FILE, counted: (PROMPTS . CALLS)."
  (let ((prompts 0) (calls 0))
    (dolist (line (vigil-archive--lines file))
      (let* ((event (vigil-base-settled (alist-get 'event line)))
             (name (alist-get 'hook_event_name event)))
        (cond ((and (equal name "UserPromptSubmit")
                    (null (alist-get 'agent_id event))
                    (stringp (alist-get 'prompt event))
                    (not (vigil--injected-p (alist-get 'prompt event))))
               (cl-incf prompts))
              ((equal name "PostToolUse") (cl-incf calls)))))
    (cons prompts calls)))

(defun vigil-archive--count (file)
  "How many prompts and tool calls FILE holds, as (PROMPTS . CALLS).
Counted once for as long as the file stays as it is."
  ;; By the file, with what it was when counted: a session still going is
  ;; counted again, and its earlier counts are not kept beside the new.
  (let* ((attributes (file-attributes file))
         (state (list (file-attribute-size attributes)
                      (file-attribute-modification-time attributes)))
         (known (gethash file vigil-archive--counts)))
    (if (equal (car known) state)
        (cdr known)
      (cdr (puthash file (cons state (vigil-archive--tally file))
                    vigil-archive--counts)))))

(defun vigil-archive--first-time (file)
  "When the first event in FILE came, or failing that when FILE was written."
  (or (with-temp-buffer
        (ignore-errors (insert-file-contents file nil 0 65536))
        (goto-char (point-min))
        (let ((first (vigil-base-json-string
                      (buffer-substring-no-properties (point) (line-end-position)))))
          (and (numberp (alist-get 't first)) (alist-get 't first))))
      (float-time (file-attribute-modification-time (file-attributes file)))))

(defun vigil-archive-sessions ()
  "The archived sessions, newest first: plists from the index and the files.
A session file with no index line is listed too, from what its name says."
  (let ((files (make-hash-table :test #'equal))
        (sessions nil))
    (when (file-directory-p vigil-archive-directory)
      (dolist (file (directory-files-recursively vigil-archive-directory
                                                 "\\`[^.].*\\.jsonl\\'"))
        (unless (equal (file-name-nondirectory file) "index.jsonl")
          (puthash (file-name-base file) file files))))
    (dolist (entry (vigil-archive--lines
                    (expand-file-name "index.jsonl" vigil-archive-directory)))
      (let* ((id (alist-get 'session_id entry))
             (file (and (stringp id) (gethash id files))))
        (when file
          (remhash id files)
          (push (list :id id :file file :started (alist-get 'started entry)
                      :host (alist-get 'host entry)
                      ;; `coterie' is what the flag was called in archives
                      ;; written before this was a package of its own.
                      :hosted (or (alist-get 'hosted entry) (alist-get 'coterie entry))
                      :cwd (alist-get 'cwd entry) :branch (alist-get 'git_branch entry)
                      :commit (alist-get 'git_commit entry) :model (alist-get 'model entry))
                sessions))))
    (maphash (lambda (id file)
               (push (list :id id :file file :started (vigil-archive--first-time file))
                     sessions))
             files)
    (sort sessions (lambda (a b) (> (or (plist-get a :started) 0)
                                    (or (plist-get b :started) 0))))))

;;;; Opening a session

(defun vigil-archive--load (session)
  "A hidden buffer holding SESSION's events, as an agent buffer holds its own."
  (let ((buffer (get-buffer-create (format " *vigil archive: %s*" (plist-get session :id))))
        (n 0))
    (with-current-buffer buffer
      (vigil--reset)
      (dolist (line (vigil-archive--lines (plist-get session :file)))
        (let ((event (alist-get 'event line)))
          (when (consp event)
            ;; Seconds, made distinct and in order: the lines are.
            (vigil--take-report
             event (+ (or (alist-get 't line) 0) (* 1e-4 (cl-incf n)))
             (format "line-%d" n))))))
    buffer))

(defun vigil-archive--title (session)
  "A few words naming SESSION."
  (format "%s %s%s"
          (if (plist-get session :started)
              (format-time-string "%Y-%m-%d %H:%M" (plist-get session :started))
            "")
          (if (plist-get session :cwd)
              (file-name-nondirectory (directory-file-name (plist-get session :cwd)))
            (plist-get session :id))
          (if (plist-get session :host) (format " (%s)" (plist-get session :host)) "")))

(defun vigil-archive-open (session)
  "Show what SESSION's agent was given, read-only, as `vigil-context' does."
  (let* ((data (vigil-archive--load session))
         (buffer (get-buffer-create (format "*archive: %s*" (vigil-archive--title session)))))
    (with-current-buffer buffer
      (vigil-context-mode)
      (setq vigil--context-agent data
            vigil--context-title (vigil-archive--title session))
      ;; What was read of the session goes when what shows it does.
      (add-hook 'kill-buffer-hook
                (lambda () (when (buffer-live-p data) (kill-buffer data)))
                nil t)
      (vigil--context-render)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

;;;; The list

(defvar vigil-archive-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-archive-open-at-point)
    (define-key map (kbd "e") #'vigil-archive-export-at-point)
    map)
  "Keys of `vigil-archive-mode'.")

(define-derived-mode vigil-archive-mode tabulated-list-mode "Archive"
  "The archived sessions, newest first.
\\{vigil-archive-mode-map}"
  (setq tabulated-list-format [("Started" 16 t) ("Project" 20 t) ("Agent" 18 t)
                               ("Branch" 14 t) ("Prompts" 7 nil :right-align t)
                               ("Calls" 6 nil :right-align t)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'vigil-archive--entries nil t)
  (tabulated-list-init-header))

(defun vigil-archive--entries ()
  "Set `tabulated-list-entries' from the archive."
  (setq tabulated-list-entries
        (mapcar (lambda (session)
                  (let ((count (vigil-archive--count (plist-get session :file))))
                    (list session
                          (vector (if (plist-get session :started)
                                      (format-time-string "%Y-%m-%d %H:%M"
                                                          (plist-get session :started))
                                    "")
                                  (if (plist-get session :cwd)
                                      (file-name-nondirectory
                                       (directory-file-name (plist-get session :cwd)))
                                    "")
                                  (or (plist-get session :host)
                                      (if (plist-get session :hosted) "" "(not hosted)"))
                                  (or (plist-get session :branch) "")
                                  (number-to-string (car count))
                                  (number-to-string (cdr count))))))
                (vigil-archive-sessions))))

;;;###autoload
(defun vigil-archive ()
  "List the archived sessions."
  (interactive)
  (let ((buffer (get-buffer-create "*vigil archive*")))
    (with-current-buffer buffer
      (vigil-archive-mode)
      (vigil-archive--entries)
      (tabulated-list-print))
    (pop-to-buffer buffer)
    buffer))

(defun vigil-archive-open-at-point ()
  "Open the session on this line."
  (interactive)
  (vigil-archive-open (or (tabulated-list-get-id) (user-error "No session here"))))

(defun vigil-archive-export-at-point (file)
  "Export the session on this line to FILE, for evals."
  (interactive (list (read-file-name "Export to: " nil nil nil "vigil-session.jsonl")))
  (vigil-archive-export file (list (or (tabulated-list-get-id)
                                         (user-error "No session here")))))

;;;; Export

(defun vigil-archive--call-summary (pre post)
  "One tool call, from its PRE and POST events, as an export row has it."
  (let* ((event (or post pre))
         ;; The tool is named as its agent names it; what it was about is
         ;; found by the names vigil knows.
         (ours (vigil--in-our-words event))
         (call (vigil-call--make :name (alist-get 'tool_name ours)
                                   :input (alist-get 'tool_input ours)
                                   :cwd (alist-get 'cwd event)))
         (response (alist-get 'tool_response post)))
    `((tool . ,(or (alist-get 'tool_name event) "?"))
      (summary . ,(vigil--summary call))
      (agent_id . ,(alist-get 'agent_id event))
      (status . ,(cond ((null post) "unfinished")
                       ((and (consp response) (alist-get 'interrupted response))
                        "interrupted")
                       (t "done")))
      (duration_s . ,(let ((ms (alist-get 'duration_ms post)))
                       (and (numberp ms) (/ ms 1000.0)))))))

(defun vigil-archive--rows (session)
  "SESSION's prompts, each with what followed it, as export rows (alists).
A turn runs from a prompt the user gave to the next one; prompts the agent
gives itself stay inside the turn they arrive in."
  (let ((rows nil) (turn nil) (n 0) (last-time nil))
    (cl-flet ((close ()
                (when turn
                  (let* ((calls (nreverse (plist-get turn :order)))
                         (table (plist-get turn :calls)))
                    (push `((schema . "vigil.prompt.v1")
                            (session_id . ,(plist-get session :id))
                            (host . ,(plist-get session :host))
                            (hosted . ,(if (plist-get session :hosted) t :false))
                            (cwd . ,(plist-get session :cwd))
                            (git_branch . ,(plist-get session :branch))
                            (git_commit . ,(plist-get session :commit))
                            (model . ,(plist-get session :model))
                            (turn . ,(plist-get turn :n))
                            (prompt . ,(plist-get turn :prompt))
                            (prompt_time . ,(plist-get turn :time))
                            (reply . ,(plist-get turn :reply))
                            (reply_time . ,(plist-get turn :reply-time))
                            (seconds . ,(let ((end (or (plist-get turn :reply-time) last-time)))
                                          (and end (- end (plist-get turn :time)))))
                            (tool_calls . ,(vconcat
                                            (mapcar (lambda (id)
                                                      (let ((pair (gethash id table)))
                                                        (vigil-archive--call-summary
                                                         (car pair) (cdr pair))))
                                                    calls)))
                            (subagents . ,(vconcat (nreverse (plist-get turn :subagents))))
                            (label . ((outcome) (score) (notes))))
                          rows)))
                (setq turn nil)))
      (dolist (line (vigil-archive--lines (plist-get session :file)))
        (let* ((event (vigil-base-settled (alist-get 'event line)))
               (time (alist-get 't line))
               (name (alist-get 'hook_event_name event))
               (agent (alist-get 'agent_id event)))
          (when (numberp time) (setq last-time time))
          (cond
           ((and (equal name "UserPromptSubmit") (null agent)
                 (stringp (alist-get 'prompt event))
                 (not (vigil--injected-p (alist-get 'prompt event))))
            (close)
            (setq turn (list :n (cl-incf n) :prompt (alist-get 'prompt event) :time time
                             :calls (make-hash-table :test #'equal) :order nil)))
           ((null turn))
           ((member name '("PreToolUse" "PostToolUse"))
            (let* ((id (or (alist-get 'tool_use_id event) (format "line-%s" time)))
                   (pair (or (gethash id (plist-get turn :calls))
                             (progn (plist-put turn :order (cons id (plist-get turn :order)))
                                    (puthash id (cons nil nil) (plist-get turn :calls))))))
              (if (equal name "PreToolUse") (setcar pair event) (setcdr pair event))))
           ((equal name "SubagentStop")
            (plist-put turn :subagents
                       (cons `((agent_id . ,agent)
                               (agent_type . ,(alist-get 'agent_type event))
                               (result . ,(alist-get 'last_assistant_message event)))
                             (plist-get turn :subagents))))
           ((and (equal name "Stop") (null agent))
            (plist-put turn :reply (alist-get 'last_assistant_message event))
            (plist-put turn :reply-time time)))))
      (close))
    (nreverse rows)))

;;;###autoload
(defun vigil-archive-export (file &optional sessions)
  "Write a dataset for evals to FILE: one JSON line per prompt.
From every archived session, or from SESSIONS.  The schema is in the
README; `label' is left empty, for labelling."
  (interactive (list (read-file-name "Export to: " nil nil nil
                                     (format-time-string "vigil-prompts-%Y%m%d.jsonl"))))
  (let ((count 0))
    (with-temp-file file
      (dolist (session (or sessions (vigil-archive-sessions)))
        (dolist (row (vigil-archive--rows session))
          (insert (json-serialize row :null-object nil :false-object :false) "\n")
          (cl-incf count))))
    (message "Wrote %d prompts to %s" count file)
    count))

(provide 'vigil-archive)
;;; vigil-archive.el ends here
