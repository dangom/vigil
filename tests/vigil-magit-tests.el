;;; vigil-magit-tests.el --- What is behind a change, in Magit -*- lexical-binding: t; -*-

;; The repository and the archive of vigil-codebase-fixture.el.  Which
;; prompts are behind a commit needs only git; what Magit is given is tried
;; in Magit, and skipped without it.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-magit-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; With Magit and what it needs on the load path, nothing is skipped.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-magit)
(require 'vigil-codebase-fixture
         (expand-file-name "vigil-codebase-fixture.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

;; Asked once, here: asked inside a test, after another has run, it is not
;; always found.
(defconst vigil-magit-tests--magit (require 'magit nil t)
  "Whether Magit is there to be tried.")

(defun vigil-magit-tests--head (root &optional back)
  "The hash of the commit BACK commits before the head of ROOT's repository."
  (string-trim (vigil-git root "rev-parse" (format "HEAD~%d" (or back 0)))))

(ert-deftest vigil-magit-finds-the-prompts-behind-a-commit ()
  "A commit goes back to the prompt whose edit wrote lines it adds, to the one
whose command seems to have written a file of it, and lists apart what was
only asked while it was made."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let ((said (lambda (revision)
                  (mapcar (lambda (entry)
                            (list (car (split-string (plist-get (car entry) :text) "\n"))
                                  (nth 1 entry) (nth 2 entry) (nth 3 entry)))
                          (vigil-magit-commit-prompts root revision)))))
      ;; The last commit made `z = 1; return z': the edit wrote `return z'
      ;; (`z = 1' says too little to tell by).  The second prompt was asked
      ;; while it was made -- the commits here are all of one moment -- and
      ;; wrote nothing in it.
      (should (equal (funcall said (vigil-magit-tests--head root))
                     '(("rename the variable in f" wrote 1 ("a.py")))))
      ;; The one before it made c.txt, which a command of the second prompt
      ;; redirects to, since the commit before that; the first prompt was
      ;; asked in that time too, and nothing of it is known to be in it.
      (should (equal (funcall said (vigil-magit-tests--head root 1))
                     '(("now b" command 0 ("c.txt"))
                       ("rename the variable in f" meanwhile 0 nil))))
      ;; The one before that was made before anything was asked.
      (should-not (funcall said (vigil-magit-tests--head root 2)))
      ;; As text.
      (with-temp-buffer
        (vigil-magit--insert-prompts
         (vigil-magit-commit-prompts root (vigil-magit-tests--head root)))
        (should (string-match-p
                 "\\`  [-0-9: ]+  rename the variable in f please  1 line in a\\.py\n\\'"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest vigil-magit-says-what-is-known-of-a-file ()
  "A file's change in a few words, from the repository's log and the archive."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((vigil-codebase--stats (make-hash-table :test #'equal))
           (stats (vigil-codebase-stats root)))
      (should (equal (substring-no-properties (vigil-codebase-badge (gethash "a.py" stats)))
                     (format "new, reworked · 4 changes · 1 prompt · ran %s ok, changed since"
                             (vigil-codebase--when
                              (plist-get (plist-get (gethash "a.py" stats) :last-run) :time)))))
      ;; Only what is committed: b.el's change in the working tree is not.
      (should (= (plist-get (gethash "b.el" stats) :changes) 1))
      (should-not (gethash "d.sh" stats))
      (should-not (vigil-codebase-badge nil))
      ;; Asked again at once: not worked out again.
      (should (eq (vigil-codebase-stats root) stats)))))

(ert-deftest vigil-magit-in-magit ()
  "In Magit: the commit's buffer has the prompts behind it, before the diff;
each file is said what change it has seen; a hunk is the call that wrote it;
and with the mode off, Magit's buffers are as they were."
  (skip-unless (and (executable-find "git") vigil-magit-tests--magit))
  (vigil-codebase-tests--with-repository
    (let ((vigil-codebase--stats (make-hash-table :test #'equal))
          (magit-display-buffer-function #'display-buffer)
          (default-directory root))
      (unwind-protect
          (save-window-excursion
            (vigil-magit-mode 1)
            (should (memq #'vigil-magit-insert-prompts magit-revision-sections-hook))
            (magit-show-commit (vigil-magit-tests--head root))
            (with-current-buffer (magit-get-mode-buffer 'magit-revision-mode)
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p
                         "Rename it again\n\\(?:.*\n\\)*Prompts behind this commit\n  [-0-9: ]+  rename the variable in f please  1 line in a\\.py\n\\(?:.*\n\\)*modified +a\\.py"
                         text)))
              ;; Beside the file.
              (let ((badges (cl-remove-if-not
                             (lambda (overlay) (overlay-get overlay 'vigil-magit))
                             (overlays-in (point-min) (point-max)))))
                (should (= (length badges) 1))
                (should (string-match-p
                         "new, reworked · 4 changes · 1 prompt · ran"
                         (substring-no-properties
                          (overlay-get (car badges) 'after-string)))))
              ;; The hunk: the edit e1 of the session proj.1.
              (goto-char (point-min))
              (re-search-forward "^\\+    return z")
              (should (equal (take 2 (vigil-magit-target-call))
                             '(vigil-call "proj.1/e1")))
              (save-window-excursion
                (with-current-buffer (vigil-magit-why)
                  (should (string-match-p
                           "\\`The prompts behind this change of a\\.py\n\n  [-0-9: ]+  rename the variable in f please  1 line\n"
                           (buffer-substring-no-properties (point-min) (point-max))))
                  (kill-buffer)))
              ;; Off: nothing of it is left, here or in what is drawn next.
              (vigil-magit-mode -1)
              (should-not (cl-some (lambda (overlay) (overlay-get overlay 'vigil-magit))
                                   (overlays-in (point-min) (point-max))))
              (magit-refresh-buffer)
              (should-not (string-match-p "Prompts behind"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max))))))
        (vigil-magit-mode -1)
        (dolist (buffer (buffer-list))
          (when (with-current-buffer buffer (derived-mode-p 'magit-mode))
            (kill-buffer buffer)))))))

(provide 'vigil-magit-tests)
;;; vigil-magit-tests.el ends here
