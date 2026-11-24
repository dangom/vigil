;;; vigil-codebase-tests.el --- Where a repository is changing, and why -*- lexical-binding: t; -*-

;; A repository made for the test, with git, and an archive written the way
;; `vigil hook' writes one; nothing of this machine's is read, and what is
;; kept to read faster is kept in the test's own directories.  Skipped
;; without git.  vigil-history.el and vigil-codebase.el need nothing else
;; of vigil, nor cooked: only `emacs/' is on the load path.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-codebase-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-history)
(require 'vigil-codebase)
(require 'vigil-codebase-fixture
         (expand-file-name "vigil-codebase-fixture.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

;;;; The archive

(ert-deftest vigil-history-reads-commands-as-text ()
  "The words of a command that could name files, with the programs they are
given to; what is quoted or in a heredoc is not the command's own, and what
a redirection writes to is written."
  (should (equal (car (vigil-history--words
                       "cd e2e && FOO=1 uv run pytest tests/x.py::test_a --cfg=a/b.toml > out/log.txt 2>&1"))
                 '(("tests/x.py" "uv" argument) ("a/b.toml" "uv" argument)
                   ("out/log.txt" "uv" written))))
  (should (equal (car (vigil-history--words "grep -n \"a\\|b c/d.py\" src/y.py | wc -l"))
                 '(("src/y.py" "grep" argument))))
  (let ((words (vigil-history--words
                "python3 - <<'EOF'\nopen('emacs/x.el').read()\nEOF\nmake test")))
    (should (member '("emacs/x.el" nil written) (car words)))
    (should-not (cl-find 'argument (car words) :key #'caddr))
    (should (equal (cdr words) '("python3" "make"))))
  (should (vigil-history--runs-p '("sed" "make")))
  (should-not (vigil-history--runs-p '("sed" "grep" "cd")))
  (should (equal (vigil-history--mentions
                  "  File \"src/a.py\", line 12, in f\nerror: src/lib.rs:40:5 bad\n")
                 '(("src/a.py" . 12) ("src/lib.rs" . 40)))))

(ert-deftest vigil-history-says-what-agents-did-to-a-file ()
  "From the archive: the edits of a file and their prompts, the commands that
ran it or named a line of it, and the ones that seem to have written it."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((history (vigil-history root '("a.py" "b.el" "c.txt" "d.sh")))
           (text (lambda (prompt) (plist-get prompt :text)))
           (commands (lambda (file)
                       (mapcar (lambda (run) (list (plist-get (car run) :call) (cadr run)
                                                   (plist-get (car run) :status)))
                               (vigil-history-runs history file)))))
      ;; The edit, and the prompt it goes back to.
      (should (equal (mapcar (lambda (edit) (plist-get edit :call))
                             (vigil-history-edits history "a.py"))
                     '("e1")))
      (should (equal (mapcar (lambda (entry) (list (funcall text (car entry))
                                                   (nth 1 entry) (nth 2 entry)))
                             (vigil-history-prompts-of history "a.py"))
                     '(("rename the variable in f\nplease" 1 0))))
      ;; Ran twice; the second time what it printed names a line too, and a
      ;; command is counted once.  The grep that only read it is not one.
      (should (equal (funcall commands "a.py")
                     '(("c2" named done) ("c1" named done))))
      ;; Never answered: failed.
      (should (equal (funcall commands "d.sh") '(("c5" named unanswered))))
      ;; Written by a command: no edit, but a prompt all the same.
      (should-not (vigil-history-edits history "b.el"))
      (should (equal (mapcar (lambda (command) (plist-get command :call))
                             (vigil-history-writes history "b.el"))
                     '("c4")))
      (should (equal (mapcar (lambda (entry) (list (funcall text (car entry))
                                                   (nth 1 entry) (nth 2 entry)))
                             (vigil-history-prompts-of history "c.txt"))
                     '(("now b" 0 1))))
      (should-not (funcall commands "b.el"))
      ;; Which edit wrote these lines, by their text; a line that says
      ;; little (`z = 1', a brace) is not counted, and one no edit wrote has
      ;; no origin.
      (should (equal (mapcar (lambda (origin) (cons (plist-get (car origin) :call)
                                                    (cdr origin)))
                             (vigil-history-origin history "a.py"
                                                   '("    z = 1" "    return z" "}")))
                     '(("e1" . 1))))
      (should-not (vigil-history-origin history "a.py" '("    return 2")))
      ;; The prompts of a stretch of time.
      (should (equal (mapcar text (vigil-history-prompts-between history (- now 700) now))
                     '("rename the variable in f\nplease" "now b")))
      ;; Asked again with nothing new: the same, not read again.
      (should (eq (vigil-history root '("a.py" "b.el" "c.txt" "d.sh")) history)))))

(ert-deftest vigil-history-reads-what-pi-did ()
  "pi's edits, writes and commands go back to its prompts as Claude Code's do:
a file named from where pi works, a patch given as text, a command said to
have failed."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((t0 (- (truncate now) 300))
           (line (lambda (time event)
                   (concat (json-serialize
                            `((t . ,time) (host . "proj.2") (hosted . t)
                              (event . ((agent . "pi") (session_id . "pi1")
                                        (prompt_id . "pp1") (cwd . ,root)
                                        ,@event))))
                           "\n"))))
      (write-region (concat (json-serialize `((session_id . "pi1") (host . "proj.2")
                                              (file . "2026/11/pi1.jsonl") (cwd . ,root)))
                            "\n")
                    nil (expand-file-name "index.jsonl" archive) t 0)
      (with-temp-file (expand-file-name "2026/11/pi1.jsonl" archive)
        (insert
         (funcall line t0 '((hook_event_name . "UserPromptSubmit") (prompt . "make it v")))
         (funcall line (+ t0 5)
                  `((hook_event_name . "PostToolUse") (tool_name . "edit")
                    (tool_use_id . "pc1")
                    (tool_input . ((path . "a.py")
                                   (edits . [((oldText . "z = 1") (newText . "v = 1"))])))
                    (tool_response
                     . ((content . [((type . "text") (text . "Replaced 1 block."))])
                        (details . ((patch . "--- a.py\n+++ a.py\n@@ -2,2 +2,2 @@\n-    z = 1\n-    return z\n+    v = 1\n+    return v\n")))))))
         (funcall line (+ t0 10)
                  '((hook_event_name . "PostToolUse") (tool_name . "write")
                    (tool_use_id . "pc2") (created . t)
                    (tool_input . ((path . "made.txt") (content . "made by pi\nfor a test")))
                    (tool_response . ((content . [((type . "text") (text . "Wrote."))])))))
         (funcall line (+ t0 15)
                  '((hook_event_name . "PostToolUse") (tool_name . "bash")
                    (tool_use_id . "pc3") (is_error . t)
                    (tool_input . ((command . "python3 a.py")))
                    (tool_response . ((content . [((type . "text") (text . "boom"))])))))))
      (let* ((history (vigil-history root))
             (edits (vigil-history-prompt-edits history "pp1")))
        (should (equal (plist-get (vigil-history-prompt history "pp1") :text) "make it v"))
        (should (equal (mapcar #'car edits) '("a.py" "made.txt")))
        (should (equal (plist-get (cdr (car edits)) :added) '("    v = 1" "    return v")))
        (should (= (plist-get (cdr (car edits)) :removed) 2))
        (should (equal (plist-get (cdr (cadr edits)) :added) '("made by pi" "for a test")))
        (should (plist-get (cdr (cadr edits)) :created))
        ;; Its prompt is among those behind the file, the newest.
        (should (equal (plist-get (car (car (vigil-history-prompts-of history "a.py"))) :prompt)
                       "pp1"))
        ;; Its command ran the file, and is said to have failed.
        (let ((run (car (vigil-history-runs history "a.py"))))
          (should (equal (plist-get (car run) :prompt) "pp1"))
          (should (eq (plist-get (car run) :status) 'failed)))
        ;; A line it wrote is its.
        (should (equal (plist-get (car (car (vigil-history-origin
                                             history "a.py" '("    return v"))))
                                  :prompt)
                       "pp1"))))))

(ert-deftest vigil-history-reads-only-what-is-new ()
  "A session that has grown is read from where it was left, in this Emacs
or, from what was kept, in another."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((session (expand-file-name "2026/11/s1.jsonl" archive))
           (state (vigil-history--read session))
           (size (file-attribute-size (file-attributes session))))
      (should (= (vigil-history--file-offset state) size))
      (should (= (length (vigil-history--file-prompts state)) 2))
      (write-region
       (vigil-codebase-tests--event
        (truncate now) '((hook_event_name . "UserPromptSubmit") (prompt_id . "p3")
                         (prompt . "and c")))
       nil session t 'silent)
      ;; Half a line, still being written, is left for next time.
      (write-region "{\"t\":1,\"event\":{\"hook_event_name\":\"UserPromptSubmit\"" nil
                    session t 'silent)
      (should (eq (vigil-history--read session) state))
      (should (= (length (vigil-history--file-prompts state)) 3))
      (should (< (vigil-history--file-offset state)
                 (file-attribute-size (file-attributes session))))
      ;; Kept, and read back by an Emacs that has read nothing.
      (vigil-history--save session state)
      (let* ((vigil-history--files (make-hash-table :test #'equal))
             (again (vigil-history--load session)))
        (should (= (vigil-history--file-offset again) (vigil-history--file-offset state)))
        (should (equal (vigil-history--file-prompts again)
                       (vigil-history--file-prompts state)))
        (should (equal (vigil-history--file-order again)
                       (vigil-history--file-order state)))
        (should (equal (gethash "c1" (vigil-history--file-commands again))
                       (gethash "c1" (vigil-history--file-commands state))))))))

(ert-deftest vigil-history-reads-the-code-commands-ran ()
  "What the programs of a command said they ran: the command of the archive it
was, by its text and when it began, is said to have run those functions of
the file, in place of only having named it.  A run the archive does not
know is a command of its own; one of another directory is not this
repository's."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((t0 (- (truncate now) 600))
           (run (lambda (session name command cwd &rest files)
                  (let ((dir (expand-file-name (format "%s/%s" session name)
                                               vigil-history-coverage-directory)))
                    (make-directory dir t)
                    (with-temp-file (expand-file-name "command.txt" dir) (insert command))
                    (with-temp-file (expand-file-name "cwd.txt" dir) (insert cwd))
                    (cl-loop for (file . said) in files
                             do (with-temp-file (expand-file-name file dir)
                                  (insert (json-serialize said))))))))
      ;; The command c1, which began at t0+20: two programs of it.
      (funcall run "proj.1" (format "%d-101" (+ t0 22)) "python3 a.py" root
               `("python-101.json" . ((files . ((,(intern (concat root "a.py")) . ["<module>" "f"])
                                                (,(intern "/elsewhere/site.py") . ["x"])))))
               `("node-102-0.json" . ((files . ((,(intern (concat root "a.py")) . ["g"])
                                                (,(intern (concat root "d.sh")) . []))))))
      ;; One the archive has no report of.
      (funcall run "proj.1" (format "%d-103" (+ t0 500)) "pytest -q" root
               `("python-103.json" . ((files . ((,(intern (concat root "a.py")) . ["f"]))))))
      ;; One of somewhere else.
      (funcall run "other.1" (format "%d-104" (+ t0 22)) "python3 a.py" "/elsewhere"
               `("python-104.json" . ((files . ((,(intern "/elsewhere/a.py") . ["f"]))))))
      (let* ((history (vigil-history root '("a.py" "b.el" "c.txt" "d.sh")))
             (runs (mapcar (lambda (run)
                             (list (or (plist-get (car run) :call)
                                       (plist-get (car run) :command))
                                   (cadr run) (cddr run)))
                           (vigil-history-runs history "a.py"))))
        (should (equal runs
                       '(("pytest -q" ran ("f"))
                         ("c2" named nil)
                         ("c1" ran ("<module>" "f" "g")))))
        ;; A file that ran and names no function still ran.
        (should (equal (mapcar (lambda (run) (list (plist-get (car run) :call) (cadr run)))
                               (vigil-history-runs history "d.sh"))
                       '(("c5" named) ("c1" ran))))
        ;; Shown with the file.
        (with-temp-buffer
          (let ((file (cl-find "a.py" (vigil-codebase-files
                                       (vigil-codebase-commits root 30) root)
                               :key (lambda (f) (plist-get f :file)) :test #'equal)))
            (vigil-codebase--insert-file file history root 30))
          (should (string-match-p
                   "  2×  python3 a\\.py  ran, named  ·  last .*  ok\n +ran: <module>, f, g\n"
                   (buffer-substring-no-properties (point-min) (point-max)))))))))

;;;; The repository

(ert-deftest vigil-codebase-reads-what-git-says ()
  "How much each file of a commit changed, and whether it was made or
removed; and, of a diff, the hunks by the functions git names them by."
  (should (equal (with-temp-buffer
                   (insert "\x01" "abc\x02" "100\x02" "T\x02" "Add it\n\n"
                           "3\t1\tsrc/a.py\n-\t-\timg.png\n7\t0\tnew.txt\n"
                           " create mode 100644 new.txt\n delete mode 100644 gone.txt\n")
                   (vigil-codebase--parse-counts))
                 '((:hash "abc" :time 100 :author "T" :subject "Add it"
                    :files ((:file "src/a.py" :added 3 :removed 1 :created nil
                             :deleted nil :hunks nil)
                            (:file "img.png" :added 0 :removed 0 :created nil
                             :deleted nil :hunks nil)
                            (:file "new.txt" :added 7 :removed 0 :created t
                             :deleted nil :hunks nil))))))
  (let ((commit (car (vigil-codebase--parse
                      (concat "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n"
                              "@@ -2 +2,2 @@ def f():\n-    return 1\n+    x = 1\n+    return x\n"
                              "@@ -9,0 +11 @@ def g():\n+--- not a header\n")))))
    (should-not (plist-get commit :hash))
    (should (equal (plist-get (car (plist-get commit :files)) :hunks)
                   '(("def f():" 2 1) ("def g():" 1 0))))
    (should (= (plist-get (car (plist-get commit :files)) :added) 3))))

(ert-deftest vigil-codebase-says-what-kind-of-change ()
  "New, growing, churning: by how often, and how much went out for what went in."
  (should (equal (vigil-codebase--kind 1 100 0 t t) "new"))
  (should (equal (vigil-codebase--kind 5 100 60 t t) "new, reworked"))
  (should (equal (vigil-codebase--kind 5 100 60 nil t) "churning"))
  ;; One rewrite is not churn.
  (should (equal (vigil-codebase--kind 1 100 90 nil t) "changed"))
  (should (equal (vigil-codebase--kind 4 100 10 nil t) "growing"))
  (should (equal (vigil-codebase--kind 2 10 10 nil nil) "gone")))

(ert-deftest vigil-codebase-lists-a-repository ()
  "The files that changed, the most changed first, each with its kind, how
much it changed, the prompts behind it and the commands that exercised it;
over them, what the changes come to.  And a file alone."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (save-window-excursion
      (let ((list (vigil-codebase root)))
        (unwind-protect
            (with-current-buffer list
              (let* ((rows (mapcar (lambda (entry)
                                     (cons (car entry)
                                           (mapcar #'substring-no-properties
                                                   (append (cadr entry) nil))))
                                   (vigil-codebase--entries)))
                     (row (lambda (name) (cdr (assoc name rows)))))
                (should (equal (mapcar #'car rows) '("a.py" "b.el" "d.sh" "c.txt")))
                ;; Made, then changed three times, as much out as in.
                (should (equal (take 5 (funcall row "a.py"))
                               '("a.py" "new, reworked" "4" "+12" "-5")))
                ;; One prompt; ran twice, and changed since: the last commit
                ;; is newer than the last run.
                (should (equal (nth 6 (funcall row "a.py")) "1"))
                (should (equal (nth 7 (funcall row "a.py")) "2"))
                (should (string-match-p "changed since\\'" (nth 8 (funcall row "a.py"))))
                ;; Made an hour ago, and changed but not committed.
                (should (equal (take 5 (funcall row "b.el"))
                               '("b.el" "new" "2" "+2" "-1")))
                ;; Git does not know it yet.
                (should (equal (take 5 (funcall row "d.sh"))
                               '("d.sh" "new" "1" "+2" "-0")))
                (should (string-match-p "failed" (nth 8 (funcall row "d.sh"))))
                (should (equal (nth 7 (funcall row "c.txt")) "")))
              (should (string-match-p
                       "30 days  ·  4 commits  ·  4 files changed, 4 new  ·  \\+17 -6  ·  100%% of what was added is in new files  ·  0\\.35 lines out"
                       header-line-format))
              ;; The commits were kept: another Emacs asks git of none.
              (should (file-exists-p (vigil-codebase--cache-file root)))
              (let ((vigil-codebase--known (make-hash-table :test #'equal)))
                (should (= (hash-table-count (vigil-codebase--commits-known root)) 4)))
              ;; Fewer days: the first commit, an hour old, is still in.
              (vigil-codebase-days 1)
              (should (= (length vigil-codebase--files) 4))
              ;; The file alone.
              (goto-char (point-min))
              (search-forward "a.py")
              (let ((file (vigil-codebase-file)))
                (unwind-protect
                    (with-current-buffer file
                      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                        (should (string-match-p
                                 "\\`a\\.py\nnew, reworked  ·  4 changes in 1 days  ·  \\+12 -5" text))
                        (should (string-match-p
                                 "Changed most often\n +3×  def f():  \\+6 -5\n\nChanges\n" text))
                        (should (string-match-p "Rename it again  \\+2 -2\n" text))
                        (should (string-match-p "Add a and b  \\+6 -0  made\n" text))
                        (should (string-match-p
                                 "Prompts behind its changes\n.*  rename the variable in f please  1 edit\n"
                                 text))
                        (should (string-match-p
                                 "Exercised by\n +2×  python3 a\\.py  named  ·  last .*  ok\n"
                                 text)))
                      ;; RET on the prompt shows it whole.
                      (goto-char (point-min))
                      (search-forward "rename the variable")
                      (push-button (point))
                      (with-current-buffer "*vigil codebase: text*"
                        (should (string-match-p "rename the variable in f\nplease"
                                                (buffer-string)))
                        (kill-buffer)))
                  (kill-buffer file))))
          (kill-buffer list))))))

(provide 'vigil-codebase-tests)
;;; vigil-codebase-tests.el ends here
