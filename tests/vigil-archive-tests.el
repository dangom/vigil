;;; vigil-archive-tests.el --- The archive, from Emacs's side -*- lexical-binding: t; -*-

;; An archive written the way `vigil hook' writes it, in a directory of
;; the test's own.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-archive-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-archive)

(defun vigil-archive-tests--line (time event &optional host)
  "An archive line: EVENT at TIME, from HOST."
  (concat (json-serialize `((t . ,time) (host . ,(or host "proj.1"))
                            (hosted . t) (event . ,event)))
          "\n"))

(defmacro vigil-archive-tests--with-archive (&rest body)
  "Run BODY with `vigil-archive-directory' holding two sessions."
  (declare (indent 0))
  `(let ((vigil-archive-directory (make-temp-file "vigil-archive" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "2026/11" vigil-archive-directory) t)
           (with-temp-file (expand-file-name "2026/11/s1.jsonl" vigil-archive-directory)
             (insert
              (vigil-archive-tests--line 1700000000 '((session_id . "s1") (hook_event_name . "SessionStart") (source . "startup")))
              (vigil-archive-tests--line 1700000001 '((session_id . "s1") (hook_event_name . "UserPromptSubmit") (prompt . "fix the bug")))
              (vigil-archive-tests--line 1700000002 '((session_id . "s1") (hook_event_name . "PreToolUse") (tool_name . "Bash") (tool_use_id . "b1") (tool_input (command . "make test"))))
              (vigil-archive-tests--line 1700000004 '((session_id . "s1") (hook_event_name . "PostToolUse") (tool_name . "Bash") (tool_use_id . "b1") (tool_input (command . "make test")) (tool_response (stdout . "1 failed")) (duration_ms . 1500)))
              (vigil-archive-tests--line 1700000005 '((session_id . "s1") (hook_event_name . "SubagentStart") (agent_id . "a1") (agent_type . "Explore")))
              (vigil-archive-tests--line 1700000006 '((session_id . "s1") (hook_event_name . "PostToolUse") (agent_id . "a1") (tool_name . "Grep") (tool_use_id . "g1") (tool_input (pattern . "TODO")) (tool_response (filenames . ["a.c"]))))
              (vigil-archive-tests--line 1700000007 '((session_id . "s1") (hook_event_name . "SubagentStop") (agent_id . "a1") (agent_type . "Explore") (last_assistant_message . "Found it in a.c.")))
              "this line is not JSON\n"
              (vigil-archive-tests--line 1700000008 '((session_id . "s1") (hook_event_name . "UserPromptSubmit") (prompt . "<task-notification>done</task-notification>")))
              (vigil-archive-tests--line 1700000010 '((session_id . "s1") (hook_event_name . "Stop") (last_assistant_message . "Fixed: a.c had a typo.")))
              (vigil-archive-tests--line 1700000020 '((session_id . "s1") (hook_event_name . "UserPromptSubmit") (prompt . "thanks")))
              (vigil-archive-tests--line 1700000021 '((session_id . "s1") (hook_event_name . "SomeFutureEvent") (whatever . 1)))
              (vigil-archive-tests--line 1700000022 '((session_id . "s1") (hook_event_name . "Stop") (last_assistant_message . "You're welcome.")))))
           (with-temp-file (expand-file-name "2026/11/s2.jsonl" vigil-archive-directory)
             (insert (vigil-archive-tests--line 1600000000 '((session_id . "s2") (hook_event_name . "UserPromptSubmit") (prompt . "old")))))
           (with-temp-file (expand-file-name "index.jsonl" vigil-archive-directory)
             (insert (json-serialize '((session_id . "s1") (started . 1700000000)
                                       ;; As archives written before this was
                                       ;; a package of its own say "hosted".
                                       (host . "proj.1") (coterie . t)
                                       (file . "2026/11/s1.jsonl") (cwd . "/src/proj")
                                       (git_branch . "main") (git_commit . "abc123")))
                     "\n"))
           ,@body)
       (delete-directory vigil-archive-directory t))))

(ert-deftest vigil-archive-lists-sessions-newest-first ()
  "Sessions come from the index, and from files the index does not name."
  (vigil-archive-tests--with-archive
    (let ((sessions (vigil-archive-sessions)))
      (should (equal (mapcar (lambda (s) (plist-get s :id)) sessions) '("s1" "s2")))
      (should (equal (plist-get (car sessions) :branch) "main"))
      (should (equal (vigil-archive--count (plist-get (car sessions) :file)) '(2 . 2))))
    (let ((list (vigil-archive)))
      (unwind-protect
          (with-current-buffer list
            (should (equal (aref (cadr (car tabulated-list-entries)) 1) "proj"))
            (should (equal (aref (cadr (car tabulated-list-entries)) 4) "2")))
        (kill-buffer list)))))

(ert-deftest vigil-archive-opens-a-session-as-its-context ()
  "A session opens read-only in the context view, in the order it happened."
  (vigil-archive-tests--with-archive
    (let ((view (vigil-archive-open (car (vigil-archive-sessions)))))
      (unwind-protect
          (with-current-buffer view
            (should buffer-read-only)
            (should (eq major-mode 'vigil-context-mode))
            (should (string-match-p "\\`What 2023-11-14 [0-9:]+ proj (proj.1) has been given"
                                    (buffer-string)))
            (let (headings)
              (save-excursion
                (goto-char (point-min))
                (while (re-search-forward "^\\(\\*+\\) [0-9:]+  \\([^ \n]+\\)" nil t)
                  (push (concat (match-string-no-properties 1) " " (match-string-no-properties 2)) headings)))
              (should (equal (nreverse headings)
                             '("* Session" "* Prompt" "* Bash" "* Agent" "** Grep"
                               "* Prompt" "* Reply" "* Prompt" "* Reply")))))
        (kill-buffer view)))))

