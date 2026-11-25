;;; vigil-purpose-tests.el --- What a command was for -*- lexical-binding: t; -*-

;; Commands as text: nothing here is run but shfmt and Python, each given a
;; command or a program to parse.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-purpose-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-purpose)

(defun vigil-purpose-tests--tags (command &optional changed result)
  "The tags of COMMAND, alone, without why."
  (mapcar #'car (vigil-purpose-tags command changed result t)))

(ert-deftest vigil-purpose-reads-a-command-as-the-shell-does ()
  "What is quoted, and what is in a heredoc, are not the command's own words."
  (should (equal (vigil-purpose--bare "git commit -m 'run pytest' && echo \"a \\\" b\"")
                 "git commit -m \"\" && echo \"\""))
  ;; A quote inside a heredoc opens nothing, and what follows it is read.
  (should (equal (vigil-purpose--bare "cat > f <<'EOF'\nit's \"here\nEOF\ngit tag v1")
                 "cat > f  \ngit tag v1"))
  ;; A heredoc inside a quoted string is not one.
  (should (equal (vigil-purpose--bare "emacs --eval \"x <<EOF\ny\nEOF\" | tail")
                 "emacs --eval \"\" | tail"))
  ;; A string given at once is no heredoc.
  (should (equal (vigil-purpose--bare "cat <<< 'pytest'; bats tests")
                 "cat   \"\"; bats tests")))

(ert-deftest vigil-purpose-says-what-a-command-was-for ()
  "By the programs it runs and what it asks of them."
  (should (equal (vigil-purpose-tests--tags "cd src && pytest -x tests/") '(test)))
  (should (equal (vigil-purpose-tests--tags
                  "emacs -Q --batch -l t.el -f ert-run-tests-batch-and-exit 2>&1 | tail")
                 '(test)))
  (should (equal (vigil-purpose-tests--tags "python3 -m unittest discover") '(test)))
  (should (equal (vigil-purpose-tests--tags "cargo test && cargo clippy") '(test check)))
  (should (equal (vigil-purpose-tests--tags "ruff check . && make") '(check)))
  (should (equal (vigil-purpose-tests--tags "git add -A && git commit -qm x && git tag v1")
                 '(git)))
  (should (equal (vigil-purpose-tests--tags "pip install requests") '(setup)))
  ;; Several at once, in a fixed order.
  (should (equal (vigil-purpose-tests--tags "git commit -m x; bats tests; npm ci")
                 '(test git setup)))
  ;; What it is told to say runs nothing; and looking is none of these.
  ;; A program has to be where a program is: under a path, after what
  ;; runs it; not an argument.
  (should (equal (vigil-purpose-tests--tags
                  "git log | grep pytest; echo bats; cat ruff.toml")
                 '(look)))
  (should (equal (vigil-purpose-tests--tags "CI=1 uv run pytest -q") '(test)))
  (should (equal (vigil-purpose-tests--tags "cd x && ./node_modules/.bin/jest") '(test)))
  (should (equal (vigil-purpose-tests--tags "time bats tests | tail -3") '(test)))
  (should (equal (vigil-purpose-tests--tags "git commit -m 'run pytest and pip install'")
                 '(git)))
  ;; None of these: it only looked, it wrote by its words, or it ran
  ;; something no rule knows.  It is never nothing, of a command.
  (should (equal (vigil-purpose-tests--tags "git log --oneline | head; git status")
                 '(look)))
  (should (equal (vigil-purpose-tests--tags "ls -la") '(look)))
  (should (equal (vigil-purpose-tests--tags "cp a b && ./serve") '(write)))
  (should (equal (vigil-purpose-tests--tags "./serve --port 8000") '(run)))
  (should (equal (vigil-purpose-tests--tags "pytest > out.txt") '(write test)))
  (should-not (vigil-purpose-tests--tags nil))
  ;; Why: what matched, and for tests how they went.
  (should (equal (vigil-purpose-tags "bats tests && git push" nil "ok 65 x\n66 tests, 0 failures" t)
                 '((test . "bats: 66 tests, 0 failures") (git . "git push")))))

(ert-deftest vigil-purpose-says-what-was-written-by-the-files ()
  "Code, tests and documentation, by the names of the files that differed."
  (should (equal (vigil-purpose-tags "python3 gen.py"
                                     '("src/a.py" "tests/test_a.py" "README.md" "lib/b.el"
                                       "lib/b-tests.el" "docs/x.html" "c.js" "d.js")
                                     nil t)
                 '((code . "src/a.py, lib/b.el, c.js, and 1 more")
                   (tests . "tests/test_a.py, lib/b-tests.el")
                   (docs . "README.md, docs/x.html")))))

(ert-deftest vigil-purpose-reads-a-python-program ()
  "What it imports, writes, reads and runs, off its syntax tree."
  (skip-unless (executable-find vigil-purpose-python))
  (let ((scan (vigil-purpose-python
               (concat "import re, subprocess, requests\n"
                       "from pathlib import Path\n"
                       "p = 'src/a.el'\n"
                       "s = open(p).read()\n"
                       "assert s.count('x') == 1\n"
                       "open(p, 'w').write(s)\n"
                       "Path('out.txt').write_text(s)\n"
                       "open(name + '.log', mode='a')\n"
                       "subprocess.run(['bats', 'tests'])\n"
                       "def f(): pass\n"))))
    (should (equal (plist-get scan :standard) '("pathlib" "re" "subprocess")))
    (should (equal (plist-get scan :others) '("requests")))
    ;; A name given a string is that string; one worked out is said to be.
    (should (equal (sort (copy-sequence (plist-get scan :writes)) #'string<)
                   '("<worked out>" "out.txt" "src/a.el")))
    (should (equal (plist-get scan :reads) '("src/a.el")))
    (should (equal (plist-get scan :runs) '("bats tests")))
    (should (= (plist-get scan :asserts) 1))
    (should (= (plist-get scan :defines) 1)))
  ;; One that does not parse says so, and nothing of it was run.
  (let ((scan (vigil-purpose-python "open('/tmp/vigil-purpose-never', 'w')\nif x:\n")))
    (should (plist-get scan :error))
    (should-not (file-exists-p "/tmp/vigil-purpose-never")))
  (vigil-purpose-python "open('/tmp/vigil-purpose-never', 'w').write('x')")
  (should-not (file-exists-p "/tmp/vigil-purpose-never")))

(ert-deftest vigil-purpose-looks-into-the-python-a-command-runs ()
  "A command is what the Python inside it runs, and a test where that asserts."
  (skip-unless (and (executable-find vigil-purpose-python)
                    (executable-find vigil-command-shfmt)))
  (let ((command "python3 - <<'EOF'\nimport subprocess\nsubprocess.run(['pytest', '-x'])\nEOF"))
    (should (equal (mapcar #'car (vigil-purpose-scripts command))
                   '("python3, from its standard input")))
    (should (equal (mapcar #'car (vigil-purpose-tags command)) '(test)))
    ;; Not looked into, it is not known: it ran something.
    (should (equal (mapcar #'car (vigil-purpose-tags command nil nil t)) '(run))))
  (should (equal (vigil-purpose-tags "python3 -c 'assert 1 + 1 == 2'")
                 '((test . "1 assertion in the Python it runs"))))
  ;; What it writes, where nothing else says which files differed.
  (should (equal (vigil-purpose-tags
                  "python3 -c 'open(\"tests/test_a.py\", \"w\"); open(\"README.md\", \"a\")'")
                 '((tests . "tests/test_a.py, by the Python inside it")
                   (docs . "README.md, by the Python inside it"))))
  (should (equal (vigil-purpose-tags "python3 -c 'open(name, \"w\")'" '("src/x.py"))
                 '((code . "src/x.py"))))
  (should (equal (mapcar #'car (vigil-purpose-tags "python3 -c 'open(a + b, \"w\")'"))
                 '(write))))

(ert-deftest vigil-purpose-names-the-programs ()
  "The programs a command runs, and where each is: not the shell's words."
  (let* ((directory (file-name-as-directory (make-temp-file "vigil-purpose" t)))
         (script (expand-file-name "bin/tool" directory)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory script) t)
          (with-temp-file script (insert "#!/bin/sh\n"))
          (let ((programs (vigil-purpose-programs
                           "cd x && bin/tool --go | head -3; echo 'cat nothing'" directory)))
            (should (equal (car programs) (cons "bin/tool" script)))
            (should (assoc "head" programs))
            (should-not (assoc "cd" programs))
            (should-not (assoc "echo" programs))
            (should-not (assoc "tool" programs))
            (should-not (assoc "cat" programs))))
      (delete-directory directory t))))

(provide 'vigil-purpose-tests)
;;; vigil-purpose-tests.el ends here
