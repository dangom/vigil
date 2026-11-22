;;; vigil-tests.el --- An agent's tool calls, from Emacs's side -*- lexical-binding: t; -*-

;; Reports written the way `vigil hook' writes them, into a directory
;; of the test's own, read by an agent buffer that is a cooked buffer with no
;; terminal behind it -- its "conversation" is text the test inserts.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-transcript)
(require 'vigil-turn)
(require 'vigil-edits)
(require 'vigil-compile)
(require 'cooked)
(require 'cooked-annotate)
(require 'cooked-mode)
(require 'cooked-host)

(defvar vigil-tests--n 0)

(defun vigil-tests--write (directory event id tool input &optional response)
  "Write a report like the hook does: one JSON line, named for when."
  (make-directory directory t)
  (let ((file (expand-file-name
               (format "%d.%06d-1-%d.json" 1700000000 (cl-incf vigil-tests--n)
                       vigil-tests--n)
               directory)))
    (with-temp-file file
      (insert (json-serialize
               `((hook_event_name . ,event) (tool_name . ,tool) (tool_use_id . ,id)
                 (cwd . "/tmp/proj") (tool_input . ,input)
                 ,@(and response `((tool_response . ,response)))))
              "\n"))
    file))

(defmacro vigil-tests--with-agent (conversation &rest body)
  "Run BODY in an agent buffer showing CONVERSATION, its reports in `dir'."
  (declare (indent 1))
  `(let* ((vigil-directory (make-temp-file "vigil" t))
          (dir (expand-file-name "proj.1" vigil-directory))
          (buffer (generate-new-buffer "*agent*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (let ((inhibit-read-only t)) (insert ,conversation))
           (setq cooked-host-name "proj.1")
           (make-directory dir t)
           ,@body)
       (with-current-buffer buffer (vigil--stop))
       (kill-buffer buffer)
       (delete-directory vigil-directory t))))

(defun vigil-tests--headings (&optional visible)
  "The headings of the context buffer, without their times; VISIBLE, only those shown."
  (let (headings)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+\\) [0-9:]+  \\(.*\\)$" nil t)
        (unless (and visible (outline-invisible-p (match-beginning 0)))
          (push (concat (match-string-no-properties 1) " " (match-string-no-properties 2))
                headings))))
    (nreverse headings)))

(defun vigil-tests--line (call)
  "The text of the line CALL is marked on."
  (let ((annotation (vigil-call-annotation call)))
    (and annotation
         (save-excursion
           (goto-char (cooked-annotation-beg annotation))
           (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

(defconst vigil-tests--conversation
  (concat "> list the files, then fix notes.txt\n"
          "I'll look at notes.txt after listing.\n"
          "* Bash(ls -la)\n"
          "  total 16\n"
          "* Update(notes.txt)\n"
          "  1 alpha\n"
          "Now again.\n"
          "* Bash(ls -la)\n"
          "  total 16\n"
          "> \n"))

(ert-deftest vigil-reads-and-merges-reports ()
  "A Pre and a Post report of one call are one call; an unreadable report is
listed as such rather than dropped."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "t1" "Bash" '((command . "ls -la")))
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                                '((stdout . "total 16") (stderr . "") (interrupted . :false)))
    (with-temp-file (expand-file-name "1700000001.000000-1-1.json" dir)
      (insert "{\"tool_name\": \"Bash\", \"tool_inp"))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (should (= (length vigil--order) 2))
    (let ((call (car vigil--order)))
      (should (equal (vigil-call-name call) "Bash"))
      (should (equal (vigil--status call) "done"))
      (should (equal (alist-get 'stdout (vigil-call-response call)) "total 16")))
    (should (equal (vigil--status (cadr vigil--order)) "unreadable"))))

(ert-deftest vigil-marks-each-call-on-its-own-line ()
  "Each finished call is marked where its own words last show before the next
call's: a command run twice is marked twice, and a file named in prose before
it was edited is marked at the edit."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                                '((stdout . "total 16")))
    (vigil-tests--write dir "PostToolUse" "t2" "Edit"
                                '((file_path . "/tmp/proj/notes.txt")
                                  (old_string . "beta") (new_string . "BETA"))
                                '((filePath . "/tmp/proj/notes.txt")))
    (vigil-tests--write dir "PostToolUse" "t3" "Bash" '((command . "ls -la"))
                                '((stdout . "total 16")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((calls vigil--order))
      (should (equal (mapcar #'vigil-tests--line calls)
                     '("* Bash(ls -la)" "* Update(notes.txt)" "* Bash(ls -la)")))
      (should-not (eq (cooked-annotation-beg (vigil-call-annotation (nth 0 calls)))
                      (cooked-annotation-beg (vigil-call-annotation (nth 2 calls)))))
      (should (< (cooked-annotation-beg (vigil-call-annotation (nth 0 calls)))
                 (cooked-annotation-beg (vigil-call-annotation (nth 2 calls))))))))

(ert-deftest vigil-leaves-unfound-and-running-calls-unmarked ()
  "A call whose words are nowhere, or that has not finished, is listed and not
marked."
  (vigil-tests--with-agent vigil-tests--conversation
    (let ((vigil-anchor-tries 1))
      (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "make test"))
                                  '((stdout . "")))
      (vigil-tests--write dir "PreToolUse" "t2" "Bash" '((command . "ls -la")))
      (vigil-mode 1)
      (vigil--scan (current-buffer))
      (should (= (length vigil--order) 2))
      (should-not (cl-some #'vigil-call-annotation vigil--order))
      (should (equal (vigil--status (nth 1 vigil--order)) "running")))))

(ert-deftest vigil-diff-from-the-reported-patch ()
  "An edit's diff is the patch Claude Code reported, as a unified diff."
  (let ((call (vigil-call--make
               :name "Edit" :cwd "/tmp/proj"
               :input '((file_path . "/tmp/proj/notes.txt"))
               :response '((structuredPatch
                            ((oldStart . 1) (oldLines . 3) (newStart . 1) (newLines . 3)
                             (lines " alpha" "-beta" "+BETA" " gamma")))))))
    (should (equal (vigil-diff call)
                   (concat "--- a/notes.txt\n+++ b/notes.txt\n@@ -1,3 +1,3 @@\n"
                           " alpha\n-beta\n+BETA\n gamma\n")))))

(ert-deftest vigil-diff-without-a-patch ()
  "A new file is all additions; an edit with no patch reported is its
replacement; a multi-edit, each of its replacements."
  (should (equal (vigil-diff
                  (vigil-call--make
                   :name "Write" :cwd "/tmp/proj"
                   :input '((file_path . "/tmp/proj/new.txt") (content . "hello\nworld"))
                   :response '((type . "create") (structuredPatch))))
                 "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+hello\n+world\n"))
  (should (equal (vigil-diff
                  (vigil-call--make
                   :name "MultiEdit" :cwd "/tmp/proj"
                   :input '((file_path . "/tmp/proj/a.el")
                            (edits ((old_string . "x") (new_string . "y"))
                                   ((old_string . "p\nq") (new_string . "r"))))))
                 (concat "--- a/a.el\n+++ b/a.el\n"
                         "@@ -1,1 +1,1 @@\n-x\n+y\n"
                         "@@ -1,2 +1,1 @@\n-p\n-q\n+r\n"))))

(ert-deftest vigil-renders-read-only-and-never-evaluates ()
  "A command is shown highlighted as shell with its output; an edit, in
`diff-mode'; either read-only.  What a report says is only ever shown."
  (let ((evaluated nil))
    (with-temp-buffer
      (vigil--render
       (vigil-call--make
        :name "Bash" :cwd "/tmp"
        :input `((command . ,(format "echo \"%S\"" '(setq evaluated t)))
                 (description . "say it"))
        :response '((stdout . "\e[31mred\e[0m") (stderr . "oops"))))
      (should (eq major-mode 'vigil-view-mode))
      (should buffer-read-only)
      (should vigil-popup-mode)
      (should (eq (key-binding "q") #'vigil-popup-quit))
      (should (string-match-p "\\`\\$ echo" (buffer-string)))
      (should (string-match-p "^# say it$" (buffer-string)))
      (should (string-match-p "^red$" (buffer-string)))
      (should (eq (get-text-property (1+ (string-match "oops" (buffer-string))) 'face) 'error))
      (should-error (insert "x") :type 'buffer-read-only)
      (should-not evaluated))
    (with-temp-buffer
      (vigil--render
       (vigil-call--make
        :name "Edit" :cwd "/tmp"
        :input '((file_path . "/tmp/a") (old_string . "x") (new_string . "y"))
        :response '((filePath . "/tmp/a"))))
      (should (eq major-mode 'diff-mode))
      (should buffer-read-only)
      (should (string-match-p "^-x\n\\+y" (buffer-string))))
    (with-temp-buffer
      (vigil--render
       (vigil-call--make
        :name "TodoWrite" :input '((todos ((content . "a") (status . "completed"))
                                          ((content . "b") (status . "pending"))))
        :response '((ok . t))))
      (should (equal (buffer-string) "[x] a\n[ ] b\n")))))

(ert-deftest vigil-renders-an-image-read-not-its-base64 ()
  "An image a Read call read is shown as the image, never as its base64; and
base64 anywhere else is said, not shown -- nor does a long run of it stop a
call being drawn."
  (let* ((png (base64-encode-string (make-string 300000 ?x) t))
         (call (vigil-call--make
                :name "Read" :cwd "/tmp"
                :input '((file_path . "/tmp/plot.png"))
                :response `((type . "image")
                            (file (base64 . ,png) (type . "image/png")
                                  (originalSize . 362638)
                                  (dimensions (originalWidth . 3000) (originalHeight . 2244)
                                              (displayWidth . 2000) (displayHeight . 1496)))))))
    (with-temp-buffer
      (vigil--render call)
      (should vigil-popup-mode)
      (should-not (string-search (substring png 0 100) (buffer-string)))
      (should (string-match-p
               "^image/png  ·  3000×2244  ·  354k  ·  seen by the agent at 2000×1496$"
               (buffer-string))))
    ;; Base64 in a call nothing here knows: its size, in its place.
    (with-temp-buffer
      (vigil--render (vigil-call--make :name "mcp__shot" :cwd "/tmp"
                                       :input '((url . "x"))
                                       :response `((data . ,png))))
      (should-not (string-search (substring png 0 100) (buffer-string)))
      (should (string-search "<base64: 300000 bytes, not shown>" (buffer-string))))
    ;; And where it does get into a buffer, file names are still linked around it.
    (with-temp-buffer
      (insert png "\n/tmp\n")
      (vigil--link-files (point-min) (point-max) "/")
      (should-not (next-single-property-change (point-min) 'button)))))

(ert-deftest vigil-renders-what-it-does-not-know-as-json ()
  "A tool nothing here knows -- one added after this was written -- is shown
as its input and result, in JSON, rather than not at all."
  (with-temp-buffer
    (vigil--render
     (vigil-call--make :name "FutureTool"
                         :input '((knob . 3) (list . ("x" "y")))
                         :response '((answer . "fine") (nested (deep . t)))))
    (should (eq major-mode 'vigil-view-mode))
    (should buffer-read-only)
    (should (string-match-p "\"knob\": 3" (buffer-string)))
    (should (string-match-p "\"answer\": \"fine\"" (buffer-string)))))

(ert-deftest vigil-renders-web-calls ()
  "A fetch shows its address and what it found; a search, its query and results."
  (with-temp-buffer
    (vigil--render
     (vigil-call--make :name "WebFetch"
                         :input '((url . "https://example.org") (prompt . "title?"))
                         :response '((result . "Example Domain"))))
    (should (string-match-p "\\`WebFetch  https://example.org" (buffer-string)))
    (should (string-match-p "Example Domain" (buffer-string))))
  (with-temp-buffer
    (vigil--render
     (vigil-call--make :name "WebSearch" :input '((query . "emacs child frames"))
                         :response '((results ((title . "Child Frames")
                                               (url . "https://gnu.org/cf"))))))
    (should (string-match-p "WebSearch  emacs child frames" (buffer-string)))
    (should (string-match-p "- Child Frames\n  https://gnu.org/cf" (buffer-string)))))

(defun vigil-tests--write-raw (directory alist)
  "Write ALIST as a report, the way the hook would."
  (make-directory directory t)
  (with-temp-file (expand-file-name
                   (format "%d.%06d-1-%d.json" 1700000000 (cl-incf vigil-tests--n)
                           vigil-tests--n)
                   directory)
    (insert (json-serialize alist) "\n")))

(ert-deftest vigil-groups-a-subagent-under-its-launch ()
  "A backgrounded subagent: the Agent call names it in its result at once, its
own calls carry its id, and SubagentStop brings its result.  The list shows
it as a group under the launch, and folds it."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "a1" "Agent"
                                '((description . "count files") (prompt . "Run ls.")
                                  (subagent_type . "general-purpose")))
    (vigil-tests--write-raw dir '((hook_event_name . "SubagentStart")
                                          (agent_id . "sub1") (agent_type . "general-purpose")))
    (vigil-tests--write dir "PostToolUse" "a1" "Agent"
                                '((description . "count files") (prompt . "Run ls.")
                                  (subagent_type . "general-purpose"))
                                '((status . "async_launched") (agentId . "sub1")))
    (vigil-tests--write-raw dir '((hook_event_name . "PostToolUse") (tool_name . "Bash")
                                          (tool_use_id . "b1") (agent_id . "sub1")
                                          (agent_type . "general-purpose")
                                          (tool_input (command . "ls"))
                                          (tool_response (stdout . "notes.txt"))))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let* ((launch (gethash "a1" vigil--calls))
           (subagent (gethash "sub1" vigil--subagents)))
      (should (eq (vigil-call-subagent launch) subagent))
      (should (equal (vigil--status launch) "running"))
      (should (equal (mapcar #'vigil-call-id (vigil-subagent-calls subagent)) '("b1")))
      ;; While it runs: how many calls it has made, and the last.
      (should (equal (vigil--subagent-progress subagent) "1 call  ·  Bash ls"))
      (should (equal (vigil--state launch) "  ·  running  ·  1 call  ·  Bash ls"))
      (with-temp-buffer
        (vigil--render launch)
        (should (string-match-p "^running  ·  1 call  ·  Bash ls  ·  in the background$"
                                (buffer-string))))
      ;; Its agent did not wait for it: a reply does not make it interrupted.
      (vigil-tests--write-raw dir '((hook_event_name . "Stop")
                                            (last_assistant_message . "Launched.")))
      (vigil--scan (current-buffer))
      (should (equal (vigil--status launch) "running"))
      (vigil-tests--write-raw dir '((hook_event_name . "SubagentStop")
                                            (agent_id . "sub1") (agent_type . "general-purpose")
                                            (last_assistant_message . "1 file.")))
      (vigil--scan (current-buffer))
      (should (equal (vigil--status launch) "done"))
      (let ((context (vigil-context)))
        (unwind-protect
            (with-current-buffer context
              (should (equal (vigil-tests--headings)
                             '("* Agent  [general-purpose] count files  ·  done 0.0s"
                               "** Bash  ls  ·  done 0.0s" "* Reply")))
              ;; Folded to its heading: the subagent's calls are under it.
              (should (equal (vigil-tests--headings t)
                             '("* Agent  [general-purpose] count files  ·  done 0.0s"
                               "* Reply"))))
          (kill-buffer context)))
      (with-temp-buffer
        (vigil--render launch)
        (should (string-match-p "\\`count files  \\[general-purpose\\]" (buffer-string)))
        (should (string-match-p "^Task\nRun ls\\.$" (buffer-string)))
        (should (string-match-p "^Result\n1 file\\.$" (buffer-string)))
        (should (string-match-p "^  Bash +done +ls$" (buffer-string)))))))

(ert-deftest vigil-joins-a-foreground-subagent-to-its-launch-when-told ()
  "A foreground subagent's launch has no result while it runs: until the result
names it, the subagent is a group of its own, and nothing is guessed."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "a1" "Agent"
                                '((description . "look") (subagent_type . "Explore")))
    (vigil-tests--write-raw dir '((hook_event_name . "SubagentStart")
                                          (agent_id . "sub1") (agent_type . "Explore")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((launch (gethash "a1" vigil--calls))
          (subagent (gethash "sub1" vigil--subagents)))
      (should-not (vigil-subagent-call subagent))
      (vigil-tests--write dir "PostToolUse" "a1" "Agent"
                                  '((description . "look") (subagent_type . "Explore"))
                                  '((status . "completed") (agentId . "sub1")
                                    (content . [((type . "text") (text . "found it"))])))
      (vigil--scan (current-buffer))
      (should (eq (vigil-subagent-call subagent) launch))
      (should (equal (vigil--status launch) "done")))))

(ert-deftest vigil-takes-a-subagent-left-behind-for-interrupted ()
  "A subagent that was waited for, and never said it was done while its agent
went on to reply, is interrupted, not running for good; heard of again, it
is running again, and done once it says so."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "a1" "Agent" '((subagent_type . "Explore")))
    (vigil-tests--write-raw dir '((hook_event_name . "SubagentStart")
                                          (agent_id . "sub1") (agent_type . "Explore")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((subagent (gethash "sub1" vigil--subagents)))
      (should (equal (vigil--subagent-status subagent) "running"))
      (should-not (vigil--subagent-progress subagent))
      (vigil-tests--write-raw dir '((hook_event_name . "Stop")
                                            (last_assistant_message . "Stopped.")))
      (vigil--scan (current-buffer))
      (should (equal (vigil--subagent-status subagent) "interrupted"))
      (vigil-tests--write-raw dir '((hook_event_name . "PostToolUse") (tool_name . "Bash")
                                            (tool_use_id . "b1") (agent_id . "sub1")
                                            (tool_input (command . "ls"))
                                            (tool_response (stdout . "x"))))
      (vigil--scan (current-buffer))
      (should (equal (vigil--subagent-status subagent) "running"))
      (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                            (prompt . "never mind")))
      (vigil--scan (current-buffer))
      (should (equal (vigil--subagent-status subagent) "interrupted"))
      (should-not (vigil--subagent-progress subagent))
      (vigil-tests--write-raw dir '((hook_event_name . "SubagentStop")
                                            (agent_id . "sub1")
                                            (last_assistant_message . "Done after all.")))
      (vigil--scan (current-buffer))
      (should (equal (vigil--subagent-status subagent) "done")))))

(ert-deftest vigil-says-a-subagent-failed ()
  "A subagent whose launching call came back an error has failed."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "a1" "Agent" '((subagent_type . "Explore")))
    (vigil-tests--write-raw dir '((hook_event_name . "SubagentStart")
                                          (agent_id . "sub1") (agent_type . "Explore")))
    (vigil-tests--write dir "PostToolUse" "a1" "Agent" '((subagent_type . "Explore"))
                                '((is_error . t) (agentId . "sub1")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (should (equal (vigil--status (gethash "a1" vigil--calls)) "failed"))))

(ert-deftest vigil-shows-an-unnamed-subagent-on-its-own ()
  "A subagent whose launch has not named it yet is an entry of its own."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PreToolUse" "a1" "Agent" '((subagent_type . "Explore")))
    (vigil-tests--write-raw dir '((hook_event_name . "SubagentStart")
                                          (agent_id . "sub1") (agent_type . "Explore")))
    (vigil-mode 1)
    (let ((context (vigil-context)))
      (unwind-protect
          (with-current-buffer context
            (should (equal (vigil-tests--headings)
                           '("* Agent    ·  running " "* Agent  [Explore] sub1  ·  running "))))
        (kill-buffer context)))))

(ert-deftest vigil-stepping-through-calls ()
  "`]' and `[' step through the calls in the frame inspecting them."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                                '((stdout . "one")))
    (vigil-tests--write dir "PostToolUse" "t2" "Bash" '((command . "ls -la"))
                                '((stdout . "two")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((shown (vigil-inspect (car vigil--order) (current-buffer))))
      (with-current-buffer shown
        (should (string-match-p "^one$" (buffer-string)))
        (vigil-next-call)
        (should (string-match-p "^two$" (buffer-string)))
        (should-error (vigil-next-call) :type 'user-error)
        (vigil-previous-call)
        (should (string-match-p "^one$" (buffer-string)))))))

;; Each report's time is in its file's name: 1700000000, the same for all.
(ert-deftest vigil-says-when-and-how-deep-a-call-is ()
  "The header of a call inspected says when it ran, in which turn, which call of
the turn and of all; its keys are in the mode line."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                  (prompt . "list the files, then fix notes.txt")))
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                        '((stdout . "one")))
    (vigil-tests--write dir "PostToolUse" "t2" "Bash" '((command . "ls -la"))
                        '((stdout . "two")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (with-current-buffer (vigil-inspect (cadr vigil--order) (current-buffer))
      (should (string-match-p
               (concat "\\`Bash  ·  done  ·  [0-9.]+s  ·  "
                       (regexp-quote (vigil--time 1700000000))
                       "  ·  turn 1/1  ·  call 2/2 (2/2)  ·  /tmp/proj\\'")
               header-line-format))
      ;; The keys below, out of the way once known.
      (should (string-prefix-p " q close  ] next  [ previous  o conversation  e explain"
                               mode-line-format)))
    (should (equal (vigil--whereabouts vigil--order (current-buffer))
                   (list (vigil--time 1700000000) "turn 1/1" "calls 1–2/2 (1–2/2)")))
    ;; A later turn: the call's place in it, and among all.
    (let* ((later (vigil-call--make :id "t3" :name "Bash" :start 1700000100))
           (vigil--order (append vigil--order (list later)))
           (vigil--prompts (append vigil--prompts
                                   (list (vigil--prompt-make :text "more"
                                                             :time 1700000050)))))
      (should (equal (cdr (vigil--whereabouts (list later) (current-buffer)))
                     '("turn 2/2" "call 1/1 (3/3)"))))
    (should (equal (vigil--time (float-time)) (format-time-string "%H:%M:%S")))))

(ert-deftest vigil-follows-a-call-in-the-conversation ()
  "Inspecting a call scrolls the conversation to its line; \\`q' puts it back."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                        '((stdout . "one")))
    (vigil-tests--write dir "PostToolUse" "t2" "Bash" '((command . "ls -la"))
                        '((stdout . "two")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let* ((agent (current-buffer))
           (window (progn (delete-other-windows)
                          (set-window-buffer (selected-window) agent)
                          (selected-window)))
           (first (vigil-call-annotation (car vigil--order)))
           (second (vigil-call-annotation (cadr vigil--order))))
      (should (and first second))
      (set-window-point window (point-max))
      (with-current-buffer (vigil-inspect (car vigil--order) agent)
        (skip-unless (window-live-p window))
        (should (eq (window-buffer window) agent))
        (should (= (window-point window) (cooked-annotation-beg first)))
        (let ((this-command 'vigil-next-call))
          (vigil-next-call))
        (should (= (window-point window) (cooked-annotation-beg second)))
        ;; Back to where it was: following the conversation's end.
        (vigil-popup-quit)
        (should (= (window-point window) (with-current-buffer agent (point-max))))
        (should-not vigil--follow-saved)))))

;; A turn's calls, made by hand: the times are what is tested.
(ert-deftest vigil-context-from-the-transcript ()
  "The context a call was made in: what the request that made it read, from
the transcript; a subagent's from its own; and kept up as the file grows."
  (let* ((dir (make-temp-file "vigil-transcript" t))
         (main (expand-file-name "s.jsonl" dir))
         (line (lambda (type id tokens)
                 (concat (json-serialize
                          `((type . ,type)
                            (message . ((role . "assistant")
                                        (content . [((type . "tool_use") (id . ,id))])
                                        ,@(and tokens
                                               `((usage . ((input_tokens . 3)
                                                           (cache_creation_input_tokens . 1000)
                                                           (cache_read_input_tokens . ,tokens)))))))))
                         "\n"))))
    (unwind-protect
        (with-temp-buffer
          (setq-local vigil--transcript main)
          (setq-local vigil--subagents (make-hash-table :test #'equal))
          (make-directory (expand-file-name "s/subagents" dir) t)
          (write-region (concat (funcall line "assistant" "t1" 40000)
                                ;; The id again, in an entry with no usage.
                                (funcall line "api-request-blob" "t1" nil))
                        nil main nil 'silent)
          (write-region (funcall line "assistant" "t2" 8000) nil
                        (expand-file-name "s/subagents/agent-a1.jsonl" dir) nil 'silent)
          (let ((agent (current-buffer))
                (call (vigil-call--make :id "t1" :name "Bash"))
                (inner (vigil-call--make :id "t2" :name "Read" :agent "a1"))
                (later (vigil-call--make :id "t3" :name "Bash")))
            (should (equal (vigil--context call agent) 41003))
            (should (equal (vigil--context inner agent) 9003))
            (should-not (vigil--context later agent))
            ;; A line still being written, a character split across the
            ;; two writes: read once whole.
            (let ((whole (encode-coding-string
                          (concat "{\"note\":\"é\","
                                  (substring (funcall line "assistant" "t3" 150000) 1))
                          'utf-8)))
              (write-region (substring whole 0 10) nil main t 'silent)
              (should-not (vigil--context later agent))
              (write-region (substring whole 10) nil main t 'silent))
            (should (equal (vigil--context later agent) 151003))
            (let ((vigil-transcript-limit 10))
              (should-not (vigil--context later agent)))
            ;; Done with: what was read of it goes.
            (vigil--forget-transcript)
            (should-not (cl-some (lambda (buffer)
                                   (string-prefix-p " *vigil transcript " (buffer-name buffer)))
                                 (buffer-list)))
            (should (equal (vigil--tokens 151003) "151k"))
            (should (string-match-p "  ·  41k context" (vigil--header call (list call) agent)))))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p " *vigil transcript " (buffer-name buffer))
          (kill-buffer buffer)))
      (delete-directory dir t))))

(ert-deftest vigil-turn-lists-a-turns-calls-in-order ()
  "A turn is the calls between one prompt given and the next, in order, each
with when it began, how long it took and what it did; a prompt the agent
gives itself does not begin one."
  (with-temp-buffer
    (let* ((agent (current-buffer))
           (call (lambda (id name start end input &optional response agent-id)
                   (vigil-call--make :id id :name name :start start :end end
                                     :input input :agent agent-id
                                     :response (or response '((ok . t))))))
           (before (funcall call "c0" "Bash" 990 991 '((command . "ls"))))
           (write (funcall call "c1" "Write" 1003 1003.5
                           '((file_path . "/p/new.py") (content . "x"))
                           '((type . "create"))))
           (edit (funcall call "c2" "Edit" 1010 1010.2
                          '((file_path . "/p/old.py") (old_string . "a") (new_string . "b"))))
           (bash (funcall call "c3" "Bash" 1012 1014.5
                          '((command . "python3 - <<'EOF'\nprint(1)\nEOF")
                            (description . "Count keys"))))
           (background (funcall call "c4" "Bash" 1070 1070
                                '((command . "sleep 600") (run_in_background . t))
                                '((stdout . "") (backgroundTaskId . "b1"))))
           (inner (funcall call "c5" "Read" 1080 1080.1 '((file_path . "/p/a.txt"))
                           '((ok . t)) "sub-1")))
      (setq-local vigil--order (list before write edit bash background inner))
      (setq-local vigil--prompts
                  (list (vigil--prompt-make :text "first" :time 900)
                        (vigil--prompt-make :text "second prompt\nmore" :time 1000)
                        ;; A background task reporting back: still turn 2.
                        (vigil--prompt-make :text "<task-notification>done</task-notification>"
                                            :time 1060)))
      (setq-local vigil--notes (list (list :time 1065 :kind 'reply :text "ok")))
      (setq-local vigil--subagents nil)
      (should (equal (mapcar (lambda (c) (vigil-turn--of c agent)) vigil--order)
                     '(1 2 2 2 2 2)))
      (with-temp-buffer
        (vigil-turn-mode)
        (setq vigil-turn--agent agent vigil-turn--turn 2)
        (should (equal (mapcar (lambda (row)
                                 (mapconcat #'substring-no-properties (cadr row) "|"))
                               (vigil-turn--entries))
                       '("+0:03|0.5s|||Write|created /p/new.py"
                         "+0:10|0.2s|||Edit|edited /p/old.py"
                         "+0:12|2.5s|||Bash|Count keys  python3 - <<'EOF'"
                         "+1:10|0.0s||background|Bash|sleep 600"
                         "+1:20|0.1s|||  ↳ Read|read /p/a.txt")))
        (should (equal (vigil-turn--header)
                       (concat "Turn 2/2  ·  " (vigil--time 1000)
                               "  ·  5 calls  ·  1m05s  ·  second prompt"))))
      ;; And the header of a call inspected counts turns the same way.
      (should (equal (cadr (vigil--whereabouts (list background) agent)) "turn 2/2")))))

(ert-deftest vigil-turn-opens-on-the-call-nearest-point ()
  "From the conversation, the turn of the call marked nearest above point,
with that call selected and shown; RET inspects it, `o' goes to its line."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                        '((stdout . "total 16")))
    (vigil-tests--write dir "PostToolUse" "t2" "Edit"
                        '((file_path . "/tmp/proj/notes.txt")
                          (old_string . "beta") (new_string . "BETA"))
                        '((filePath . "/tmp/proj/notes.txt")))
    (vigil-tests--write dir "PostToolUse" "t3" "Bash" '((command . "ls -la"))
                        '((stdout . "total 16")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let* ((agent (current-buffer))
           (edit (nth 1 vigil--order))
           (at (marker-position (cooked-annotation-beg (vigil-call-annotation edit)))))
      (save-window-excursion
        (delete-other-windows)
        (set-window-buffer (selected-window) agent)
        ;; Point a line below the edit's mark, above the next call's.
        (goto-char at)
        (forward-line 1)
        (should (eq (vigil-turn--call-near (point) agent) edit))
        (let ((shown (vigil-turn)))
          (with-current-buffer shown
            (should (derived-mode-p 'vigil-turn-mode))
            (should (eq (tabulated-list-get-id) edit))
            (should (equal (mapcar #'car (vigil-turn--entries))
                           (buffer-local-value 'vigil--order agent)))
            (should (string-prefix-p " RET inspect  o conversation" mode-line-format))
            (should-error (vigil-turn-next) :type 'user-error)
            ;; RET inspects it, in the same frame.
            (should (eq (key-binding (kbd "RET")) #'vigil-turn-inspect))
            (with-current-buffer (vigil-turn-inspect)
              (should (eq vigil--popup-call edit))
              (should (derived-mode-p 'diff-mode)))
            (vigil-turn-goto))
          ;; `o' took us to the agent, at the edit's line.
          (should (eq (window-buffer (selected-window)) agent))
          (should (= (window-point (selected-window)) at)))))))

(ert-deftest vigil-stepping-from-a-file-opened-out-of-a-call ()
  "A file opened from a call being inspected keeps `]' and `[': they step to
the calls after and before the one it was opened from."
  (let ((file (make-temp-file "vigil-step" nil ".txt" "hello\n")))
    (unwind-protect
        (vigil-tests--with-agent vigil-tests--conversation
          (vigil-tests--write dir "PostToolUse" "s1" "Bash" '((command . "ls -la"))
                                      `((stdout . ,file)))
          (vigil-tests--write dir "PostToolUse" "s2" "Bash" '((command . "ls -la"))
                                      '((stdout . "two")))
          (vigil-mode 1)
          (vigil--scan (current-buffer))
          (save-window-excursion
            (let ((call (vigil-inspect (car vigil--order) (current-buffer))))
              (with-current-buffer call
                (goto-char (point-min))
                (search-forward (file-name-nondirectory file))
                (push-button (1- (point))))
              (with-current-buffer (window-buffer)
                (should (equal (buffer-string) "hello\n"))
                (should (eq (key-binding "]") #'vigil-next-call))
                (should (eq (key-binding "v") #'cooked-popup-visit))
                (vigil-next-call))
              (should (eq (window-buffer) call))
              (with-current-buffer call
                (should (string-match-p "^two$" (buffer-string)))
                (vigil-previous-call)
                (should (string-match-p (regexp-quote file) (buffer-string))))
              (cooked-popup-quit))))
      (delete-file file))))

(ert-deftest vigil-inspects-a-group-call-by-call ()
  "A group marked on one line is inspected as each of its calls: a read shows
its file and what it held."
  (with-temp-buffer
    (vigil--render
     (list (vigil-call--make :name "Read" :input '((file_path . "/tmp/a.el"))
                               :response '((type . "text")
                                           (file (filePath . "/tmp/a.el")
                                                 (content . "(setq x 1)\n"))))
           (vigil-call--make :name "Bash" :input '((command . "ls"))
                               :response '((stdout . "a.el")))))
    (should (string-match-p "\\`Read  /tmp/a.el" (buffer-string)))
    (should (string-match-p "^(setq x 1)$" (buffer-string)))
    (should (string-match-p "^Bash  ls" (buffer-string)))
    (should (string-match-p "^a.el$" (buffer-string)))
    (should buffer-read-only)))

(ert-deftest vigil-context-has-everything-the-hooks-report ()
  "Prompts, session starts, calls with their full results and the reply ending
the turn, oldest first; and a note of what hooks do not report."
  (vigil-tests--with-agent ""
    (vigil-tests--write-raw dir '((hook_event_name . "SessionStart") (source . "startup")
                                          (transcript_path . "/tmp/t.jsonl")))
    (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                          (prompt . "* read a.el")))
    (vigil-tests--write dir "PostToolUse" "r1" "Read" '((file_path . "/tmp/a.el"))
                                '((type . "text")
                                  (file (filePath . "/tmp/a.el") (content . "* (setq x 1)\n"))))
    (vigil-tests--write-raw dir '((hook_event_name . "Stop")
                                          (last_assistant_message . "It sets x.")))
    (vigil-mode 1)
    (let ((context (vigil-context)))
      (unwind-protect
          (with-current-buffer context
            (should buffer-read-only)
            (should (string-match-p "not here: the system prompt" (buffer-string)))
            (should (string-match-p "Transcript: /tmp/t.jsonl" (buffer-string)))
            ;; Bodies are indented, so a line of them that begins with `*' is
            ;; not taken for a heading.
            (should (equal (vigil-tests--headings)
                           '("* Session start (startup)" "* Prompt"
                             "* Read  /tmp/a.el  ·  done 0.0s" "* Reply")))
            (should (string-match-p "^  \\* (setq x 1)$" (buffer-string)))
            (should (string-match-p "^  It sets x\\.$" (buffer-string))))
        (kill-buffer context)))))

(ert-deftest vigil-context-keeps-what-was-open-as-it-grows ()
  "A new report draws the context again: an entry that was open stays open."
  (vigil-tests--with-agent ""
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls"))
                                '((stdout . "one")))
    (vigil-mode 1)
    (let ((context (vigil-context)))
      (unwind-protect
          (with-current-buffer context
            (goto-char (point-min))
            (re-search-forward "^\\* ")
            (outline-show-entry)
            (should (member "t1" (vigil--context-open-keys)))
            (with-current-buffer vigil--context-agent
              (vigil-tests--write dir "PostToolUse" "t2" "Bash" '((command . "pwd"))
                                          '((stdout . "/tmp")))
              (vigil--scan (current-buffer)))
            (should (= (length (vigil-tests--headings)) 2))
            (should (equal (vigil--context-open-keys) '("t1"))))
        (kill-buffer context)))))

(ert-deftest vigil-picks-up-reports-as-they-are-written ()
  "A report written after the buffer started watching is read without being
asked for."
  (vigil-tests--with-agent vigil-tests--conversation
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (should-not vigil--order)
    (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                                '((stdout . "total 16")))
    (let ((deadline (+ (float-time) 5)))
      (while (and (null vigil--order) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should (= (length vigil--order) 1))
    (should (equal (vigil-tests--line (car vigil--order))
                   "* Bash(ls -la)"))))




(ert-deftest vigil-does-not-mark-a-call-in-its-own-prompt ()
  "A call the agent shows only as a summary is left unmarked, not marked on the
prompt that happened to name its file."
  (vigil-tests--with-agent
      (concat "> run ls -la, then fix notes.txt\n"
              "  and reply done.\n"
              "  Listed 1 directory\n"
              "* Update(notes.txt)\n"
              "> \n")
    (let ((vigil-anchor-tries 1))
      (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                            (prompt . "run ls -la, then fix notes.txt and reply done.")))
      (vigil-tests--write dir "PostToolUse" "t1" "Bash" '((command . "ls -la"))
                                  '((stdout . "x")))
      (vigil-tests--write dir "PostToolUse" "t2" "Edit"
                                  '((file_path . "/tmp/proj/notes.txt")
                                    (old_string . "a") (new_string . "b"))
                                  '((filePath . "/tmp/proj/notes.txt")))
      (vigil-mode 1)
      (vigil--scan (current-buffer))
      ;; The run of calls not found is marked on the line above the next one
      ;; that was: here, the agent's own summary of it.
      (should (equal (mapcar #'vigil-tests--line vigil--order)
                     '("  Listed 1 directory" "* Update(notes.txt)")))
      (should (equal (cooked-annotation-data (vigil-call-annotation
                                              (car vigil--order)))
                     (list (car vigil--order)))))))




(ert-deftest vigil-marks-the-last-drawing-and-stays-in-its-turn ()
  "The agent drew the start of its turn twice: calls are marked on the last
drawing, never on prose of the reply that ends their turn, and a summarised
run at the end of a turn is marked on its summary, above the reply."
  (vigil-tests--with-agent
      (concat "> fix notes.txt then ls -la\n"
              "  Read 1 file\n"
              "> fix notes.txt then ls -la\n"
              "  Read 1 file\n"
              "* Update(notes.txt)\n"
              "  Listed 1 directory\n"
              "* Done.\n"
              "  - ls -la shows notes.txt only here.\n"
              "> \n")
    (let ((vigil-anchor-tries 1))
      (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                            (prompt . "fix notes.txt then ls -la")))
      (vigil-tests--write dir "PostToolUse" "r1" "Read"
                                  '((file_path . "/tmp/proj/notes.txt")) '((type . "text")))
      (vigil-tests--write dir "PostToolUse" "e1" "Edit"
                                  '((file_path . "/tmp/proj/notes.txt")
                                    (old_string . "a") (new_string . "b"))
                                  '((filePath . "/tmp/proj/notes.txt")))
      (vigil-tests--write dir "PostToolUse" "b1" "Bash" '((command . "ls -la"))
                                  '((stdout . "notes.txt")))
      (vigil-tests--write-raw dir '((hook_event_name . "Stop")
                                            (last_assistant_message
                                             . "Done.\n\n- `ls -la` shows notes.txt only here.")))
      (vigil-mode 1)
      (vigil--scan (current-buffer))
      (should (equal (mapcar (lambda (call)
                               (list (vigil-tests--line call)
                                     (line-number-at-pos
                                      (cooked-annotation-beg (vigil-call-annotation call)))))
                             vigil--order)
                     '(("  Read 1 file" 4) ("* Update(notes.txt)" 5)
                       ("  Listed 1 directory" 6)))))))




(ert-deftest vigil-prompts-are-stops-for-cooked-navigation ()
  "C-c C-p and C-c C-n move between the agent's prompts, by their echoes."
  (vigil-tests--with-agent
      (concat "> first thing to do\n"
              "* Bash(ls)\n"
              "> second thing, which is long enough\n"
              "  to be wrapped by the agent\n"
              "* Bash(pwd)\n"
              "> \n")
    (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                          (prompt . "first thing to do")))
    (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                          (prompt . "second thing, which is long enough to be wrapped by the agent")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (goto-char (point-max))
    (cooked-previous-command)
    (should (looking-at-p "> second thing"))
    (cooked-previous-command)
    (should (looking-at-p "> first thing"))
    (cooked-next-command)
    (should (looking-at-p "> second thing"))))

(ert-deftest vigil-prompts-offers-history-newest-first-and-pastes ()
  "The history, for this agent or all of them, newest first and each prompt
once; what the agent gives itself is left out; the choice is pasted, not
submitted."
  (vigil-tests--with-agent ""
    (let* ((vigil-prompt-history (expand-file-name "prompts.jsonl" dir))
           (line (lambda (host time text)
                   (concat (json-serialize
                            `((host . ,host) (time . ,time)
                              (event (hook_event_name . "UserPromptSubmit")
                                     (prompt . ,text) (cwd . "/tmp/proj"))))
                           "\n")))
           (offered nil)
           (pasted nil))
      (with-temp-file vigil-prompt-history
        (insert (funcall line "proj.1" 1700000001 "fix the bug")
                (funcall line "other.1" 1700000002 "elsewhere")
                (funcall line "proj.1" 1700000003 "<task-notification>x</task-notification>")
                "not json\n"
                (funcall line "proj.1" 1700000004 "add a test\nand run it")
                (funcall line "proj.1" 1700000005 "fix the bug")))
      (vigil-mode 1)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq offered (funcall table "" nil t))
                   (car offered)))
                ((symbol-function 'cooked-paste-string)
                 (lambda (text) (setq pasted text))))
        (vigil-prompts)
        (should (equal offered '("fix the bug" "add a test ↵ and run it")))
        (should (equal pasted "fix the bug"))
        (vigil-prompts '(4))
        (should (equal offered '("fix the bug" "add a test ↵ and run it" "elsewhere")))))))

;;;; Files and focus

(ert-deftest vigil-a-file-name-opens-in-the-preview ()
  "An agent buffer opens a file named in its output in the pop-up, read-only
and at its line; `v' there visits it in a window.  A shell's buffer is left
to cooked's default."
  (let* ((file (make-temp-file "vigil-preview" nil ".el" "(one)\n(two)\n(three)\n")))
    (unwind-protect
        (vigil-tests--with-agent "> look\n"
          (vigil-mode 1)
          (should (eq cooked-file-open-function #'vigil--open-file))
          (should (funcall cooked-file-open-function file 2 1))
          (with-current-buffer (window-buffer)
            (should buffer-read-only)
            (should (equal (buffer-string) "(one)\n(two)\n(three)\n"))
            (should (= (line-number-at-pos) 2))
            (should (eq (key-binding "v") #'cooked-popup-visit))
            (cooked-popup-visit))
          (with-current-buffer (get-file-buffer file)
            (should (= (line-number-at-pos) 2))
            (kill-buffer))
          (with-temp-buffer
            (cooked-mode)
            (should-not cooked-file-open-function)))
      (delete-file file))))

(ert-deftest vigil-file-names-in-a-call-are-links ()
  "A file a call's output names, which exists, is a link to its preview."
  (let* ((file (make-temp-file "vigil-link" nil ".txt" "hello\n")))
    (unwind-protect
        (vigil-tests--with-agent "> look\n"
          (vigil-tests--write dir "PostToolUse" "g1" "Bash" '((command . "ls"))
                                      `((stdout . ,(format "%s:1\n/no/such/file\n" file))))
          (vigil-mode 1)
          (vigil--scan (current-buffer))
          (with-current-buffer (vigil-inspect (car vigil--order))
            (goto-char (point-min))
            (should (search-forward file nil t))
            (should (button-at (match-beginning 0)))
            (should-not (and (search-forward "/no/such/file" nil t)
                             (button-at (match-beginning 0))))))
      (delete-file file))))

(defun vigil-tests--visible ()
  "The buffer's text as displayed: invisible parts out, placeholders in."
  (let ((out "") (pos (point-min)))
    (while (< pos (point-max))
      (let ((next (next-single-char-property-change pos 'invisible)))
        (dolist (o (overlays-at pos))
          (when (and (overlay-get o 'before-string) (= (overlay-start o) pos))
            (setq out (concat out (overlay-get o 'before-string)))))
        (unless (invisible-p pos)
          (setq out (concat out (buffer-substring-no-properties pos next))))
        (setq pos next)))
    out))

(defmacro vigil-tests--with-turn (&rest body)
  "Run BODY in an agent buffer with one finished turn: a prompt, its work, a reply."
  (declare (indent 0))
  `(vigil-tests--with-agent
       (concat "> fix notes.txt please\n"
               "* Read(notes.txt)\n"
               "  Read 3 lines\n"
               "* Update(notes.txt)\n"
               "  - a\n"
               "  + b\n"
               "* Fixed notes.txt.\n"
               "> \n")
     (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                           (prompt . "fix notes.txt please")))
     (vigil-tests--write dir "PostToolUse" "r1" "Read"
                                 '((file_path . "/tmp/proj/notes.txt")) '((type . "text")))
     (vigil-tests--write dir "PostToolUse" "e1" "Edit"
                                 '((file_path . "/tmp/proj/notes.txt")
                                   (old_string . "a") (new_string . "b"))
                                 '((filePath . "/tmp/proj/notes.txt")))
     (vigil-tests--write-raw dir '((hook_event_name . "Stop")
                                           (last_assistant_message . "Fixed notes.txt.")))
     (vigil-mode 1)
     (vigil--scan (current-buffer))
     ,@body))

(ert-deftest vigil-focus-shows-only-prompts-and-replies ()
  "Focus hides each turn's work behind one line saying what it was, changes
no text, and shows everything again when turned off."
  (vigil-tests--with-turn
    (let ((text (buffer-string)))
      (vigil-focus-mode 1)
      (should (string-match-p
               "\\`> fix notes.txt please\n  ⋯ 2 tool calls hidden.*\n\\* Fixed notes.txt.\n> \n\\'"
               (vigil-tests--visible)))
      (should (equal (buffer-string) text))
      (vigil-focus-mode -1)
      (should (equal (vigil-tests--visible) text))
      (should-not vigil--focus-overlays))))

(ert-deftest vigil-focus-never-hides-what-is-still-drawn ()
  "A finished turn is hidden wherever it is; a turn still under way only as far
as it has scrolled off the screen."
  (vigil-tests--with-agent
      (concat "> fix notes.txt please\n"
              "* Read(notes.txt)\n"
              "  Read 3 lines\n"
              "* Update(notes.txt)\n"
              "  - a\n"
              "  + b\n")
    (vigil-tests--write-raw dir '((hook_event_name . "UserPromptSubmit")
                                          (prompt . "fix notes.txt please")))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((screen (save-excursion (goto-char (point-min))
                                  (search-forward "* Update") (line-beginning-position))))
      (cl-letf (((symbol-function 'cooked--screen-start-position) (lambda () screen)))
        (vigil-focus-mode 1)
        (should (string-search "* Update(notes.txt)\n  - a\n  + b\n"
                               (vigil-tests--visible)))
        (should-not (string-search "Read 3 lines" (vigil-tests--visible)))))))

(ert-deftest vigil-focus-opens-a-turn-isearch-finds-in ()
  "A match inside a hidden turn opens that turn, and it stays open."
  (vigil-tests--with-turn
    (vigil-focus-mode 1)
    (let ((overlay (car vigil--focus-overlays)))
      (should (eq (overlay-get overlay 'isearch-open-invisible) #'vigil--focus-open))
      (vigil--focus-open overlay)
      (should (string-search "Read 3 lines" (vigil-tests--visible)))
      (vigil--focus-place t)
      (should (string-search "Read 3 lines" (vigil-tests--visible))))))

(ert-deftest vigil-focus-is-for-agent-buffers-only ()
  "A shell has no turns to hide."
  (with-temp-buffer
    (cooked-mode)
    (should-error (vigil-focus-mode 1) :type 'user-error)
    (should-not vigil-focus-mode)))

(ert-deftest vigil-html-opens-in-a-browser ()
  "An HTML file named in an agent's output goes to the browser, not the preview."
  (let* ((file (make-temp-file "vigil-test" nil ".html" "<p>hi</p>"))
         (browsed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'browse-url-of-file)
                   (lambda (f) (setq browsed f))))
          (vigil-preview-file file)
          (should (equal browsed file)))
      (delete-file file))))

;;;; Commands as they print

(ert-deftest vigil-a-running-command-is-shown-as-it-prints ()
  "A command with no result yet, whose run cooked kept, is inspected in the
buffer following that run -- the one of that command which began nearest the
call -- with the call's keys; `r' shows the same for one that has finished."
  (require 'cooked-run)
  (vigil-tests--with-agent "> go\n"
    (let* ((cooked-run-directory (make-temp-file "vigil-runs" t))
           (dir (expand-file-name "proj.1" cooked-run-directory))
           (run (lambda (id label started output)
                  (make-directory dir t)
                  (write-region output nil (expand-file-name (concat id ".out") dir) nil 'silent)
                  (write-region (json-serialize `((id . ,id) (session . "proj.1")
                                                  (pid . ,(emacs-pid)) (cwd . "/tmp")
                                                  (argv . ["sh" "-c" "x"]) (label . ,label)
                                                  (started . ,started)))
                                nil (expand-file-name (concat id ".json") dir) nil 'silent))))
      (unwind-protect
          (save-window-excursion
            (funcall run "1.000000-1" "make test" 1000.0 "an earlier one\n")
            (funcall run "2.000000-2" "make test" 2000.2 "building\n")
            (funcall run "3.000000-3" "ls" 2000.3 "other\n")
            (let* ((agent (current-buffer))
                   (running (vigil-call--make :id "r" :name "Bash" :start 2000.0
                                              :input '((command . "make test"))))
                   (done (vigil-call--make :id "d" :name "Bash" :start 1000.1 :end 1001.0
                                           :input '((command . "make test"))
                                           :response '((stdout . "an earlier one"))))
                   (untracked (vigil-call--make :id "u" :name "Bash" :start 2000.0
                                                :input '((command . "never kept"))))
                   (shown (vigil-inspect running agent)))
              (with-current-buffer shown
                (should (derived-mode-p 'cooked-run-mode))
                (should (string-suffix-p "building\n" (buffer-string)))
                (should (eq (key-binding "]") #'vigil-next-call))
                (should (eq (key-binding "q") #'vigil-popup-quit))
                (should (eq vigil--popup-call running)))
              ;; Finished: its report, and `r' for the run.
              (with-current-buffer (vigil-inspect done agent)
                (should (derived-mode-p 'vigil-view-mode))
                (should (eq (key-binding "r") #'vigil-show-run))
                (with-current-buffer (vigil-show-run)
                  (should (string-suffix-p "an earlier one\n" (buffer-string)))
                  ;; And `r' again: back to the report.
                  (should (string-match-p "r report" mode-line-format))
                  (with-current-buffer (vigil-show-run)
                    (should (derived-mode-p 'vigil-view-mode))
                    (should (eq vigil--popup-call done)))))
              ;; Nothing kept: as before.
              (with-current-buffer (vigil-inspect untracked agent)
                (should (string-match-p "(still running)" (buffer-string)))
                (should-error (vigil-show-run) :type 'user-error))
              ;; Left in the background: its report, which comes at once,
              ;; has nothing of what it prints; its run has.
              (let ((background (vigil-call--make
                                 :id "b" :name "Bash" :start 2000.0 :end 2000.1
                                 :input '((command . "make test") (run_in_background . t))
                                 :response '((stdout . "") (backgroundTaskId . "bx1")))))
                (with-current-buffer (vigil-inspect background agent)
                  (should (derived-mode-p 'cooked-run-mode))
                  (should (string-suffix-p "building\n" (buffer-string))))
                (setf (vigil-call-input background) '((command . "never kept")))
                (with-current-buffer (vigil-inspect background agent)
                  (should (string-match-p "(left running in the background, as task bx1"
                                          (buffer-string)))))
              (cooked-popup-quit)))
        (dolist (buffer (buffer-list))
          (when (buffer-local-value 'cooked-run--run buffer) (kill-buffer buffer)))
        (delete-directory cooked-run-directory t)))))

(ert-deftest vigil-a-commands-colours-are-shown ()
  "What a command printed keeps its colours as faces; a result reported as
one piece of text is shown too."
  (with-temp-buffer
    (vigil--render
     (vigil-call--make :name "Bash" :input '((command . "ls"))
                       :response '((stdout . "\e[31mred\e[0m plain"))))
    (should (string-match-p "^red plain$" (buffer-string)))
    (goto-char (point-min))
    (search-forward "red")
    (should (get-text-property (1- (point)) 'face))
    (should-not (get-text-property (+ (point) 2) 'face)))
  (with-temp-buffer
    (vigil--render (vigil-call--make :name "Bash" :input '((command . "ls"))
                                     :response "all of it\nas text"))
    (should (string-match-p "^all of it$" (buffer-string)))))

(ert-deftest vigil-says-when-commands-stop-being-followed ()
  "Where the agent runs its commands through vigil-shell, several reported in
a row with no run among them are said to be unfollowed, once; one followed
starts the count again; and an agent that does not use vigil-shell is never
told anything."
  (require 'cooked-run)
  (vigil-tests--with-agent "> go\n"
    (let* ((cooked-run-directory (make-temp-file "vigil-runs" t))
           (runs (expand-file-name "proj.1" cooked-run-directory))
           (warnings nil)
           (n 0)
           (report (lambda (command &optional followed)
                     ;; A run's name begins with when it started.
                     (let ((id (format "1700000000.%06d-1" (cl-incf n))))
                       (vigil-tests--write dir "PostToolUse" id "Bash"
                                           `((command . ,command)) '((stdout . "")))
                       (when followed
                         (make-directory runs t)
                         (write-region "" nil (expand-file-name (concat id ".out") runs)
                                       nil 'silent)
                         (write-region
                          (json-serialize `((id . ,id) (session . "proj.1") (pid . 1)
                                            (label . ,command) (argv . ["sh"])
                                            ;; The reports here are named for 2023.
                                            (started . ,(+ 1700000000.0 (* n 1e-6)))))
                          nil (expand-file-name (concat id ".json") runs) nil 'silent))
                       (vigil--scan (current-buffer))))))
      (unwind-protect
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (vigil-mode 1)
            ;; Not through vigil-shell: nothing to expect, nothing said.
            (dotimes (_ 4) (funcall report "ls"))
            (should-not warnings)
            ;; From now on it is, as `vigil hook' says with a file: written
            ;; after those four, which stay nothing to expect a run of.
            (let ((mark (expand-file-name ".shell" dir)))
              (write-region "" nil mark nil 'silent)
              (set-file-times mark (seconds-to-time
                                    (+ (vigil-call-start (car (last vigil--order)))
                                       5e-7))))
            (funcall report "make" t)
            (should-not warnings)
            (should (= vigil--unfollowed 0))
            (funcall report "make lint")
            (funcall report "make test")
            (should-not warnings)
            (funcall report "make check")
            (should (= (length warnings) 1))
            (should (string-match-p "not kept as they" (car warnings)))
            ;; Said once.
            (funcall report "make again")
            (should (= (length warnings) 1)))
        (delete-directory cooked-run-directory t)))))

;;;; Which buffers

(ert-deftest vigil-is-turned-on-where-an-agent-has-reported ()
  "A buffer attached to a hosted session gets the mode once its session has a
directory of reports, on attaching or when the first report arrives; a
session nothing reported from, and a buffer attached to none, are left alone."
  (let* ((vigil-directory (make-temp-file "vigil" t))
         (reported (generate-new-buffer "*reported*"))
         (silent (generate-new-buffer "*silent*"))
         (plain (generate-new-buffer "*plain*")))
    (unwind-protect
        (progn
          (with-current-buffer reported (cooked-mode) (setq cooked-host-name "has-agent"))
          (with-current-buffer silent (cooked-mode) (setq cooked-host-name "no-agent"))
          (with-current-buffer plain (cooked-mode))
          (vigil--enable-everywhere)
          (should-not (buffer-local-value 'vigil-mode reported))
          (make-directory (expand-file-name "has-agent" vigil-directory))
          ;; What the watch on `vigil-directory' does when a session appears.
          (vigil--enable-everywhere)
          (should (buffer-local-value 'vigil-mode reported))
          (should-not (buffer-local-value 'vigil-mode silent))
          (should-not (buffer-local-value 'vigil-mode plain))
          (should-not (file-exists-p (expand-file-name "no-agent" vigil-directory)))
          ;; And what `cooked-host-attach-hook' does for a buffer attached later.
          (make-directory (expand-file-name "no-agent" vigil-directory))
          (with-current-buffer silent
            (vigil--maybe-enable)
            (should vigil-mode)
            (should (eq cooked-file-open-function #'vigil--open-file))
            (vigil-mode -1)
            (should-not cooked-file-open-function)))
      (dolist (buffer (list reported silent plain))
        (with-current-buffer buffer (vigil--stop))
        (kill-buffer buffer))
      (delete-directory vigil-directory t))))

(ert-deftest vigil-a-name-that-is-a-path-names-no-directory ()
  "A session's name is only ever one directory under `vigil-directory'."
  (with-temp-buffer
    (setq-local cooked-host-name "../escape")
    (should-not (vigil--agent-directory))
    (should-error (vigil-mode 1) :type 'user-error)))

;;;; Edits: which call wrote each line

(defmacro vigil-tests--with-edits (&rest body)
  "Run BODY in an agent buffer that has edited `file' twice, in two turns.
Turn 1 rewrote its second line into two; you then changed its first; turn 2
rewrote its last, reported with no patch.  `e1' and `e2' are the calls."
  (declare (indent 0))
  `(vigil-tests--with-agent ""
     (let* ((home (make-temp-file "vigil-edits" t))
            (file (expand-file-name "notes.txt" home))
            (prompt (lambda (text)
                      (vigil-tests--write-raw dir `((hook_event_name . "UserPromptSubmit")
                                                    (prompt . ,text))))))
       (unwind-protect
           (progn
             (funcall prompt "fix the notes")
             (vigil-tests--write dir "PostToolUse" "e1" "Edit"
                                 `((file_path . ,file) (old_string . "beta")
                                   (new_string . "BETA\nbeta2"))
                                 `((filePath . ,file)
                                   (originalFile . "alpha\nbeta\ngamma\n")
                                   (structuredPatch
                                    . [((oldStart . 1) (oldLines . 3)
                                        (newStart . 1) (newLines . 4)
                                        (lines . [" alpha" "-beta" "+BETA" "+beta2" " gamma"]))])))
             (funcall prompt "and the end")
             (vigil-tests--write dir "PostToolUse" "e2" "Edit"
                                 `((file_path . ,file) (old_string . "gamma")
                                   (new_string . "GAMMA"))
                                 `((filePath . ,file)
                                   (originalFile . "ALPHA\nBETA\nbeta2\ngamma\n")))
             (with-temp-file file (insert "ALPHA\nBETA\nbeta2\nGAMMA\n"))
             (vigil-mode 1)
             (vigil--scan (current-buffer))
             (let ((agent (current-buffer))
                   (e1 (gethash "e1" vigil--calls))
                   (e2 (gethash "e2" vigil--calls)))
               (ignore agent e1 e2)
               ,@body))
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p home (buffer-file-name buffer)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (delete-directory home t)))))

(defun vigil-tests--owners (&optional buffer)
  "Which call wrote each line of BUFFER: the calls, or nil."
  (mapcar (lambda (owner) (car owner)) (vigil-edits-owners buffer)))

(ert-deftest vigil-edits-are-followed-line-by-line ()
  "Each edit is kept with the file as it left it; who wrote each line is
followed from edit to edit, and a line anyone else changed -- between edits,
or in the buffer, unsaved -- is no call's."
  (vigil-tests--with-edits
    (let ((edits (gethash (file-truename file) vigil--edits)))
      (should (equal (mapcar #'vigil-edit-after edits)
                     '("alpha\nBETA\nbeta2\ngamma\n" "ALPHA\nBETA\nbeta2\nGAMMA\n"))))
    (with-current-buffer (find-file-noselect file)
      (should vigil-edits-mode)
      ;; ALPHA was yours, between the two edits.
      (should (equal (vigil-tests--owners) (list nil e1 e1 e2)))
      (should (= (length vigil-edits--overlays) 3))
      (goto-char (point-min))
      (forward-line 3)
      (should (eq (car (vigil-edits--owner-at)) e2))
      ;; The turn going on now is bright; the one before, dim.
      (should (equal (mapcar (lambda (o) (get-text-property 0 'display (overlay-get o 'before-string)))
                             (sort (copy-sequence vigil-edits--overlays)
                                   (lambda (a b) (< (overlay-start a) (overlay-start b)))))
                     (list (list vigil-edits-fringe 'vigil-edit-bar 'vigil-edit)
                           (list vigil-edits-fringe 'vigil-edit-bar 'vigil-edit)
                           (list vigil-edits-fringe 'vigil-edit-bar 'vigil-edit-latest))))
      ;; Rewritten by you, unsaved: yours.
      (goto-char (point-min))
      (forward-line 1)
      (delete-region (point) (line-end-position))
      (insert "Beta")
      (should (equal (vigil-tests--owners) (list nil nil e1 e2)))
      ;; A line added above moves the marks with it.
      (goto-char (point-min))
      (insert "new first line\n")
      (should (equal (vigil-tests--owners) (list nil nil nil e1 e2))))))

(ert-deftest vigil-edits-keep-each-version-once ()
  "Where nothing came between two edits, the second found the file as the
first left it: one string, not two."
  (vigil-tests--with-agent ""
    (let ((file (file-truename "/tmp/proj/a.txt")))
      (vigil-tests--write dir "PostToolUse" "w" "Write"
                          `((file_path . ,file) (content . "one\n"))
                          `((type . "create") (filePath . ,file)))
      (vigil-tests--write dir "PostToolUse" "e" "Edit"
                          `((file_path . ,file) (old_string . "one") (new_string . "two"))
                          `((filePath . ,file) (originalFile . "one\n")))
      (vigil-mode 1)
      (vigil--scan (current-buffer))
      (pcase-let ((`(,write ,edit) (gethash file vigil--edits)))
        (should (equal (vigil-edit-before write) ""))
        (should (eq (vigil-edit-before edit) (vigil-edit-after write)))
        (should (equal (vigil-edit-after edit) "two\n"))))))

(ert-deftest vigil-lines-are-followed-even-without-diff ()
  "Where `diff' cannot say how two versions differ, or says what is not so,
what lies between their common beginning and end is taken to have changed:
the hunks still make the one of the other."
  (let ((old '("a" "b" "c" "d" "e"))
        (new '("a" "B" "c" "D" "e")))
    (dolist (program '("vigil-no-such-program" "false" "true"))
      (let* ((vigil-diff-program program)
             (moved (vigil--apply-hunks old (make-list 5 'old)
                                        (vigil--line-hunks old new) 'new)))
        (should (equal (car moved) new))
        (should (equal (cdr moved) '(old new new new old)))))
    ;; With diff: only what changed.
    (should (equal (cdr (vigil--apply-hunks old (make-list 5 'old)
                                            (vigil--line-hunks old new) 'new))
                   '(old new old new old)))))

(ert-deftest vigil-a-turns-changes-as-one-diff ()
  "A turn's diff is each file from before the turn's first edit to after its
last; a hunk of it can be undone in the file."
  (vigil-tests--with-edits
    (let ((case-fold-search nil)
          (first (cdr (vigil-edits--diff agent (vigil-turn--calls agent 1))))
          (all (cdr (vigil-edits--diff agent vigil--order))))
      (should (string-match-p "^-beta$" first))
      (should (string-match-p "^\\+beta2$" first))
      (should-not (string-match-p "GAMMA" first))
      (should (string-match-p "^-alpha$" all))
      (should (string-match-p "^\\+GAMMA$" all)))
    (save-window-excursion
      ;; With no call to start from: the latest turn.
      (let ((diff (vigil-turn-diff)))
        (with-current-buffer diff
          (setq-local case-fold-search nil)
          (should (derived-mode-p 'diff-mode))
          (should (string-match-p "turn 2 of 2" (buffer-string)))
          (should (string-match-p "^\\+GAMMA$" (buffer-string)))
          (should-not (string-match-p "^\\+BETA" (buffer-string)))
          (goto-char (point-min))
          (diff-hunk-next)
          (diff-apply-hunk t)))
      (with-current-buffer (find-buffer-visiting file)
        (should (equal (buffer-string) "ALPHA\nBETA\nbeta2\ngamma\n"))))))

;;;; Runs as compilations

(defmacro vigil-tests--with-run (output &rest body)
  "Run BODY with a run of `make' in `home' that printed OUTPUT and is going.
`run' is it, as cooked reads it; `agent' the agent buffer, shown."
  (declare (indent 1))
  `(vigil-tests--with-agent "> go\n"
     (require 'cooked-run)
     (let* ((cooked-run-directory (make-temp-file "vigil-runs" t))
            (runs (expand-file-name "proj.1" cooked-run-directory))
            (home (file-name-as-directory (make-temp-file "vigil-home" t)))
            (agent (current-buffer)))
       (unwind-protect
           (save-window-excursion
             (make-directory runs t)
             (write-region ,output nil (expand-file-name "1.000000-1.out" runs) nil 'silent)
             (write-region (json-serialize `((id . "1.000000-1") (session . "proj.1")
                                             (pid . ,(emacs-pid)) (cwd . ,home)
                                             (argv . ["sh" "-c" "make"]) (label . "make")
                                             (started . ,(- (float-time) 10))))
                           nil (expand-file-name "1.000000-1.json" runs) nil 'silent)
             (delete-other-windows)
             (switch-to-buffer agent)
             (let ((run (car (cooked-runs "proj.1"))))
               ,@body))
         (dolist (buffer (buffer-list))
           (when (or (buffer-local-value 'cooked-run--run buffer)
                     (and (buffer-file-name buffer)
                          (string-prefix-p home (buffer-file-name buffer))))
             (kill-buffer buffer)))
         (setq vigil-compile--shown nil)
         (delete-directory home t)
         (delete-directory cooked-run-directory t)))))

(ert-deftest vigil-a-runs-errors-are-walked-as-a-compilations ()
  "What a command printed is a compilation's output: `next-error' goes to
the errors in it, marked where it printed them uncoloured."
  (vigil-tests--with-run "building\nsrc/x.c:3:2: error: no\n\e[31mred\e[0m\n"
    (make-directory (expand-file-name "src" home))
    (with-temp-file (expand-file-name "src/x.c" home) (insert "one\ntwo\nthree\nfour\n"))
    (let ((buffer (cooked-run-buffer run)))
      (with-current-buffer buffer
        (should compilation-minor-mode)
        ;; Its keys, not compile's single letters.
        (should (eq (key-binding "g") #'cooked-run-refresh))
        (should (eq (key-binding "k") #'cooked-run-interrupt))
        (should (eq (key-binding (kbd "RET")) #'compile-goto-error))
        (vigil-compile--parse buffer)
        (goto-char (point-min))
        (search-forward "src/x.c")
        (should (get-char-property (1- (point)) 'face))
        (search-forward "red")
        ;; Its own colour, not compile's.
        (should (equal (get-char-property (1- (point)) 'face)
                       (get-text-property (1- (point)) 'face)))
        (should-not (get-text-property (1- (point)) 'font-lock-face)))
      (setq next-error-last-buffer buffer)
      (next-error)
      (with-current-buffer (window-buffer (selected-window))
        (should (equal (buffer-file-name) (expand-file-name "src/x.c" home)))
        (should (= (line-number-at-pos) 3))))))

(ert-deftest vigil-the-running-list-shows-the-command-at-point ()
  "In the list of what is running, the command on the cursor's line is shown
as it prints beside the list, and is what `next-error' walks."
  (vigil-tests--with-run "building\n"
    (let ((next-error-last-buffer nil))
      (require 'vigil-running)
      (vigil-running)
      (let ((list (get-buffer "*vigil running*")))
        (unwind-protect
            (progn
              (should (eq (window-buffer (selected-window)) list))
              (should (get-buffer-window (cooked-run-buffer run)))
              (should (eq next-error-last-buffer (cooked-run-buffer run))))
          (kill-buffer list))))))

(ert-deftest vigil-a-long-command-is-shown-as-it-runs ()
  "Asked for, a command still going a while after it began is shown in a
window of its own, as `compile' shows a build, and is what `next-error'
walks; one left in the background is not."
  (vigil-tests--with-run "building\n"
    (let ((vigil-show-runs-after 3)
          (call (vigil-call--make :id "m" :name "Bash" :start (- (float-time) 10)
                                  :input '((command . "make"))))
          (background (vigil-call--make :id "s" :name "Bash" :start (- (float-time) 10)
                                        :input '((command . "make") (run_in_background . t))))
          (next-error-last-buffer nil))
      (setq-local vigil--order (list background))
      (vigil-compile--watch)
      (should-not (gethash background vigil-compile--timed))
      (vigil-compile--due call agent)
      (let ((shown (get-buffer-window (cooked-run-buffer run))))
        (should shown)
        (should (eq (window-buffer (selected-window)) agent))
        (should (eq next-error-last-buffer (cooked-run-buffer run))))
      ;; Not when the agent is not on show.
      (delete-window (get-buffer-window (cooked-run-buffer run)))
      (switch-to-buffer "*scratch*")
      (setq vigil-compile--shown nil next-error-last-buffer nil)
      (vigil-compile--due call agent)
      (should-not next-error-last-buffer))))

(provide 'vigil-tests)
;;; vigil-tests.el ends here
