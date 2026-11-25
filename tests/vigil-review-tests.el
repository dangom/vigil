;;; vigil-review-tests.el --- What a session built -*- lexical-binding: t; -*-

;; The repository of vigil-codebase-fixture.el, and snapshots of it taken by
;; bin/vigil as its hook takes them.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-review-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-review)
(require 'vigil-codebase-fixture
         (expand-file-name "vigil-codebase-fixture.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defconst vigil-review-tests--program
  (expand-file-name "../bin/vigil"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The vigil of this checkout.")

(defun vigil-review-tests--hook (root event session prompt &optional host)
  "Hand vigil's snapshot hook EVENT of SESSION and PROMPT, in ROOT, as HOST."
  (let ((process-environment
         (append (list (concat "VIGIL_SESSION=" (or host "proj.1"))
                       "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                 process-environment)))
    (with-temp-buffer
      (insert (json-serialize `((hook_event_name . ,event) (session_id . ,session)
                                (prompt_id . ,prompt) (cwd . ,root))))
      (should (eq 0 (call-process-region (point-min) (point-max)
                                         vigil-review-tests--program
                                         t t nil "snapshot"))))))

(defconst vigil-review-tests--python
  (concat "import os\n\n\n"
          "def f():\n    a = 1\n    b = 2\n    c = 3\n    return a + b + c\n\n\n"
          "def g():\n    d = 4\n    e = 5\n    f = 6\n    return d + e + f\n\n\n"
          "def h():\n    return 0\n")
  "A file of three definitions: two long enough to fold, and one not.")

(defmacro vigil-review-tests--with-session (&rest body)
  "Run BODY in the fixture's repository after a session's work.
mod.py is there before it begins.  An earlier agent of the same name is
given a prompt and stops.  Then the session: its prompt p1; g of mod.py is
changed and lib.el is made; another session is given a prompt; it stops;
its prompt p2; c.txt is taken away, and its agent has not stopped."
  (declare (indent 0))
  `(vigil-codebase-tests--with-repository
     (let ((vigil-snapshot-program vigil-review-tests--program)
           (vigil-snapshot-use-magit nil))
       (vigil-codebase-tests--write root "mod.py" vigil-review-tests--python)
       (vigil-review-tests--hook root "UserPromptSubmit" "s0" "p0")
       (vigil-review-tests--hook root "Stop" "s0" "p0")
       (vigil-review-tests--hook root "UserPromptSubmit" "s1" "p1")
       (vigil-codebase-tests--write
        root "mod.py"
        (string-replace "    e = 5\n" "    e = 50\n    extra = 1\n"
                        vigil-review-tests--python))
       (vigil-codebase-tests--write
        root "src/lib.el"
        (concat ";;; lib.el --- made  -*- lexical-binding: t; -*-\n\n"
                "(defun lib-one ()\n  \"One.\"\n  (list 1\n        2\n        3))\n\n"
                "(defun lib-two ()\n  \"Two.\"\n  (list 4\n        5\n        6))\n"))
       (vigil-review-tests--hook root "UserPromptSubmit" "s9" "q1" "other.1")
       (vigil-review-tests--hook root "Stop" "s1" "p1")
       (vigil-review-tests--hook root "UserPromptSubmit" "s1" "p2")
       (delete-file (expand-file-name "c.txt" root))
       ,@body)))

(defun vigil-review-tests--session (root host)
  "The newest beginning of HOST's in ROOT."
  (cl-find host (vigil-review-sessions root)
           :key (lambda (session) (plist-get session :host)) :test #'equal))

(ert-deftest vigil-review-finds-a-session-and-where-it-begins ()
  "An agent started again under the same name begins anew; the review runs
from the latest beginning to now, the agent not having stopped."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (let* ((sessions (vigil-review-sessions root))
           (session (vigil-review-tests--session root "proj.1"))
           (span (vigil-review-span root (plist-get session :from))))
      (should (equal (mapcar (lambda (s) (plist-get s :session)) sessions)
                     '("s9" "s1" "s0")))
      (should (equal (plist-get session :session) "s1"))
      (should (= (plist-get session :prompts) 2))
      (should (equal (plist-get (plist-get span :from) :prompt) "p1"))
      (should (eq (plist-get span :end) 'now))
      (should (equal (mapcar (lambda (s) (plist-get s :prompt)) (plist-get span :prompts))
                     '("p1" "p2")))
      ;; Two moments: what p1 left, and c.txt gone.  Another session's
      ;; snapshot in between is not one of them.
      (should (= (length (plist-get span :frames)) 2))
      (should (eq (car (last (plist-get span :frames))) (plist-get span :to))))))

(ert-deftest vigil-review-ends-where-the-agent-stopped ()
  "A session whose agent stopped ends there, whatever changed since."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (vigil-review-tests--hook root "Stop" "s1" "p2")
    (vigil-codebase-tests--write root "later.txt" "by hand\n")
    (let* ((session (vigil-review-tests--session root "proj.1"))
           (span (vigil-review-span root (plist-get session :from)))
           (changes (vigil-review-changes root (plist-get (plist-get span :from) :commit)
                                          (plist-get (plist-get span :to) :commit))))
      (should (eq (plist-get span :end) 'stopped))
      (should-not (cl-find "later.txt" changes
                           :key (lambda (c) (plist-get c :file)) :test #'equal)))))

(ert-deftest vigil-review-says-what-changed ()
  "The files new, changed and gone, with the lines put in and taken out."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (let* ((span (vigil-review-span
                  root (plist-get (vigil-review-tests--session root "proj.1") :from)))
           (changes (vigil-review-changes root (plist-get (plist-get span :from) :commit)
                                          (plist-get (plist-get span :to) :commit))))
      (should (equal (mapcar (lambda (c)
                               (list (plist-get c :file) (plist-get c :status)
                                     (plist-get c :added) (plist-get c :removed)))
                             changes)
                     '(("c.txt" "D" 0 1) ("mod.py" "M" 2 1) ("src/lib.el" "A" 13 0))))
      (should (equal (vigil-review--totals changes) '(1 1 1 15 2)))
      (should (equal (vigil-review--hunks root (plist-get (plist-get span :from) :commit)
                                          (plist-get (plist-get span :to) :commit)
                                          "mod.py")
                     '((13 2 1)))))))

(ert-deftest vigil-review-folds-what-was-not-touched ()
  "A changed file is laid out with the lines put in marked and the
definitions not touched folded; a new one with every definition folded."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (let* ((span (vigil-review-span
                  root (plist-get (vigil-review-tests--session root "proj.1") :from)))
           (a (plist-get (plist-get span :from) :commit))
           (b (plist-get (plist-get span :to) :commit))
           (changes (vigil-review-changes root a b))
           (layout (lambda (name)
                     (vigil-review--layout
                      root a b (cl-find name changes
                                        :key (lambda (c) (plist-get c :file))
                                        :test #'equal))))
           (hidden (lambda (layout)
                     (mapcar (lambda (fold)
                               (substring (plist-get layout :text)
                                          (1- (car fold)) (1- (cadr fold))))
                             (plist-get layout :folds)))))
      (let ((mod (funcall layout "mod.py")))
        ;; The two lines put in g, and nothing else.
        (should (equal (mapcar (lambda (place)
                                 (substring-no-properties (plist-get mod :text)
                                                          (1- (car place)) (1- (cdr place))))
                               (plist-get mod :added))
                       '("    e = 50\n    extra = 1\n")))
        ;; f is folded under its first line; g, which changed, and h, which
        ;; is short, are not.
        (should (= (length (plist-get mod :folds)) 1))
        (should (string-match-p "\\`\n    a = 1\n.*\n.*\n    return a \\+ b \\+ c\\'"
                                (car (funcall hidden mod))))
        (should (= (nth 2 (car (plist-get mod :folds))) 4)))
      (let ((lib (funcall layout "src/lib.el")))
        (should-not (plist-get lib :added))
        (should (= (length (plist-get lib :folds)) 2))
        (should (string-prefix-p "\n  \"One.\"" (car (funcall hidden lib)))))
      (should (equal (plist-get (funcall layout "c.txt") :note) "gone")))))

(ert-deftest vigil-review-folds-far-from-changes-where-there-are-no-definitions ()
  "In a file of no definitions, what is far from a change is folded."
  (let ((vigil-review-context 2) (vigil-review-fold-lines 3))
    (with-temp-buffer
      (dotimes (n 30) (insert (format "line %d\n" (1+ n))))
      ;; Lines 10 and 11 changed: 1 stays, 2-7 fold, 8-13 show, 14-30 fold.
      (let ((folds (vigil-review--runs '((10 . 11)) 30)))
        (should (equal (mapcar (lambda (fold) (nth 2 fold)) folds) '(6 17)))
        (should (equal (buffer-substring (car (car folds)) (cadr (car folds)))
                       "\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7"))))))

(ert-deftest vigil-review-shows-the-session-in-short-and-through-time ()
  "The overview names the prompts and the files, and steps through moments."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (let ((default-directory root) buffer)
      (unwind-protect
          (progn
            (setq buffer (save-window-excursion (vigil-review)))
            ;; Not in an agent's buffer: the session last at work, which is
            ;; another's.  Ask for ours.
            (with-current-buffer buffer
              (should (string-match-p "other\\.1" (buffer-name))))
            (kill-buffer buffer)
            (setq buffer
                  (save-window-excursion
                    (vigil-review--open root (vigil-review-tests--session root "proj.1"))))
            (with-current-buffer buffer
              (let ((text (buffer-string)))
                (should (string-match-p "^proj\\.1" text))
                (should (string-match-p "2 prompts" text))
                (should (string-match-p "1 new, 1 changed, 1 gone   \\+15 −2" text))
                (should (string-match-p "^   1  .*2 files  \\+15 −1$" text))
                (should (string-match-p "^   2  .*1 file  \\+0 −1$" text))
                (should (string-match-p "^  - c\\.txt" text))
                (should (string-match-p "^  ~ mod\\.py +\\+2 −1$" text))
                (should (string-match-p "^  src/\n    \\+ lib\\.el +\\+13$" text)))
              ;; Its first moment: what p1 left, c.txt still there.
              (vigil-review-forward)
              (let ((text (buffer-string)))
                (should (string-match-p "moment 1 of 2" text))
                (should (string-match-p "^▸  1 " text))
                (should-not (string-match-p "c\\.txt" text))
                (should (string-match-p "mod\\.py.*●" text)))
              (vigil-review-forward)
              (let ((text (buffer-string)))
                (should (string-match-p "moment 2 of 2" text))
                (should (string-match-p "^▸  2 " text))
                (should (string-match-p "c\\.txt.*●" text))
                (should-not (string-match-p "mod\\.py.*●" text)))
              (vigil-review-forward)
              (should-not vigil-review--frame)
              ;; A prompt's line goes to what that prompt left.
              (goto-char (point-min))
              (re-search-forward "^   1 ")
              (vigil-review-act)
              (should (eql vigil-review--frame 0))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest vigil-review-lays-the-files-out-to-read ()
  "The reading buffer has each file under its name, new ones first, with
folds that open and close, and goes to the line of the file itself."
  (skip-unless (executable-find "git"))
  (vigil-review-tests--with-session
    (let* ((span (vigil-review-span
                  root (plist-get (vigil-review-tests--session root "proj.1") :from)))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (vigil-review-read root
                                            (plist-get (plist-get span :from) :commit)
                                            (plist-get (plist-get span :to) :commit)
                                            "proj.1" "mod.py"))
            (with-current-buffer buffer
              (should (looking-at-p "~ mod\\.py   changed  \\+2 −1"))
              (should (equal (mapcar (lambda (file) (plist-get file :file))
                                     (reverse vigil-review--files))
                             '("src/lib.el" "mod.py" "c.txt")))
              (should (string-match-p "^- c\\.txt   −1  gone$" (buffer-string)))
              ;; f is folded; unfolding and folding it again.
              (re-search-forward "^def f")
              (let ((fold (vigil-review--fold-here)))
                (should (vigil-review--folded-p fold))
                (should (string-match-p "4 lines"
                                        (overlay-get (overlay-get fold 'vigil-review-tag)
                                                     'display)))
                (vigil-review-toggle)
                (should-not (vigil-review--folded-p fold))
                (vigil-review-toggle)
                (should (vigil-review--folded-p fold)))
              ;; The change is found, and is at the file's own line 13.
              (goto-char (point-min))
              (vigil-review-next-change)
              (should (looking-at-p "    e = 50"))
              (should (eq (get-char-property (point) 'face) 'vigil-review-added))
              (vigil-review-visit)
              (should (equal (file-name-nondirectory buffer-file-name) "mod.py"))
              (should (= (line-number-at-pos) 13))
              (kill-buffer))
            (with-current-buffer buffer
              ;; Under its heading, a file folds whole.
              (goto-char (point-min))
              (vigil-review-next-file)
              (should (looking-at-p "\\+ src/lib\\.el   new  \\+13"))
              (vigil-review-toggle)
              (should (eq (overlay-get (vigil-review--fold-here) 'vigil-review-fold) 'file))
              (should (vigil-review--folded-p (vigil-review--fold-here)))
              (vigil-review-toggle-all)
              (should-not (cl-some #'vigil-review--folded-p
                                   (seq-remove
                                    (lambda (fold)
                                      (eq (overlay-get fold 'vigil-review-fold) 'file))
                                    (vigil-review--folds))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'vigil-review-tests)
;;; vigil-review-tests.el ends here
