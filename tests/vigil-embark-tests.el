;;; vigil-embark-tests.el --- A call as one Embark target -*- lexical-binding: t; -*-

;; Reports written the way `vigil hook' writes them, read by an agent buffer
;; with no terminal behind it, as in vigil-tests.el.  Embark itself is not
;; needed: the finders and the commands are plain functions.  The one test
;; of what Embark is given is skipped without it.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-embark-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-transcript)
(require 'vigil-turn)
(require 'vigil-edits)
(require 'vigil-archive)
(require 'vigil-embark)
(require 'cooked)
(require 'cooked-annotate)
(require 'cooked-mode)
(require 'cooked-host)

(defvar vigil-embark-tests--n 0)

(defun vigil-embark-tests--write (directory report)
  "Write REPORT, an alist, into DIRECTORY as the hook does: named for when."
  (make-directory directory t)
  (with-temp-file (expand-file-name
                   (format "%d.%06d-1-%d.json" 1700000000
                           (cl-incf vigil-embark-tests--n) vigil-embark-tests--n)
                   directory)
    (insert (json-serialize report) "\n")))

(defun vigil-embark-tests--call (directory event id tool input &optional response)
  "Write the report of a tool call into DIRECTORY."
  (vigil-embark-tests--write
   directory
   `((hook_event_name . ,event) (tool_name . ,tool) (tool_use_id . ,id)
     (cwd . "/tmp/proj") (tool_input . ,input)
     ,@(and response `((tool_response . ,response))))))

(defconst vigil-embark-tests--conversation
  (concat "> list the files, then fix notes.txt\n"
          "I'll look at notes.txt after listing.\n"
          "* Bash(ls -la)\n"
          "  total 16\n"
          "* Update(notes.txt)\n"
          "  1 alpha\n"
          "> \n"))

(defmacro vigil-embark-tests--with-agent (&rest body)
  "Run BODY in the agent buffer of the session proj.1, `agent'.
It has run `ls -la' (the call t1) and edited `file' (t2), in one turn."
  (declare (indent 0))
  `(let* ((vigil-directory (make-temp-file "vigil" t))
          (dir (expand-file-name "proj.1" vigil-directory))
          (home (make-temp-file "vigil-embark" t))
          (file (expand-file-name "notes.txt" home))
          (agent (generate-new-buffer "*agent*")))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer agent
             (cooked-mode)
             (let ((inhibit-read-only t)) (insert vigil-embark-tests--conversation))
             (setq cooked-host-name "proj.1")
             (with-temp-file file (insert "alpha\nBETA\n"))
             (vigil-embark-tests--write dir '((hook_event_name . "UserPromptSubmit")
                                              (prompt . "list the files")))
             (vigil-embark-tests--call dir "PostToolUse" "t1" "Bash"
                                       '((command . "ls -la"))
                                       '((stdout . "total 16") (stderr . "")))
             (vigil-embark-tests--call
              dir "PostToolUse" "t2" "Edit"
              `((file_path . ,file) (old_string . "beta") (new_string . "BETA"))
              `((filePath . ,file) (originalFile . "alpha\nbeta\n")
                (structuredPatch . [((oldStart . 1) (oldLines . 2)
                                     (newStart . 1) (newLines . 2)
                                     (lines . [" alpha" "-beta" "+BETA"]))])))
             (vigil-mode 1)
             (vigil--scan agent)
             ,@body))
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p home (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (when (buffer-live-p agent)
         (with-current-buffer agent (vigil--stop))
         (kill-buffer agent))
       (delete-directory home t)
       (delete-directory vigil-directory t))))

(defun vigil-embark-tests--goto-heading (regexp)
  "Go to the heading of the context buffer matching REGEXP."
  (goto-char (point-min))
  (re-search-forward regexp)
  (beginning-of-line))

;;;; The name of a call

(ert-deftest vigil-embark-resolves-a-call-by-its-name ()
  "A call's name gives the call and its agent's buffer back; a session with no
live buffer, a call that is not there and a name that is none are errors."
  (vigil-embark-tests--with-agent
    (let ((call (gethash "t1" vigil--calls)))
      (should (equal (vigil-embark--name call agent) "proj.1/t1"))
      (should (equal (vigil-embark--resolve "proj.1/t1") (cons call agent)))
      (should-error (vigil-embark--resolve "proj.1/nope") :type 'user-error)
      (should-error (vigil-embark--resolve "gone.1/t1") :type 'user-error)
      (should-error (vigil-embark--resolve "t1") :type 'user-error)
      ;; An id with a slash in it is still the session's.
      (puthash "a/b" call vigil--calls)
      (should (eq (car (vigil-embark--resolve "proj.1/a/b")) call))))
  ;; Its buffer gone, the session is not live.
  (should-error (vigil-embark--resolve "proj.1/t1") :type 'user-error))

(ert-deftest vigil-embark-names-a-group-and-a-subagent-by-a-call ()
  "A group is its first call; a subagent the call that launched it, and
nothing until that is known.  An archived session's calls have no name."
  (vigil-embark-tests--with-agent
    (let ((t1 (gethash "t1" vigil--calls))
          (t2 (gethash "t2" vigil--calls)))
      (should (equal (vigil-embark--name (list t1 t2) agent) "proj.1/t1"))
      (vigil-embark-tests--call dir "PreToolUse" "a1" "Agent"
                                '((description . "look") (subagent_type . "Explore")))
      (vigil-embark-tests--write dir '((hook_event_name . "SubagentStart")
                                       (agent_id . "sub1") (agent_type . "Explore")))
      (vigil--scan agent)
      (let ((subagent (gethash "sub1" vigil--subagents)))
        (should-not (vigil-embark--name subagent agent))
        ;; Nor is its heading in the context a target.
        (let ((context (vigil-context agent)))
          (unwind-protect
              (with-current-buffer context
                (vigil-embark-tests--goto-heading "Agent  \\[Explore\\] sub1")
                (should-not (vigil-embark-target-call)))
            (kill-buffer context)))
        (vigil-embark-tests--call dir "PostToolUse" "a1" "Agent"
                                  '((description . "look") (subagent_type . "Explore"))
                                  '((status . "completed") (agentId . "sub1")))
        (vigil--scan agent)
        (should (equal (vigil-embark--name subagent agent) "proj.1/a1")))
      ;; A buffer that is no session's: an archived one's.
      (with-temp-buffer
        (should-not (vigil-embark--name t1 (current-buffer)))))))

;;;; Finding it

(ert-deftest vigil-embark-finds-the-call-in-the-context ()
  "On a call's heading, or in its body, the target is the call, bounded by
its heading; on a prompt there is none."
  (vigil-embark-tests--with-agent
    (let ((context (vigil-context agent)))
      (unwind-protect
          (with-current-buffer context
            (vigil-embark-tests--goto-heading "Bash  ls -la")
            (let ((bounds (cons (line-beginning-position) (line-end-position))))
              (should (equal (vigil-embark-target-call)
                             `(vigil-call "proj.1/t1" ,(car bounds) . ,(cdr bounds))))
              (outline-show-all)
              (forward-line 1)
              (should (equal (vigil-embark-target-call)
                             `(vigil-call "proj.1/t1" ,(car bounds) . ,(cdr bounds)))))
            (vigil-embark-tests--goto-heading "Prompt")
            (should-not (vigil-embark-target-call)))
        (kill-buffer context)))))

(ert-deftest vigil-embark-finds-the-call-in-a-turn ()
  "On a row of a turn's list, the target is that row's call."
  (vigil-embark-tests--with-agent
    (let ((turn (vigil-turn-show agent 1 (gethash "t2" vigil--calls))))
      (with-current-buffer turn
        (should (equal (vigil-embark-target-call)
                       `(vigil-call "proj.1/t2" ,(line-beginning-position)
                                    . ,(line-end-position))))
        (goto-char (point-max))
        (should-not (vigil-embark-target-call))))))

