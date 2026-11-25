;;; vigil-status-tests.el --- A session, and its views -*- lexical-binding: t; -*-

;; Reports written the way `vigil hook' writes them, in a directory of the
;; test's own, of a session at work in the repository of
;; vigil-codebase-fixture.el.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-status-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-status)
(require 'vigil-codebase-fixture
         (expand-file-name "vigil-codebase-fixture.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defvar vigil-directory)

(defconst vigil-status-tests--program
  (expand-file-name "../bin/vigil"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The vigil of this checkout.")
(defvar vigil-status-tests--time 0)

(defun vigil-status-tests--write (session seconds report)
  "Write REPORT as SESSION's next report, SECONDS after the one before."
  (let* ((directory (expand-file-name session vigil-directory))
         (time (cl-incf vigil-status-tests--time seconds))
         (file (expand-file-name (format "%d-%05d-1.json" (floor time)
                                         (random 99999))
                                 directory)))
    (make-directory directory t)
    (with-temp-file file (insert (json-serialize report)))
    (set-file-times file (seconds-to-time time))
    file))

(defun vigil-status-tests--call (event tool id input &rest more)
  "A report of the call ID to TOOL with INPUT: EVENT, and MORE of it."
  `((hook_event_name . ,event) (tool_name . ,tool) (tool_use_id . ,id)
    (tool_input . ,input) ,@more))

