;;; vigil-survey-tests.el --- Objectives and subagents, read by session -*- lexical-binding: t; -*-

;; Reports written the way `vigil hook' writes them -- one JSON file an
;; event, in a directory named for the session -- in a directory of the
;; test's own.  The shapes are the ones Claude Code reports: a subagent's
;; calls carry its `agent_id', the call that launched one is answered with
;; its `agentId', and a start is not always reported.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-survey-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-survey)

(defvar vigil-directory)
(defvar vigil-survey-tests--count 0)

(defun vigil-survey-tests--write (session report)
  "Write REPORT, an alist or a string, as SESSION's next report."
  (let* ((directory (expand-file-name session vigil-directory))
         (n (cl-incf vigil-survey-tests--count))
         (file (expand-file-name (format "%d-%05d-1.json" (+ 1700000000 n) n) directory)))
    (make-directory directory t)
    (with-temp-file file
      (insert (if (stringp report) report (json-serialize report))))
    (set-file-times file (seconds-to-time (+ 1700000000 n)))
    file))

(defmacro vigil-survey-tests--with (&rest body)
  "Run BODY with `vigil-directory' an empty directory, and nothing read yet."
  (declare (indent 0))
  `(let ((vigil-directory (make-temp-file "vigil-survey" t))
         (vigil-survey-tests--count 0))
     (vigil-survey-forget)
     (unwind-protect (progn ,@body)
       (delete-directory vigil-directory t)
       (vigil-survey-forget))))

(defun vigil-survey-tests--call (event tool id input &rest more)
  "A report of the call ID to TOOL with INPUT: EVENT, and MORE of it."
  `((hook_event_name . ,event) (tool_name . ,tool) (tool_use_id . ,id)
    (tool_input . ,input) ,@more))

(ert-deftest vigil-survey-nothing-there ()
  "A session with no reports, or no name fit to be one, has nothing and signals nothing."
  (vigil-survey-tests--with
    (dolist (session '("coterie.none.1" "" "../etc" "a/b" "." nil 7))
      (should-not (vigil-survey-objective session))
      (should-not (vigil-survey-objectives session))
      (should-not (vigil-survey-subagents session))
      (should-not (vigil-survey-turns session)))))

(ert-deftest vigil-survey-todos ()
  "The list TodoWrite gives: the item in progress, and how far along."
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PreToolUse" "TodoWrite" "t1"
          '((todos . [((content . "Read the parser") (status . "completed"))
                      ((content . "Fix the parser") (status . "in_progress"))
                      ((content . "Test it") (status . "pending"))]))))
    (should (equal (vigil-survey-objective "s")
                   '(:text "Fix the parser" :done 1 :total 3)))
    (should (equal (mapcar (lambda (o) (plist-get o :status)) (vigil-survey-objectives "s"))
                   '("completed" "in_progress" "pending")))
    ;; A later list replaces it; one with everything done is no objective.
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PreToolUse" "TodoWrite" "t2"
          '((todos . [((content . "Read the parser") (status . "completed"))
                      ((content . "Fix the parser") (status . "completed"))]))))
    (should-not (vigil-survey-objective "s"))
    (should (= 2 (length (vigil-survey-objectives "s"))))))

(ert-deftest vigil-survey-todos-of-a-subagent-are-not-its-agents ()
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PreToolUse" "TodoWrite" "t1"
          '((todos . [((content . "Its own") (status . "in_progress"))]))
          '(agent_id . "a1")))
    (should-not (vigil-survey-objective "s"))))