(ert-deftest vigil-embark-finds-the-call-where-else-it-shows ()
  "In the conversation, on the line it is marked on; in the frame it is
inspected in; and in the file it edited, on a line it wrote."
  (vigil-embark-tests--with-agent
    (let ((t1 (gethash "t1" vigil--calls))
          (t2 (gethash "t2" vigil--calls)))
      ;; The conversation.
      (should (vigil-call-annotation t1))
      (goto-char (cooked-annotation-beg (vigil-call-annotation t1)))
      (should (equal (take 2 (vigil-embark-target-call)) '(vigil-call "proj.1/t1")))
      (goto-char (point-min))
      (should-not (vigil-embark-target-call))
      ;; The frame.
      (with-current-buffer (vigil-inspect t1 agent)
        (should (equal (take 2 (vigil-embark-target-call)) '(vigil-call "proj.1/t1"))))
      ;; The file: its second line is the edit's.
      (with-current-buffer (find-file-noselect file)
        (should vigil-edits-mode)
        (goto-char (point-min))
        (should-not (vigil-embark-target-call))
        (forward-line 1)
        (should (equal (take 2 (vigil-embark-target-call))
                       '(vigil-call "proj.1/t2")))))))

(ert-deftest vigil-embark-finds-the-call-of-a-running-command ()
  "On a row of the commands running, the target is the call whose command it
is; a row whose call is not known is none."
  (skip-unless (require 'vigil-running nil t))
  (vigil-embark-tests--with-agent
    (let ((started (vigil-call-start (gethash "t1" vigil--calls))))
      (with-temp-buffer
        (vigil-running-mode)
        (setq vigil-running-runs (make-hash-table :test #'equal)
              tabulated-list-entries
              (list (list "r1" (make-vector 8 "")) (list "r2" (make-vector 8 ""))))
        (puthash "r1" (cons (list :id "r1" :label "ls -la" :started started) agent)
                 vigil-running-runs)
        (puthash "r2" (cons (list :id "r2" :label "make" :started started) agent)
                 vigil-running-runs)
        (tabulated-list-print)
        (goto-char (point-min))
        (should (equal (take 2 (vigil-embark-target-call)) '(vigil-call "proj.1/t1")))
        (forward-line 1)
        (should-not (vigil-embark-target-call))))))

;;;; What is done to it

(ert-deftest vigil-embark-acts-on-a-call-by-its-name ()
  "Each action takes the call's name alone, as Embark gives it."
  (vigil-embark-tests--with-agent
    (let ((t1 (gethash "t1" vigil--calls))
          (t2 (gethash "t2" vigil--calls)))
      ;; Inspect.
      (with-current-buffer (vigil-embark-inspect "proj.1/t1")
        (should (eq vigil--popup-call t1))
        (should (string-match-p "^total 16$" (buffer-string))))
      ;; Its turn, on it.
      (with-current-buffer (vigil-embark-turn "proj.1/t2")
        (should (derived-mode-p 'vigil-turn-mode))
        (should (eq (tabulated-list-get-id) t2)))
      ;; What its turn changed.
      (with-current-buffer (vigil-embark-turn-diff "proj.1/t1")
        (should (derived-mode-p 'diff-mode))
        (should (string-match-p "^\\+BETA$" (buffer-string)))
        (kill-buffer))
      ;; Its line in the conversation.
      (vigil-embark-goto "proj.1/t1")
      (should (eq (current-buffer) agent))
      (should (looking-at-p "\\* Bash(ls -la)"))
      ;; The file it edited; a command edited none.
      (with-current-buffer (vigil-embark-visit "proj.1/t2")
        (should (equal (file-truename (buffer-file-name)) (file-truename file)))
        (should (= (line-number-at-pos) 1)))
      (should-error (vigil-embark-visit "proj.1/t1") :type 'user-error)
      ;; Copying: the command as given, or the input; and the result.
      (should (equal (vigil-embark-copy-command "proj.1/t1") "ls -la"))
      (should (equal (current-kill 0) "ls -la"))
      (should (string-match-p "\"old_string\"" (vigil-embark-copy-command "proj.1/t2")))
      (should (equal (vigil-embark-copy-result "proj.1/t1") "total 16"))
      (should (equal (current-kill 0) "total 16"))
      ;; Explaining a command; an edit is none.
      (with-current-buffer (vigil-embark-explain "proj.1/t1")
        (should (string-match-p "\\`ls -la\n" (buffer-string)))
        (kill-buffer))
      (should-error (vigil-embark-explain "proj.1/t2") :type 'user-error)
      ;; Pasting it at the agent's prompt.
      (let (pasted)
        (cl-letf (((symbol-function 'cooked-paste-string)
                   (lambda (text) (setq pasted (cons (current-buffer) text)))))
          (vigil-embark-paste "proj.1/t1")
          (should (equal pasted (cons agent "ls -la")))
          (should-error (vigil-embark-paste "proj.1/t2") :type 'user-error)))
      ;; Every one is a command, and says so of a call that is gone.
      (dolist (command '(vigil-embark-inspect vigil-embark-goto vigil-embark-turn
                         vigil-embark-turn-diff vigil-embark-visit
                         vigil-embark-copy-command vigil-embark-copy-result
                         vigil-embark-explain vigil-embark-paste))
        (should (commandp command))
        (should (eq (lookup-key vigil-embark-call-map
                                (where-is-internal command vigil-embark-call-map t))
                    command))
        (should-error (funcall command "proj.1/nope") :type 'user-error)))))

;;;; A session

(ert-deftest vigil-embark-finds-and-opens-a-session ()
  "A row of the archive's list is a session by its name: its agent's session's,
or its own id.  A live session opens as its buffer, and its context as
`vigil-context' shows it; the graph is asked for by the name."
  (vigil-embark-tests--with-agent
    (with-temp-buffer
      (vigil-archive-mode)
      (setq tabulated-list-entries
            (list (list '(:id "abc-1" :host "proj.1" :file "/nowhere") (make-vector 6 ""))
                  (list '(:id "abc-2" :file "/nowhere") (make-vector 6 ""))))
      (tabulated-list-print)
      (goto-char (point-min))
      (should (equal (vigil-embark-target-session)
                     `(vigil-session "proj.1" ,(line-beginning-position)
                                     . ,(line-end-position))))
      ;; The row's own archived session is the one acted on.
      (should (equal (vigil-embark--archived "proj.1")
                     '((:id "abc-1" :host "proj.1" :file "/nowhere"))))
      (forward-line 1)
      (should (equal (take 2 (vigil-embark-target-session)) '(vigil-session "abc-2")))
      (goto-char (point-max))
      (should-not (vigil-embark-target-session)))
    (should-not (vigil-embark-target-session))
    (vigil-embark-session-open "proj.1")
    (should (eq (current-buffer) agent))
    (let ((context (vigil-embark-session-context "proj.1")))
      (unwind-protect
          (should (eq (buffer-local-value 'vigil--context-agent context) agent))
        (kill-buffer context)))
    (let (graphed)
      (cl-letf (((symbol-function 'vigil-graph)
                 (lambda (session &rest _) (setq graphed session))))
        (vigil-embark-session-graph "proj.1")
        (should (equal graphed "proj.1"))))
    (let ((vigil-archive-directory (expand-file-name "none" vigil-directory)))
      (should-error (vigil-embark-session-open "gone.1") :type 'user-error)
      (should-error (vigil-embark-session-export "gone.1" "/dev/null")
                    :type 'user-error))))

;;;; Given to Embark

(ert-deftest vigil-embark-is-given-to-embark ()
  "With Embark: both types have their maps, over the general one, and the
finders come first; `embark-act' would find the call under point."
  (skip-unless (require 'embark nil t))
  (should (equal (alist-get 'vigil-call embark-keymap-alist) '(vigil-embark-call-map)))
  (should (equal (alist-get 'vigil-session embark-keymap-alist)
                 '(vigil-embark-session-map)))
  (should (eq (keymap-parent vigil-embark-call-map) embark-general-map))
  (should (eq (keymap-parent vigil-embark-session-map) embark-general-map))
  (should (eq (car embark-target-finders) #'vigil-embark-target-call))
  (should (eq (embark--default-action 'vigil-call) #'vigil-embark-inspect))
  (vigil-embark-tests--with-agent
    (let ((context (vigil-context agent)))
      (unwind-protect
          (with-current-buffer context
            (vigil-embark-tests--goto-heading "Bash  ls -la")
            (let ((target (car (embark--targets))))
              (should (eq (plist-get target :type) 'vigil-call))
              (should (equal (plist-get target :target) "proj.1/t1"))))
        (kill-buffer context)))))

(provide 'vigil-embark-tests)
;;; vigil-embark-tests.el ends here