(defmacro vigil-status-tests--with-session (&rest body)
  "Run BODY with the session \"proj.1\" reported, at work in the fixture's `root'.
Ten minutes ago, a prompt: a command of 3 seconds, one that reported no end,
and a reply.  Then a prompt: an edit, and a command still going."
  (declare (indent 0))
  `(vigil-codebase-tests--with-repository
     (let ((vigil-directory (make-temp-file "vigil-status" t))
           (vigil-status-tests--time (- (float-time) 600))
           (write (lambda (seconds report)
                    (vigil-status-tests--write "proj.1" seconds
                                               (append report `((cwd . ,root)))))))
       (vigil-survey-forget)
       (unwind-protect
           (progn
             (funcall write 0 '((hook_event_name . "UserPromptSubmit")
                                (prompt . "Make the tests pass\nall of them")))
             (funcall write 1 (vigil-status-tests--call
                               "PreToolUse" "Bash" "c1"
                               '((command . "make test") (description . "Run the tests"))))
             (funcall write 3 (vigil-status-tests--call
                               "PostToolUse" "Bash" "c1"
                               '((command . "make test") (description . "Run the tests"))
                               '(tool_response . ((stdout . "ok")))))
             (funcall write 1 (vigil-status-tests--call
                               "PreToolUse" "Bash" "c2" '((command . "./lint"))))
             (funcall write 5 '((hook_event_name . "Stop")
                                (last_assistant_message . "They pass.\n\nAll twelve.")))
             (funcall write 60 '((hook_event_name . "UserPromptSubmit")
                                 (prompt . "Now the docs")))
             (funcall write 2 (vigil-status-tests--call
                               "PostToolUse" "Edit" "e1" `((file_path . ,(concat root "c.txt")))
                               '(tool_response . ((ok . t)))))
             (funcall write 1 (vigil-status-tests--call
                               "PreToolUse" "Bash" "c3" '((command . "./serve"))))
             ,@body)
         (delete-directory vigil-directory t)
         (vigil-survey-forget)))))

(defmacro vigil-status-tests--in-buffer (&rest body)
  "Run BODY in the buffer `M-x vigil' shows for \"proj.1\"."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'vigil-ui-width) (lambda (&rest _) 120)))
     (let* ((vigil-status-detail (bound-and-true-p vigil-status-tests--detail))
            (buffer (save-window-excursion (vigil "proj.1"))))
       (unwind-protect (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(defvar vigil-status-tests--detail nil
  "Whether the buffers the tests open show what is at point beside the list.")

(ert-deftest vigil-status-reads-the-turns ()
  "A session's turns: prompt, calls and reply, and which calls are still going."
  (vigil-status-tests--with-session
    (let* ((turns (vigil-status-turns "proj.1"))
           (first (car turns))
           (second (cadr turns))
           (call (lambda (turn id)
                   (cl-find id (plist-get turn :calls)
                            :key #'vigil-survey-step-id :test #'equal))))
      (should (= (length turns) 2))
      (should (equal (vigil-survey-step-text (plist-get first :reply))
                     "They pass.\n\nAll twelve."))
      (should-not (plist-get second :reply))
      (should (= (round (- (plist-get first :end) (plist-get first :start))) 10))
      ;; c1 took its three seconds; c2 never said it ended, and its agent
      ;; went on: it is not running, and nobody knows how long it took.
      (should (= (round (vigil-status--took (funcall call first "c1"))) 3))
      (should-not (vigil-status--running-p (funcall call first "c2")))
      (should-not (vigil-status--took (funcall call first "c2")))
      ;; c3 is the last thing heard of: it is going.
      (should (vigil-status--running-p (funcall call second "c3")))
      (should (equal (vigil-status--counts (plist-get first :calls))
                     "2 calls: 2 commands; 1 reported no end"))
      (should (equal (vigil-status--counts (plist-get second :calls))
                     "2 calls: 1 command, 1 edit")))))

(ert-deftest vigil-status-says-durations-shortly ()
  (should (equal (mapcar #'vigil-status--duration '(0.44 12 185 3725 nil))
                 '("0.4s" "12s" "3m05s" "1h02m" ""))))

(ert-deftest vigil-status-finds-the-commits-and-the-changelog ()
  "The commits since a time, oldest first, with the versions each added."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (vigil-codebase-tests--write root "CHANGELOG.md"
                                 "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-01\n")
    (vigil-codebase-tests--git root "add" "CHANGELOG.md")
    (vigil-codebase-tests--git root "commit" "-q" "-m" "Keep a changelog")
    (vigil-codebase-tests--git root "tag" "v0.2.0")
    (let ((commits (vigil-status-commits root (- (float-time) 600))))
      ;; The fixture's, and this one last.
      (should (> (length commits) 1))
      (let ((last (car (last commits))))
        (should (equal (plist-get last :subject) "Keep a changelog"))
        (should (equal (plist-get last :versions) '("Unreleased" "0.2.0")))
        (should (string-match-p "tag: v0.2.0" (plist-get last :refs))))
      (should-not (plist-get (car commits) :versions))
      ;; None of them is from before the time asked of.
      (should-not (vigil-status-commits root (+ (float-time) 600))))))

(ert-deftest vigil-status-shows-the-session-in-short ()
  "The status view: what it is, how much it did, and the commits since."
  (skip-unless (executable-find "git"))
  (vigil-status-tests--with-session
    (vigil-status-tests--in-buffer
      (let ((text (buffer-string)))
        (should (equal vigil-status--root root))
        ;; What it is of is in the header line, and its views in the tab line.
        (should (string-match-p "proj\\.1 .*not open in this Emacs" header-line-format))
        (should (string-match-p "s Status .*P Prompts .*a Answers .*c Commands .*l Changes .*b Build"
                                tab-line-format))
        (should (string-match-p "^Prompts +2, the last at" text))
        (should (string-match-p "^Calls +4: 3 commands, 1 edit; 1 reported no end$" text))
        (should (string-match-p "^Running +1 call: ./serve$" text))
        (should (string-match-p "No snapshot is kept of it" text))
        (should (string-match-p "^ +2 +.*Now the docs" text))
        (should (string-match-p "^Commits since it began" text))
        ;; No line ends in spaces, and none is wider than it was laid out in.
        (should-not (string-match-p " $" text))
        (should (<= (apply #'max (mapcar #'string-width (split-string text "\n"))) 120))))))

(ert-deftest vigil-status-shows-prompts-answers-commands-and-the-build ()
  "Each view of the buffer, and what the keys at point do."
  (skip-unless (executable-find "git"))
  (vigil-status-tests--with-session
    (vigil-status-tests--in-buffer
      ;; Prompts: each with what it led to, all but the last folded.
      (vigil-status-show-prompts)
      (let ((text (buffer-string)))
        (should (eq vigil-status--view 'prompts))
        (should (string-match-p "^ +1 +.*Make the tests pass all of them +2 (1 failed)$" text))
        ;; The prompt as it was written: its indentation is not in the text.
        (should (string-match-p "^Make the tests pass\nall of them$" text))
        (should (string-match-p "^ +\\+1\\.0s +3\\.0s +command +Run the tests$" text))
        (should (string-match-p "command +no end +\\./lint$" text))
        (should (string-match-p "^They pass\\.\n\nAll twelve\\.$" text))
        (should (string-match-p "command +running +./serve$" text))
        (should (string-match-p "No reply yet" text)))
      ;; The last prompt first, and showing; the one before it folded.
      (goto-char (point-min))
      (vigil-status-next-heading)
      (should (looking-at-p " +2 "))
      (should-not (vigil-review--folded-p (vigil-review--fold-here)))
      (vigil-status-next-heading)
      (should (looking-at-p " +1 "))
      (should (vigil-review--folded-p (vigil-review--fold-here)))
      ;; Folded or not is said at the line's beginning.
      (should (equal (overlay-get (overlay-get (vigil-review--fold-here)
                                               'vigil-review-marker)
                                  'display)
                     "▸"))
      (vigil-status-act)
      (should-not (vigil-review--folded-p (vigil-review--fold-here)))
      (vigil-status-copy)
      (should (equal (current-kill 0) "Make the tests pass\nall of them"))
      ;; Drawn again, it is as it was left: both open.
      (vigil-status--render)
      (goto-char (point-min))
      (vigil-status-next-heading)
      (should-not (vigil-review--folded-p (vigil-review--fold-here)))
      (vigil-status-next-heading)
      (should (looking-at-p " +1 "))
      (should-not (vigil-review--folded-p (vigil-review--fold-here)))
      ;; Answers: the replies alone, and the one at point copied whole.
      (vigil-status-show-answers)
      (let ((text (buffer-string)))
        (should (string-match-p "^ +1 +[0-9:]+ +Make the tests pass all of them\nThey pass\\." text))
        (should-not (string-match-p "Run the tests" text))
        (should (string-match-p "1 prompt has no reply yet" text)))
      (goto-char (point-min))
      (vigil-status-next-heading)
      (forward-line 1)
      (vigil-status-copy)
      (should (equal (current-kill 0) "They pass.\n\nAll twelve."))
      ;; Commands: as they ran, then the longest first.
      (vigil-status-show-commands)
      (let ((text (buffer-string)))
        (should (string-match-p "^Commands +3, .* in all$" text))
        (should (string-match-p "^No end +1 ended" text))
        (should (string-match-p "\\./serve\n.* \\./lint\n.*Run the tests" text)))
      (vigil-status-by-duration)
      (should (string-match-p "./serve\n.*Run the tests\n.* \\./lint" (buffer-string)))
      ;; Build: the prompts and the commits made since, the last first.
      (vigil-status-show-build)
      (let ((text (buffer-string)))
        (should (string-match-p
                 "◆ .*\n +[0-9:]+ +2 +Now the docs\n +[0-9:]+ +1 +Make the tests pass all of them"
                 text)))
      (goto-char (point-min))
      (search-forward "◆")
      (should (stringp (get-text-property (point) 'vigil-status-commit)))
      ;; What acts on the agent's buffer says that there is none.
      (should (string-match-p "not open in this Emacs"
                              (cadr (should-error (vigil-status-context)
                                                  :type 'user-error)))))))

(ert-deftest vigil-status-shows-what-is-changing-now ()
  "The changes view: the files that differ since the last prompt, the last
written first and its diff showing; read again, it goes to what changed."
  (skip-unless (executable-find "git"))
  (vigil-status-tests--with-session
    (let ((vigil-snapshot-program vigil-status-tests--program)
          (process-environment
           (append '("VIGIL_SESSION=proj.1" "GIT_CONFIG_GLOBAL=/dev/null"
                     "GIT_CONFIG_SYSTEM=/dev/null")
                   process-environment)))
      ;; A snapshot as the hook keeps one when a prompt is given.
      (with-temp-buffer
        (insert (json-serialize `((hook_event_name . "UserPromptSubmit") (session_id . "s1")
                                  (prompt_id . "p1") (cwd . ,root))))
        (should (eq 0 (call-process-region (point-min) (point-max)
                                           vigil-status-tests--program t t nil "snapshot"))))
      (vigil-codebase-tests--write root "a.py" "def f():\n    z = 1\n    return z\n\n\ndef g():\n    return 3\n")
      (set-file-times (expand-file-name "a.py" root) (time-subtract nil 60))
      (vigil-codebase-tests--write root "made.txt" "one\ntwo\n")
      (vigil-status-tests--in-buffer
        (vigil-status-show-changes)
        (let ((text (buffer-string)))
          (should (string-match-p "^Counted +since the last prompt" text))
          (should (string-match-p "^Changed +1 new, 1 changed +\\+3 −1$" text))
          ;; The last written first, in the list and under it.
          (should (string-match-p "^  \\+ made\\.txt +\\+2 .*\n  ~ a\\.py +\\+1 −1" text))
          (should (string-match-p "^    \\+one\n    \\+two$" text))
          (should (string-match-p "^    -    return 2\n    \\+    return 3$" text)))
        ;; made.txt's diff shows, and a.py's waits to be opened.
        (vigil-status--goto-file "made.txt")
        (should-not (vigil-review--folded-p (vigil-review--fold-here)))
        (goto-char (point-min))
        (search-forward "+    return 3")
        (should (invisible-p (point)))
        ;; A line of a diff is that line of its file.
        (should (equal (get-text-property (point) 'vigil-status-file) "a.py"))
        (should (= (get-text-property (point) 'vigil-status-line) 7))
        ;; Written again, and read again: it goes to the line that is new.
        (vigil-codebase-tests--write root "made.txt" "one\ntwo\nthree\n")
        (vigil-status--auto)
        (should (looking-at-p "    \\+three"))
        ;; Counted from the session's beginning, where it is the same here.
        (vigil-status-toggle-since)
        (should (string-match-p "^Counted +since the session began" (buffer-string)))))))

(ert-deftest vigil-status-gives-each-prompt-what-changed-after-it ()
  "A message sent while the agent works is kept under its turn's id, and has
its own snapshot: what changed after it is its own, not the turn's first
prompt's."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let ((vigil-snapshot-program vigil-status-tests--program)
          (process-environment
           (append '("VIGIL_SESSION=proj.1" "GIT_CONFIG_GLOBAL=/dev/null"
                     "GIT_CONFIG_SYSTEM=/dev/null")
                   process-environment))
          (hook (lambda (event)
                  (with-temp-buffer
                    (insert (json-serialize `((hook_event_name . ,event) (session_id . "s1")
                                              (prompt_id . "p1") (cwd . ,root))))
                    (should (eq 0 (call-process-region
                                   (point-min) (point-max)
                                   vigil-status-tests--program t t nil "snapshot")))))))
      (funcall hook "UserPromptSubmit")
      (vigil-codebase-tests--write root "first.txt" "after the prompt\n")
      ;; The same turn, the same id: a message sent meanwhile.
      (funcall hook "UserPromptSubmit")
      (vigil-codebase-tests--write root "second.txt" "after the message\nand more\n")
      (funcall hook "Stop")
      (let* ((span (vigil-status--span root "proj.1"))
             (built (vigil-status--read-built root span))
             (files (lambda (entry)
                      (mapcar (lambda (change) (plist-get change :file)) (nth 2 entry)))))
        ;; One a turn for the review; one a prompt here.
        (should (= (length (plist-get span :prompts)) 1))
        (should (= (length (plist-get built :prompts)) 2))
        (should (equal (funcall files (car (plist-get built :prompts))) '("first.txt")))
        (should (equal (funcall files (cadr (plist-get built :prompts))) '("second.txt")))
        (should (= (length (plist-get built :changes)) 2))))))

(ert-deftest vigil-status-draws-a-turn-as-a-timeline ()
  "A turn's timeline: what its agent was doing in each share of it."
  (vigil-status-tests--with-session
    (let* ((turns (vigil-status-turns "proj.1"))
           (first (car turns))
           (strip (vigil-status--strip first 10)))
      ;; Ten seconds, a character each: a second of nothing, three of a
      ;; command, a command that failed in the fifth, then nothing.
      ;; `make test' runs tests: it is drawn as a test.
      (should (equal (substring-no-properties strip) "─▞▞▞─█────"))
      (should (eq (get-text-property 1 'face strip) 'vigil-ui-kind-test))
      (should (eq (get-text-property 5 'face strip) 'vigil-ui-bad))
      (should (eq (get-text-property 0 'face strip) 'vigil-ui-dim))
      ;; In a list a turn is as long as it was, among the turns, and never
      ;; nothing.
      (let ((vigil-status--turns turns)
            (vigil-status-strip-width 20))
        (should (= (length (vigil-status--strip-in-list first)) 20))
        (should (= (length (vigil-status--strip-in-list (cadr turns))) 6)))
      ;; An edit takes no time, and is drawn where it was made; a command
      ;; after which the files differed is drawn as an edit is.
      (should (equal (substring-no-properties (vigil-status--strip (cadr turns) 3))
                     "──▓"))
      (let ((vigil-status--wrote (make-hash-table :test #'equal)))
        (puthash "c1" t vigil-status--wrote)
        (should (equal (substring-no-properties (vigil-status--strip first 10))
                       "─▓▓▓─█────"))
        (should (equal (vigil-status--counts (plist-get first :calls))
                       "2 calls: 1 command, 1 write; 1 reported no end"))))))

(ert-deftest vigil-status-shows-what-is-at-point-beside-the-list ()
  "With the detail, the views are lists, and what is at point is drawn in
full in the buffer beside."
  (skip-unless (executable-find "git"))
  (vigil-status-tests--with-session
    (let ((vigil-status-tests--detail t))
      (vigil-status-tests--in-buffer
        (vigil-status-show-prompts)
        (let ((text (buffer-string)))
          ;; A line a prompt, with its timeline; nothing under it.
          (should (string-match-p "^ +1 +[0-9:]+ +10s +─+▞+[─█▞]* +Make the tests pass all of them" text))
          (should-not (string-match-p "They pass" text))
          (should (string-match-p "█ command .* ─ between calls" text)))
        ;; It lands on the last prompt, and that is what is beside.
        (should (equal (vigil-status--thing) '(turn . 2)))
        (vigil-status-next-heading)
        (should (equal (vigil-status--thing) '(turn . 1)))
        (with-current-buffer (vigil-status--detail-draw (vigil-status--thing))
          (let ((text (buffer-string)))
            (should (string-match-p "Prompt 1 .*10s .*2 calls: 2 commands; 1 reported no end"
                                    header-line-format))
            (should (string-match-p "^Prompt\nMake the tests pass\nall of them$" text))
            (should (string-match-p "\\+1\\.0s +3\\.0s +command +Run the tests$" text))
            (should (string-match-p "^Reply\nThey pass\\.\n\nAll twelve\\.$" text)))
          ;; A call there is opened as one in the list is: here, with no
          ;; agent's buffer, that is said.
          (goto-char (point-min))
          (search-forward "Run the tests")
          (should (equal (get-text-property (point) 'vigil-status-call) "c1"))
          (should-error (vigil-status-act) :type 'user-error))
        ;; In the answers, the answer alone.
        (vigil-status-show-answers)
        (should-not (string-match-p "They pass" (buffer-string)))
        (should (equal (vigil-status--thing) '(answer . 1)))
        (with-current-buffer (vigil-status--detail-draw (vigil-status--thing))
          (should (string-match-p "They pass\\.\n\nAll twelve\\." (buffer-string)))
          (should-not (string-match-p "Run the tests" (buffer-string))))
        ;; A command, and a commit.
        (vigil-status-show-commands)
        (should (eq (car (vigil-status--thing)) 'call))
        (with-current-buffer (vigil-status--detail-draw '(call . "c1"))
          (should (string-match-p "^Run the tests$" (buffer-string)))
          (should (string-match-p "^Took +3\\.0s$" (buffer-string))))
        (vigil-status-show-build)
        (goto-char (point-min))
        (search-forward "◆")
        (should (eq (car (vigil-status--thing)) 'commit))
        (with-current-buffer (vigil-status--detail-draw (vigil-status--thing))
          (should (string-match-p "Commit [0-9a-f]\\{7\\}" header-line-format))
          (should (string-match-p "^Changed\n  .*|" (buffer-string))))
        ;; Without it, what a prompt led to is under its line again.
        (vigil-status-toggle-detail)
        (vigil-status-show-prompts)
        (should (string-match-p "They pass" (buffer-string)))))))

(ert-deftest vigil-status-tells-a-look-from-a-command ()
  "A command that only reads is a look: by its words, and by what it did."
  (dolist (command '("cat a | grep b" "sed -n 1,5p f; git log --oneline -3"
                     "git -c core.x=1 status" "grep x f 2>/dev/null" "ls && wc -l f"
                     "grep x f 2>&1 | head"))
    (should (vigil-status-looks-p command)))
  ;; What its words show it writes; what a script does, they do not.
  (dolist (command '("echo hi > out.txt" "sed -i s/a/b/ f" "rm -rf /tmp/x" "cp a b"
                     "cat a | tee b"))
    (should (vigil-status-writes-p command)))
  (dolist (command '("cat a > /dev/null" "python3 gen.py" "make test" "git commit -m x"
                     "python3 - <<'EOF'\nopen('b.el','w')\nEOF" "grep x f 2>&1" nil))
    (should-not (vigil-status-writes-p command)))
  (should (eq (vigil-status--kind
               (vigil-survey-step--make :id "w" :kind 'command :command "cp a b"))
              'wrote))
  (dolist (command '("sed -i s/a/b/ f" "git commit -m x" "echo hi > out.txt"
                     "python3 - <<'EOF'\nprint(1)\nEOF" "emacs --batch -l t.el"
                     "find . -name x -delete" "bin/vigil doctor | head"
                     "cd /tmp && rm -rf x" "" nil))
    (should-not (vigil-status-looks-p command)))
  ;; One that looks like a look, and after which the files differed, is not.
  (let ((call (vigil-survey-step--make :id "c9" :kind 'command :command "cat a"))
        (vigil-status--wrote (make-hash-table :test #'equal)))
    (should (eq (vigil-status--kind call) 'look))
    (puthash "c9" t vigil-status--wrote)
    (should (eq (vigil-status--kind call) 'wrote))))

(ert-deftest vigil-status-leaves-looks-out-of-the-commands ()
  "The list of commands is of those that ran; those that looked are counted,
and listed when asked for."
  (skip-unless (executable-find "git"))
  (vigil-status-tests--with-session
    (vigil-status-tests--write
     "proj.1" 1 (vigil-status-tests--call
                 "PostToolUse" "Bash" "c4"
                 '((command . "grep -n TODO src/*.py") (description . "Find the to-dos"))
                 '(tool_response . ((stdout . "")))))
    (vigil-status-tests--in-buffer
      (should (string-match-p "^Calls +5: 3 commands, 1 look, 1 edit; 1 reported no end$"
                              (buffer-string)))
      (vigil-status-show-commands)
      (let ((text (buffer-string)))
        (should (string-match-p "^Commands +3, " text))
        (should (string-match-p "^Looks +1 more only looked, and are left out" text))
        (should-not (string-match-p "Find the to-dos" text)))
      (vigil-status-toggle-looks)
      (let ((text (buffer-string)))
        (should (string-match-p "^Commands +4, " text))
        (should (string-match-p " look +Find the to-dos$" text))
        (should (string-match-p "^For +1 look   1 test   2 run$" text))
        (should (string-match-p " test +Run the tests$" text))
        (should (string-match-p " run +no end +\\./lint$" text))))))

(ert-deftest vigil-status-lays-a-command-out-to-be-read ()
  "A command shown whole is laid out by shfmt and highlighted, the program
inside it under it; one with no description is listed as itself, on a line.
What is copied is the command as it was given."
  (skip-unless (executable-find "shfmt"))
  (let ((command "cd src && grep -rn TODO . | sort | uniq -c | sort -rn | head -20 && python3 -c 'import sys\nprint(sys.version)'"))
    (with-temp-buffer
      (vigil-status--insert-command command "c1")
      (let ((text (buffer-string)))
        ;; A long chain is broken before its operators, and the Python is
        ;; taken out to a block of its own.
        (should (string-match-p "^cd src" text))
        (should (string-match-p "\n +&& grep -rn TODO" text))
        (should (string-match-p "python3 -c ‹1›" text))
        (should (string-match-p "^import sys\n+print(sys.version)$" text))
        (should-not (string-match-p "python3 -c 'import" text)))
      ;; Highlighted as shell; and it copies as it was given.
      (goto-char (point-min))
      (should (get-text-property (point) 'face))
      (search-forward "grep")
      (should (equal (get-text-property (point) 'vigil-status-text) command))
      (should (equal (get-text-property (point) 'vigil-status-call) "c1")))
    ;; Listed: its agent's words where it said why, and else itself.
    (let ((said (vigil-survey-step--make :kind 'command :command "make test"
                                         :text "Run the tests"))
          (unsaid (vigil-survey-step--make :kind 'command :command "cd src && ls -la"
                                           :text "cd src && ls -la")))
      (should (equal (vigil-status--call-said said) "Run the tests"))
      (should (equal (substring-no-properties (vigil-status--call-said unsaid))
                     "cd src && ls -la"))
      (should (text-property-not-all 0 (length (vigil-status--call-said unsaid))
                                     'face nil (vigil-status--call-said unsaid))))
    ;; Without it, as it was given.
    (let ((vigil-status-tidy nil))
      (with-temp-buffer
        (vigil-status--insert-command command "c1")
        (should (string-match-p "python3 -c 'import sys" (buffer-string)))))))

(ert-deftest vigil-status-says-what-shellcheck-says ()
  "What shellcheck says of a command is under it; of a sound one, nothing."
  (skip-unless (executable-find "shellcheck"))
  (let ((notes (vigil-status-check "for f in $(ls *.txt); do cat $f; done")))
    (should (cl-some (lambda (note) (equal (nth 4 note) "SC2045")) notes))
    (should (equal (nth 2 (car notes)) "error"))
    (should (= (car (car notes)) 1)))
  (should-not (vigil-status-check "ls -la | head -3"))
  (should-not (let ((vigil-status-shellcheck nil))
                (vigil-status-check "for f in $(ls *.txt); do cat $f; done")))
  (with-temp-buffer
    (vigil-status--insert-command "for f in $(ls *.txt); do cat $f; done" "c1")
    (should (string-match-p "^shellcheck, of the command as it was given\n +1:[0-9]+ +error +.*SC2045$"
                            (buffer-string)))))

(ert-deftest vigil-status-says-what-a-command-was-for-and-goes-by ()
  "Beside a command: what it was for and why, its programs, and what the
Python inside it does."
  (skip-unless (and (executable-find "git") (executable-find "shfmt")
                    (executable-find vigil-purpose-python)))
  (vigil-status-tests--with-session
    (vigil-status-tests--write
     "proj.1" 1 (vigil-status-tests--call
                 "PostToolUse" "Bash" "c5"
                 '((command . "python3 - <<'EOF'\nimport json\ns = open('a.py').read()\nassert 'f' in s\nopen('a.py', 'w').write(s)\nEOF\nmake test && git commit -qm done")
                   (description . "Change f, test and commit"))
                 '(tool_response . ((stdout . "12 passed in 0.3s")))))
    (let ((vigil-status-tests--detail t))
      (vigil-status-tests--in-buffer
        (with-current-buffer (vigil-status--detail-draw '(call . "c5"))
          (let ((text (buffer-string)))
            (should (string-match-p "^Change f, test and commit$" text))
            (should (string-match-p "^What it was for\n" text))
            ;; No snapshot says which files differed: the Python does.
            (should (string-match-p "^  code +a\\.py, by the Python inside it$" text))
            (should (string-match-p "^  test +make test: 12 passed in 0\\.3s$" text))
            (should (string-match-p "^  git +git commit$" text))
            (should (string-match-p "^Programs, where each is now\n" text))
            (should (string-match-p "^  git +.*/git$" text))
            (should (string-match-p "^Python: python3, from its standard input\n" text))
            (should (string-match-p "^  imports +json, of Python's own$" text))
            (should (string-match-p "^  writes +a\\.py$" text))
            (should (string-match-p "^  reads +a\\.py$" text))
            (should (string-match-p "^  asserts +1$" text))))
        ;; And in the list, in a word each: there the Python is not looked
        ;; into.
        (vigil-status-show-commands)
        (should (string-match-p " test git +Change f, test and commit$"
                                (buffer-string)))))))

(ert-deftest vigil-status-fills-text-and-leaves-it-as-written ()
  "A block is filled to its width, an item hanging under its words; what is
copied is the text as it was written."
  (should (equal (vigil-ui-fill "one two three four five six" 12)
                 "one two\nthree four\nfive six"))
  (should (equal (vigil-ui-fill "- one two three four\n```\na long line of code here\n```" 12)
                 "- one two\n  three four\n```\na long line of code here\n```"))
  (should (equal (vigil-ui-fill "| a table | is left | as it is |" 12)
                 "| a table | is left | as it is |"))
  (should (equal (vigil-ui-fill "averyveryverylongword then" 12)
                 "averyveryverylongword\nthen")))

(provide 'vigil-status-tests)
;;; vigil-status-tests.el ends here