(ert-deftest vigil-archive-exports-one-row-per-prompt ()
  "A row per prompt the user gave, with what followed it until the next."
  (vigil-archive-tests--with-archive
    (let ((file (make-temp-file "export" nil ".jsonl")))
      (unwind-protect
          (progn
            (should (= 3 (vigil-archive-export file)))
            (let ((rows (mapcar (lambda (line)
                                  (json-parse-string line :object-type 'alist
                                                     :array-type 'list :null-object nil))
                                (split-string (with-temp-buffer
                                                (insert-file-contents file)
                                                (buffer-string))
                                              "\n" t))))
              (let ((row (car rows)))
                (should (equal (alist-get 'schema row) "vigil.prompt.v1"))
                (should (equal (alist-get 'session_id row) "s1"))
                (should (equal (alist-get 'git_commit row) "abc123"))
                (should (equal (alist-get 'prompt row) "fix the bug"))
                (should (equal (alist-get 'reply row) "Fixed: a.c had a typo."))
                (should (equal (alist-get 'seconds row) 9))
                (should (equal (mapcar (lambda (c) (list (alist-get 'tool c) (alist-get 'summary c)
                                                         (alist-get 'agent_id c) (alist-get 'status c)
                                                         (alist-get 'duration_s c)))
                                       (alist-get 'tool_calls row))
                               '(("Bash" "make test" nil "done" 1.5)
                                 ("Grep" "TODO" "a1" "done" nil))))
                (should (equal (alist-get 'result (car (alist-get 'subagents row)))
                               "Found it in a.c."))
                (should (equal (alist-get 'label row) '((outcome) (score) (notes)))))
              (should (equal (mapcar (lambda (r) (alist-get 'prompt r)) rows)
                             '("fix the bug" "thanks" "old")))
              (should (equal (alist-get 'reply (cadr rows)) "You're welcome."))))
        (delete-file file)))))

(provide 'vigil-archive-tests)
;;; vigil-archive-tests.el ends here
