;;; vigil-command-tests.el --- A shell command, untangled and explained -*- lexical-binding: t; -*-

;; Laying a command out takes shfmt, and laying its Python out takes ruff;
;; the tests that need them are skipped without them.  The manuals are
;; canned text: nothing here depends on what `man' has on this machine.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-command-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-command)

(defmacro vigil-command-tests--fresh (&rest body)
  "Run BODY with nothing remembered of commands or manuals."
  `(let ((vigil-command--tidied (make-hash-table :test #'equal))
         (vigil-command--manuals (make-hash-table :test #'equal)))
     ,@body))

(defun vigil-command-tests--shell (command)
  "COMMAND laid out, as plain text."
  (substring-no-properties (plist-get (vigil-command-tidy command) :shell)))

(defun vigil-command-tests--blocks (command)
  "The programs taken out of COMMAND, as (LABEL . CODE) in plain text."
  (mapcar (lambda (block) (cons (substring-no-properties (car block))
                                (substring-no-properties (cdr block))))
          (plist-get (vigil-command-tidy command) :blocks)))

(ert-deftest vigil-command-breaks-long-chains-only ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (should (equal (vigil-command-tests--shell "cd x && ls | wc -l") "cd x && ls | wc -l"))
   (should (equal (vigil-command-tests--shell
                   "git log --oneline -20 | grep -v Merge | awk '{print $1}' | xargs -n1 git show --stat | head")
                  (concat "git log --oneline -20 \\\n  | grep -v Merge \\\n"
                          "  | awk '{print $1}' \\\n  | xargs -n1 git show --stat \\\n"
                          "  | head")))
   ;; One statement a line.
   (should (equal (vigil-command-tests--shell "a; b") "a\nb"))))

(ert-deftest vigil-command-takes-out-python ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let ((command "python3 -c \"import os; print(\\\"hi\\\", os.sep)\" 2>&1"))
     (should (equal (vigil-command-tests--shell command) "python3 -c ‹1› 2>&1"))
     (pcase-let ((`((,label . ,code)) (vigil-command-tests--blocks command)))
       (should (equal label "‹1› python3 -c"))
       ;; The shell's quoting is undone: this is what Python was given.
       (should (string-match-p "print(\"hi\", os.sep)" code))
       (when (executable-find "ruff")
         (should (equal code "import os\n\nprint(\"hi\", os.sep)")))))
   ;; Past a wrapper, and the placeholder face where the program was.
   (let ((tidy (vigil-command-tidy "timeout 60 uv run python -c 'x = 1'")))
     (should (equal (substring-no-properties (plist-get tidy :shell))
                    "timeout 60 uv run python -c ‹1›"))
     (should (eq (get-text-property (string-match "‹" (plist-get tidy :shell))
                                    'face (plist-get tidy :shell))
                 'vigil-command-placeholder)))))

(ert-deftest vigil-command-takes-out-osascript-by-language ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let ((command "cd /tmp && timeout 60 osascript -l JavaScript -e 'const N = Application(\"Notes\"); JSON.stringify({n: 1})' 2>&1"))
     (should (equal (vigil-command-tests--shell command)
                    "cd /tmp && timeout 60 osascript -l JavaScript -e ‹1› 2>&1"))
     (pcase-let ((`((,label . ,code)) (vigil-command-tests--blocks command)))
       (should (equal label "‹1› osascript -e"))
       ;; Highlighted as JavaScript.
       (should (eq (get-text-property
                    0 'face (cdar (plist-get (vigil-command-tidy command) :blocks)))
                   'font-lock-keyword-face))
       (when (executable-find "prettier")
         (should (equal (substring-no-properties code)
                        "const N = Application(\"Notes\");\nJSON.stringify({ n: 1 });")))))
   ;; The language named, attached or apart, in any case; else AppleScript.
   (cl-flet ((mode (words)
               (let ((args (mapcar (lambda (word) (cons nil word)) words)))
                 (vigil-command--interpreter-mode (vigil-command--interpreter args) args))))
     (should (eq (mode '("osascript" "-l" "JavaScript" "-e" "1")) 'js-mode))
     (should (eq (mode '("osascript" "-ljavascript" "-e" "1")) 'js-mode))
     (should (eq (mode '("osascript" "-e" "1")) 'applescript-mode))
     (should (eq (mode '("python3" "-c" "1")) 'python-mode)))
   ;; From its standard input.
   (pcase-let ((`((,label . ,_))
                (vigil-command-tests--blocks
                 "osascript -l JavaScript <<'EOF'\nApplication('Notes').name()\nEOF")))
     (should (equal label "‹1› osascript, from its standard input")))))

(ert-deftest vigil-command-heredocs-run-or-written ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let ((command (concat "cat > app.py <<'EOF'\nx=1;y=2\nEOF\n"
                          "python3 - <<'PY'\nimport os;print(os.getcwd())\nPY")))
     (should (equal (vigil-command-tests--shell command)
                    "cat > app.py << 'EOF'\n‹1›\nEOF\npython3 - << 'PY'\n‹2›\nPY"))
     (let ((blocks (vigil-command-tests--blocks command)))
       ;; Written to a file: laid out too, when its formatter is there.
       (should (equal (car (nth 0 blocks)) "‹1› written to app.py"))
       (should (equal (cdr (nth 0 blocks))
                      (if (executable-find "ruff") "x = 1\ny = 2" "x=1;y=2")))
       (should (equal (car (nth 1 blocks)) "‹2› python3, from its standard input"))
       (when (executable-find "ruff")
         (should (equal (cdr (nth 1 blocks)) "import os\n\nprint(os.getcwd())")))))))

(ert-deftest vigil-command-never-runs-what-it-reads ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let* ((dir (make-temp-file "vigil-command" t))
          (marker (expand-file-name "ran" dir))
          (command (format "echo $(touch %s) && python3 -c 'open(%S, \"w\")'"
                           marker marker)))
     (unwind-protect
         (progn
           (should (vigil-command-tidy command))
           (cl-letf (((symbol-function 'vigil-command--manual) #'ignore))
             (should (vigil-command-explain command)))
           (should-not (file-exists-p marker)))
       (delete-directory dir t)))))

(ert-deftest vigil-command-not-shell-is-shown-as-given ()
  (vigil-command-tests--fresh
   (let ((vigil-command-shfmt "vigil-no-such-program"))
     (should-not (vigil-command-tidy "ls | wc")))
   (when (executable-find vigil-command-shfmt)
     (should-not (vigil-command-tidy "if then (( fi")))
   (with-temp-buffer
     (vigil--render (vigil-call--make :name "Bash" :input '((command . "if then (( fi"))
                                      :response '((stdout . ""))))
     (should (string-prefix-p "$ if then (( fi\n" (buffer-string))))))

(ert-deftest vigil-command-on-one-line ()
  "To be listed: one line, read as the shell would read it."
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let ((line (lambda (command) (substring-no-properties (vigil-command-line command)))))
     (should (equal (funcall line "a; b") "a; b"))
     (should (equal (funcall line "git log --oneline -20 | grep -v Merge | awk '{print $1}' | xargs -n1 git show --stat | head")
                    "git log --oneline -20 | grep -v Merge | awk '{print $1}' | xargs -n1 git show --stat | head"))
     (should (equal (funcall line "python3 -c \"import os; print(1)\" 2>&1 | tail")
                    "python3 -c ‹1› 2>&1 | tail"))
     (should (equal (funcall line "cat > app.py <<'EOF'\nx=1\nEOF\npython3 - <<'PY'\nimport os\nPY")
                    "cat > app.py << ‹1›; python3 - << ‹2›"))
     (should (equal (funcall line "if true; then echo a; else echo b; fi")
                    "if true; then echo a; else echo b; fi"))
     ;; A line break inside a string is one.
     (should (equal (funcall line "git commit -m \"one\n\ntwo\"")
                    "git commit -m \"one⏎⏎two\""))
     ;; Highlighted as shell.
     (should (get-text-property 0 'face (vigil-command-line "echo hi | tail"))))))

(defconst vigil-command-tests--man
  "GREP(1)                     General Commands Manual                    GREP(1)

NAME
     grep, egrep, fgrep - file pattern
     searcher

DESCRIPTION
     -c, --count
             Only a count of selected lines is written to standard output.
             This option is ignored if -c, -L, or -n is given.

     -n, --line-number
             Each output line is preceded by its relative line number in the
             file, starting at line 1.  The line number counter is reset.

     --color[=when]
             Mark up the matching text.
"
  "A manual as `man' prints it, its overstrike gone.")

(defconst vigil-command-tests--help
  "cd: cd [-L|[-P [-e]] [-@]] [dir]
    Change the shell working directory.

    Options:
      -L\tforce symbolic links to be followed
      -P\tuse the physical directory structure
"
  "A builtin's help, as bash prints it.")

(ert-deftest vigil-command-reads-manuals ()
  (should (equal (vigil-command--manual-summary vigil-command-tests--man)
                 "file pattern searcher"))
  (should (equal (vigil-command--manual-summary vigil-command-tests--help)
                 "Change the shell working directory."))
  (let ((man vigil-command-tests--man))
    (should (equal (vigil-command--manual-option man "-n")
                   "Each output line is preceded by its relative line number in the file, starting at line 1."))
    (should (equal (vigil-command--manual-option man "--line-number")
                   (vigil-command--manual-option man "-n")))
    ;; Under its own heading, not where another option's text names it.
    (should (string-prefix-p "Only a count" (vigil-command--manual-option man "-c")))
    (should (equal (vigil-command--manual-option man "--color") "Mark up the matching text."))
    (should-not (vigil-command--manual-option man "-z")))
  (should (equal (vigil-command--manual-option vigil-command-tests--help "-P")
                 "use the physical directory structure")))

(ert-deftest vigil-command-explains-programs-and-options ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (cl-letf (((symbol-function 'vigil-command--manual)
              (lambda (name)
                (pcase name
                  ("grep" vigil-command-tests--man)
                  ("cd" vigil-command-tests--help)))))
     (should (equal (vigil-command-explain
                     "cd /tmp && grep -cn x f | grep --color=never -z y | ./run.sh -q -- -n")
                    '(("cd" "Change the shell working directory." nil)
                      ("grep" "file pattern searcher"
                       (("-c" . "Only a count of selected lines is written to standard output.")
                        ("-n" . "Each output line is preceded by its relative line number in the file, starting at line 1.")
                        ("--color=never" . "Mark up the matching text.")
                        ("-z")))
                      ("./run.sh" nil (("-q")))))))))

(ert-deftest vigil-command-gives-man-only-names ()
  (should (vigil-command--name-p "git-log"))
  (should-not (vigil-command--name-p "-rf"))
  (should-not (vigil-command--name-p "./run.sh"))
  (should-not (vigil-command--name-p "/etc/passwd"))
  (should-not (vigil-command--name-p "a b")))

(ert-deftest vigil-command-inspected-and-toggled ()
  (skip-unless (executable-find vigil-command-shfmt))
  (vigil-command-tests--fresh
   (let* ((command "cd /tmp && python3 -c 'print(1)'")
          (call (vigil-call--make :name "Bash" :cwd "/tmp"
                                  :input `((command . ,command))
                                  :response '((stdout . "1\n"))))
          (vigil-explain-commands nil)
          (vigil-commands-as-given nil))
     (with-temp-buffer
       (vigil--render call)
       (should (string-prefix-p "$ cd /tmp && python3 -c ‹1›\n" (buffer-string)))
       (should (string-match-p "^‹1› python3 -c\nprint(1)\n\nOutput\n1\n" (buffer-string)))
       (should (string-match-p "e explain  t as given" mode-line-format))
       (should (eq (key-binding "e") #'vigil-toggle-explain))
       (should (eq (key-binding "t") #'vigil-toggle-as-given)))
     (let ((vigil-commands-as-given t))
       (with-temp-buffer
         (vigil--render call)
         (should (string-prefix-p (concat "$ " command "\n") (buffer-string)))
         (should-not (string-match-p "‹1›" (buffer-string)))))
     ;; The context draws every call at once: there, as given.
     (with-temp-buffer
       (vigil--insert-body call)
       (should (string-prefix-p (concat "$ " command "\n") (buffer-string)))))))

;;; vigil-command-tests.el ends here