(ert-deftest vigil-survey-tasks ()
  "Tasks made and updated one at a time."
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "TaskCreate" "c1" '((subject . "Scope it"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskCreate" "c1" '((subject . "Scope it"))
                                   '(tool_response . ((task . ((id . "7")))))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskCreate" "c2" '((subject . "Build it"))
                                   '(tool_response . ((task . ((id . "8")))))))
    (should (equal (vigil-survey-objective "s") '(:text "Scope it" :done 0 :total 2)))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskUpdate" "u1"
                                   '((taskId . "7") (status . "completed"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskUpdate" "u2"
                                   '((taskId . "8") (status . "in_progress"))))
    (should (equal (vigil-survey-objective "s") '(:text "Build it" :done 1 :total 2)))
    ;; An id nothing was told of: the place in the list, if it is a number.
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskUpdate" "u3"
                                   '((taskId . "2") (status . "completed"))))
    (should-not (vigil-survey-objective "s"))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "TaskUpdate" "u4"
                                   '((taskId . "nonsense") (status . "pending"))))
    (should-not (vigil-survey-objective "s"))))

(ert-deftest vigil-survey-subagent-waited-for ()
  "A subagent its agent waits for: running with what it was asked, then done."
  (vigil-survey-tests--with
    (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Go")))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PreToolUse" "Agent" "launch"
          '((description . "Find the callers") (subagent_type . "Explore")
            (prompt . "Look for every caller of foo"))))
    ;; No SubagentStart: its first call is the first that is heard of it.
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Grep" "g1" '((pattern . "foo("))
                                   '(agent_id . "a1") '(agent_type . "Explore")))
    (let ((subagent (car (vigil-survey-subagents "s"))))
      (should (= 1 (length (vigil-survey-subagents "s"))))
      (should (eq 'running (plist-get subagent :status)))
      (should (equal "Explore" (plist-get subagent :type)))
      (should (equal "Find the callers" (plist-get subagent :asked)))
      (should (= 1 (plist-get subagent :calls)))
      (should (equal "Grep foo(" (plist-get subagent :doing)))
      (should-not (plist-get subagent :end)))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "Grep" "g1" '((pattern . "foo("))
                                   '(agent_id . "a1") '(tool_response . ((numFiles . 2)))))
    (vigil-survey-tests--write
     "s" '((hook_event_name . "SubagentStop") (agent_id . "a1") (agent_type . "Explore")
           (last_assistant_message . "Two callers.\nBoth in bar.el.")))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PostToolUse" "Agent" "launch" '((description . "Find the callers"))
          '(tool_response . ((agentId . "a1") (status . "completed")))))
    (let ((subagent (car (vigil-survey-subagents "s"))))
      (should (= 1 (length (vigil-survey-subagents "s"))))
      (should (eq 'done (plist-get subagent :status)))
      (should (equal "Two callers." (plist-get subagent :result)))
      (should (equal "Find the callers" (plist-get subagent :asked)))
      (should (= 1 (plist-get subagent :calls)))
      (should-not (plist-get subagent :doing))
      (should (plist-get subagent :end)))))

(ert-deftest vigil-survey-subagent-in-the-background ()
  "One not waited for runs on past its agent's reply, until it says it is done."
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PostToolUse" "Agent" "launch" '((description . "Run the suite"))
          '(tool_response . ((agentId . "b1") (status . "async_launched")))))
    (vigil-survey-tests--write "s" '((hook_event_name . "SubagentStart") (agent_id . "b1")))
    (vigil-survey-tests--write "s" '((hook_event_name . "Stop") (last_assistant_message . "Started.")))
    (let ((subagent (car (vigil-survey-subagents "s"))))
      (should (eq 'running (plist-get subagent :status)))
      (should (plist-get subagent :background))
      (should (equal "Run the suite" (plist-get subagent :asked))))
    (vigil-survey-tests--write "s" '((hook_event_name . "SubagentStop") (agent_id . "b1")))
    (should (eq 'done (plist-get (car (vigil-survey-subagents "s")) :status)))))

(ert-deftest vigil-survey-subagent-left-behind ()
  "One waited for that never said it was done, its agent gone on: interrupted."
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Agent" "launch" '((description . "Dig"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Read" "r1" '((file_path . "/x/y.el"))
                                   '(agent_id . "a1")))
    (should (eq 'running (plist-get (car (vigil-survey-subagents "s")) :status)))
    (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Stop that")))
    (should (eq 'interrupted (plist-get (car (vigil-survey-subagents "s")) :status)))))

(ert-deftest vigil-survey-two-at-once ()
  "Two subagents out together are each given the call of their own type."
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Agent" "l1"
                                   '((description . "Plan it") (subagent_type . "Plan"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Agent" "l2"
                                   '((description . "Search it") (subagent_type . "Explore"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Grep" "g" '((pattern . "x"))
                                   '(agent_id . "e") '(agent_type . "Explore")))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Read" "r" '((file_path . "/a"))
                                   '(agent_id . "p") '(agent_type . "Plan")))
    (let ((subagents (vigil-survey-subagents "s")))
      (should (equal '(("e" . "Search it") ("p" . "Plan it"))
                     (mapcar (lambda (s) (cons (plist-get s :id) (plist-get s :asked)))
                             subagents))))))

(ert-deftest vigil-survey-reads-a-report-once ()
  "What was read is kept: only new files are read again."
  (vigil-survey-tests--with
    (let ((reads 0))
      (cl-letf* ((read (symbol-function 'vigil-survey--read))
                 ((symbol-function 'vigil-survey--read)
                  (lambda (file) (cl-incf reads) (funcall read file))))
        (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "One")))
        (vigil-survey-tests--write "s" '((hook_event_name . "Stop")))
        (vigil-survey-turns "s")
        (vigil-survey-subagents "s")
        (vigil-survey-objective "s")
        (should (= 2 reads))
        (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Two")))
        (should (= 2 (length (vigil-survey-turns "s"))))
        (should (= 3 reads))))))

(ert-deftest vigil-survey-a-new-conversation-starts-afresh ()
  (vigil-survey-tests--with
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call
          "PreToolUse" "TodoWrite" "t1"
          '((todos . [((content . "Old") (status . "in_progress"))]))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Read" "r1" '((file_path . "/a"))
                                   '(agent_id . "a1")))
    (should (vigil-survey-objective "s"))
    (should (vigil-survey-subagents "s"))
    ;; Resumed: the same conversation, and its record stays.
    (vigil-survey-tests--write "s" '((hook_event_name . "SessionStart") (source . "resume")))
    (should (vigil-survey-objective "s"))
    (vigil-survey-tests--write "s" '((hook_event_name . "SessionStart") (source . "startup")))
    (should-not (vigil-survey-objective "s"))
    (should-not (vigil-survey-subagents "s"))
    (should (= 1 (length (car (vigil-survey-turns "s")))))))

(ert-deftest vigil-survey-reports-gone-are-forgotten-not-missed ()
  "Reports pruned from under it leave what was read of them."
  (vigil-survey-tests--with
    (let ((file (vigil-survey-tests--write
                 "s" (vigil-survey-tests--call
                      "PreToolUse" "TodoWrite" "t1"
                      '((todos . [((content . "Keep") (status . "in_progress"))]))))))
      (should (vigil-survey-objective "s"))
      (delete-file file)
      (should (equal "Keep" (plist-get (vigil-survey-objective "s") :text))))))

(ert-deftest vigil-survey-what-cannot-be-read-is-passed-over ()
  "Garbage, and reports of shapes not expected, cost themselves and no more."
  (vigil-survey-tests--with
    (vigil-survey-tests--write "s" "not json {")
    (vigil-survey-tests--write "s" "[1, 2, 3]")
    (vigil-survey-tests--write "s" "")
    (vigil-survey-tests--write "s" '((hook_event_name . 7)))
    (vigil-survey-tests--write "s" '((hook_event_name . "PreToolUse")))
    (vigil-survey-tests--write "s" '((hook_event_name . "PreToolUse") (tool_name . 3)
                                     (tool_use_id . 9) (tool_input . "a string")
                                     (agent_id . 4)))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "TodoWrite" "t0" '((todos . "none"))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "TodoWrite" "t1"
                                   '((todos . [7 "x" ((status . "pending"))
                                               ((content . "Real") (status . "pending"))]))))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "Agent" "l" "odd"
                                   '(tool_response . "a string")))
    (vigil-survey-tests--write "s" '((hook_event_name . "SubagentStop")))
    (vigil-survey-tests--write "s" '((hook_event_name . "NotAnEvent") (agent_id . "z")))
    (should (equal (vigil-survey-objective "s") '(:text "Real" :done 0 :total 1)))
    (should-not (vigil-survey-subagents "s"))
    (should (listp (vigil-survey-turns "s")))))

(ert-deftest vigil-survey-turns ()
  "Turns begin at prompts; a subagent's calls are in the turn they happened in."
  (vigil-survey-tests--with
    (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "First")))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "Bash" "b1"
                                   '((command . "make test") (description . "Run the tests"))
                                   '(tool_response . ((exit_code . 2)))))
    (vigil-survey-tests--write "s" '((hook_event_name . "Stop") (last_assistant_message . "Failed.")))
    (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Second")))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PreToolUse" "Edit" "e1" '((file_path . "/src/a.el"))))
    (let ((turns (vigil-survey-turns "s")))
      (should (= 2 (length turns)))
      (should (equal '(prompt command reply)
                     (mapcar #'vigil-survey-step-kind (car turns))))
      (should (eq 'failed (vigil-survey-step-status (nth 1 (car turns)))))
      (should (equal "Run the tests" (vigil-survey-step-text (nth 1 (car turns)))))
      (should (equal '(prompt edit) (mapcar #'vigil-survey-step-kind (cadr turns))))
      (should (equal "a.el" (vigil-survey-step-text (nth 1 (cadr turns)))))
      (should (equal (vigil-survey-turns "s" 1) (last turns))))))

(ert-deftest vigil-survey-sessions ()
  (vigil-survey-tests--with
    (vigil-survey-tests--write "one" '((hook_event_name . "Stop")))
    (vigil-survey-tests--write "two" '((hook_event_name . "Stop")))
    (should (equal '("one" "two") (sort (vigil-survey-sessions) #'string<)))))

(provide 'vigil-survey-tests)
;;; vigil-survey-tests.el ends here
