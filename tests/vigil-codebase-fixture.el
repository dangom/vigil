;;; vigil-codebase-fixture.el --- A repository and an archive to test with -*- lexical-binding: t; -*-

;; For vigil-codebase-tests.el and vigil-magit-tests.el: a repository made
;; with git, and an archive of a session that worked in it, written the way
;; `vigil hook' writes one.  Nothing of this machine's is read, and what is
;; kept to read faster is kept in the test's own directories.

;;; Code:

(require 'cl-lib)
(require 'vigil-history)
(require 'vigil-codebase)

(defun vigil-codebase-tests--git (root &rest args)
  "Run git with ARGS in ROOT, as someone and at no time in particular."
  (let ((default-directory root)
        (process-environment
         (append '("GIT_AUTHOR_NAME=T" "GIT_AUTHOR_EMAIL=t@example.org"
                   "GIT_COMMITTER_NAME=T" "GIT_COMMITTER_EMAIL=t@example.org"
                   "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                 process-environment)))
    (unless (eq 0 (apply #'call-process "git" nil nil nil args))
      (error "git %S failed" args))))

(defun vigil-codebase-tests--write (root name text)
  "Make the file NAME of ROOT say TEXT."
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun vigil-codebase-tests--event (time event)
  "A line of the archive: EVENT, an alist, reported at TIME."
  (concat (json-serialize `((t . ,time) (host . "proj.1") (hosted . t)
                            (event . ,(append '((session_id . "s1")) event))))
          "\n"))

(defmacro vigil-codebase-tests--with-repository (&rest body)
  "Run BODY with `root', a repository with a history, and an archive of it.
Four commits, an hour old, half an hour old and two just made: a.py made
and then changed three times in its function f; b.el and c.txt made.  The
session's ten minutes of work come before the last two.  Not
committed: b.el changed, d.sh made.  The archive has one session in it:
two prompts, an edit of a.py, and commands."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "vigil-repo" t))))
          (archive (file-name-as-directory (make-temp-file "vigil-archive" t)))
          (cache (file-name-as-directory (make-temp-file "vigil-cache" t)))
          (vigil-history-archive-directory archive)
          (vigil-history-coverage-directory (expand-file-name "coverage" cache))
          (vigil-history-cache-directory (expand-file-name "history" cache))
          (vigil-codebase-cache-directory (expand-file-name "codebase" cache))
          (vigil-history--files (make-hash-table :test #'equal))
          (vigil-history--known (make-hash-table :test #'equal))
          (vigil-codebase--known (make-hash-table :test #'equal))
          (now (float-time)))
     (unwind-protect
         (progn
           (vigil-codebase-tests--git root "init" "-q" "-b" "main")
           (vigil-codebase-tests--write root "a.py" "def f():\n    return 1\n\n\ndef g():\n    return 2\n")
           (vigil-codebase-tests--write root "b.el" "(defun b () 1)\n")
           (vigil-codebase-tests--git root "add" "-A")
           (vigil-codebase-tests--git root "commit" "-q" "-m" "Add a and b"
                                      (format "--date=%d +0000" (- (truncate now) 3600)))
           (vigil-codebase-tests--write root "a.py" "def f():\n    x = 1\n    return x\n\n\ndef g():\n    return 2\n")
           (vigil-codebase-tests--git root "commit" "-q" "-am" "Name the one"
                                      (format "--date=%d +0000" (- (truncate now) 1800)))
           (vigil-codebase-tests--write root "a.py" "def f():\n    y = 1\n    return y\n\n\ndef g():\n    return 2\n")
           (vigil-codebase-tests--write root "c.txt" "notes\n")
           (vigil-codebase-tests--git root "add" "-A")
           (vigil-codebase-tests--git root "commit" "-q" "-m" "Rename it, and notes")
           (vigil-codebase-tests--write root "a.py" "def f():\n    z = 1\n    return z\n\n\ndef g():\n    return 2\n")
           (vigil-codebase-tests--git root "commit" "-q" "-am" "Rename it again")
           (vigil-codebase-tests--write root "b.el" "(defun b () 2)\n")
           (vigil-codebase-tests--write root "d.sh" "#!/bin/sh\necho d\n")
           ;; The archive.
           (make-directory (expand-file-name "2026/11" archive) t)
           (with-temp-file (expand-file-name "index.jsonl" archive)
             (insert (json-serialize `((session_id . "s1") (host . "proj.1")
                                       (file . "2026/11/s1.jsonl") (cwd . ,root)))
                     "\n"
                     ;; A session of somewhere else is not this repository's.
                     (json-serialize '((session_id . "s2") (file . "2026/11/s2.jsonl")
                                       (cwd . "/elsewhere")))
                     "\n"))
           (let ((t0 (- (truncate now) 600))
                 (call (lambda (event tool id input &optional response prompt)
                         `((hook_event_name . ,event) (tool_name . ,tool)
                           (tool_use_id . ,id) (cwd . ,root)
                           (prompt_id . ,(or prompt "p1")) (tool_input . ,input)
                           ,@(and response `((tool_response . ,response)))))))
             (with-temp-file (expand-file-name "2026/11/s1.jsonl" archive)
               (insert
                (vigil-codebase-tests--event
                 t0 '((hook_event_name . "UserPromptSubmit") (prompt_id . "p1")
                      (prompt . "rename the variable in f\nplease")))
                (vigil-codebase-tests--event
                 (+ t0 10)
                 (funcall call "PostToolUse" "Edit" "e1"
                          `((file_path . ,(concat root "a.py"))
                            (old_string . "    y = 1") (new_string . "    z = 1"))
                          '((structuredPatch
                             . [((oldStart . 2) (oldLines . 2) (newStart . 2) (newLines . 2)
                                 (lines . ["-    y = 1" "-    return y"
                                           "+    z = 1" "+    return z"]))]))))
                ;; A command that ran the file, and whose output names a line of it.
                (vigil-codebase-tests--event
                 (+ t0 20) (funcall call "PreToolUse" "Bash" "c1" '((command . "python3 a.py"))))
                (vigil-codebase-tests--event
                 (+ t0 21) (funcall call "PostToolUse" "Bash" "c1" '((command . "python3 a.py"))
                                    '((stdout . "ok") (stderr . ""))))
                (vigil-codebase-tests--event
                 (+ t0 30) (funcall call "PostToolUse" "Bash" "c2"
                                    '((command . "python3 a.py"))
                                    '((stdout . "  File \"a.py\", line 2, in f") (stderr . ""))))
                ;; One that only read it: nothing ran.
                (vigil-codebase-tests--event
                 (+ t0 40) (funcall call "PostToolUse" "Bash" "c3"
                                    '((command . "grep -n \"z\\|y\" a.py; cat b.el"))
                                    '((stdout . "a.py:2:    z = 1") (stderr . ""))))
                (vigil-codebase-tests--event
                 (+ t0 50) '((hook_event_name . "UserPromptSubmit") (prompt_id . "p2")
                             (prompt . "now b")))
                ;; A file changed by a command, not an edit.
                (vigil-codebase-tests--event
                 (+ t0 60) (funcall call "PostToolUse" "Bash" "c4"
                                    '((command . "python3 - <<'EOF'\nopen('b.el','w').write('(defun b () 2)')\nEOF\necho done > c.txt"))
                                    '((stdout . "") (stderr . "")) "p2"))
                ;; One that began and was never answered: it failed.
                (vigil-codebase-tests--event
                 (+ t0 70) (funcall call "PreToolUse" "Bash" "c5"
                                    '((command . "sh ./d.sh --fast")) nil "p2"))
                ;; What is of no use here is passed over.
                (vigil-codebase-tests--event
                 (+ t0 80) (funcall call "PostToolUse" "Read" "r1"
                                    `((file_path . ,(concat root "a.py")))
                                    '((file (content . "def f"))) "p2")))))
           ,@body)
       (delete-directory root t)
       (delete-directory archive t)
       (delete-directory cache t))))

(provide 'vigil-codebase-fixture)
;;; vigil-codebase-fixture.el ends here
