;;; vigil-snapshot-tests.el --- What changed after a prompt -*- lexical-binding: t; -*-

;; The repository and the archive of vigil-codebase-fixture.el, and
;; snapshots of it taken by bin/vigil as its hook takes them.
;;
;;   emacs -Q --batch -L emacs -l tests/vigil-snapshot-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; With Magit and what it needs on the load path, nothing is skipped.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil-snapshot)
(require 'vigil-codebase-fixture
         (expand-file-name "vigil-codebase-fixture.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defconst vigil-snapshot-tests--program
  (expand-file-name "../bin/vigil"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The vigil of this checkout.")

(defconst vigil-snapshot-tests--magit (require 'magit nil t)
  "Whether Magit is there to be tried.")

(defun vigil-snapshot-tests--hook (root event session prompt &optional host agent)
  "Hand vigil's snapshot hook EVENT of SESSION and PROMPT, in ROOT, as HOST.
Reported by AGENT, where one is named: Claude Code names none."
  (let ((process-environment
         (append (list (concat "VIGIL_SESSION=" (or host "proj.1"))
                       "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                 process-environment)))
    (with-temp-buffer
      (insert (json-serialize `((hook_event_name . ,event) (session_id . ,session)
                                (prompt_id . ,prompt) (cwd . ,root)
                                ,@(and agent `((agent . ,agent)))
                                (prompt . "said \"cwd\":\"/elsewhere\""))))
      (should (eq 0 (call-process-region (point-min) (point-max)
                                         vigil-snapshot-tests--program
                                         t t nil "snapshot")))
      ;; What a prompt's hook prints is given to the agent: nothing.
      (should (equal (buffer-string) "")))))

(defun vigil-snapshot-tests--status (root)
  "What git says of ROOT's working tree and index."
  (vigil-git root "status" "--porcelain"))

(defmacro vigil-snapshot-tests--with-turns (&rest body)
  "Run BODY in the fixture's repository after two prompts' worth of work.
The prompt p1 is given; a.py is changed; another session is given a prompt;
new.txt is made; p1's agent stops; c.txt is changed, by nobody's agent; the
prompt p2 is given; b.el is changed, and its agent has not stopped."
  (declare (indent 0))
  `(vigil-codebase-tests--with-repository
     (let ((vigil-snapshot-program vigil-snapshot-tests--program)
           (vigil-snapshot-use-magit nil)
           (before (vigil-snapshot-tests--status root)))
       (ignore before)
       (vigil-snapshot-tests--hook root "UserPromptSubmit" "s1" "p1")
       (vigil-codebase-tests--write root "a.py" "def f():\n    w = 1\n    return w\n")
       (vigil-snapshot-tests--hook root "UserPromptSubmit" "s9" "q1" "other.1" "pi")
       (vigil-codebase-tests--write root "new.txt" "new\n")
       (vigil-snapshot-tests--hook root "Stop" "s1" "p1")
       (vigil-codebase-tests--write root "c.txt" "mine\n")
       (vigil-snapshot-tests--hook root "UserPromptSubmit" "s1" "p2")
       (vigil-codebase-tests--write root "b.el" "(defun b () 3)\n")
       ,@body)))

(ert-deftest vigil-snapshot-keeps-the-repository-as-it-was ()
  "Snapshots are listed oldest first with what they were for, and taking
them changes nothing git says of the working tree."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let ((before (vigil-snapshot-tests--status root))
          (head (vigil-git root "rev-parse" "HEAD")))
      (should-not (vigil-snapshot-list root))
      (vigil-snapshot-tests--hook root "UserPromptSubmit" "s1" "p1")
      (vigil-snapshot-tests--hook root "Stop" "s1" "p1")
      (should (equal (vigil-snapshot-tests--status root) before))
      (should (equal (vigil-git root "rev-parse" "HEAD") head))
      (let ((snapshots (vigil-snapshot-list root)))
        (should (equal (mapcar (lambda (s) (plist-get s :event)) snapshots)
                       '("UserPromptSubmit" "Stop")))
        (should (equal (plist-get (car snapshots) :session) "s1"))
        (should (equal (plist-get (car snapshots) :prompt) "p1"))
        (should (equal (plist-get (car snapshots) :host) "proj.1"))
        ;; Claude Code does not say who it is: it is the one that does not.
        (should (equal (plist-get (car snapshots) :agent) "claude"))
        ;; Nothing changed in between: the same tree, twice.
        (should (equal (plist-get (car snapshots) :tree)
                       (plist-get (cadr snapshots) :tree)))
        ;; What is not committed is in it: b.el as changed, and d.sh, which
        ;; git does not track.
        (should (string-match-p
                 "d\\.sh"
                 (vigil-git root "ls-tree" "-r" "--name-only"
                                      (plist-get (car snapshots) :commit))))
        (should (equal (vigil-git
                        root "show" (concat (plist-get (car snapshots) :commit) ":b.el"))
                       "(defun b () 2)\n"))))))

(ert-deftest vigil-snapshot-finds-what-changed-after-a-prompt ()
  "A prompt's changes run from its snapshot to its agent's stop, and name
the other agents at work meanwhile; without a stop, to now, or to the next
prompt."
  (skip-unless (executable-find "git"))
  (vigil-snapshot-tests--with-turns
    (should-not (vigil-snapshot-window root "no-such-prompt"))
    ;; p1: stopped.  What came after the stop is not its.
    (let ((window (vigil-snapshot-window root "p1")))
      (should (eq (plist-get window :end) 'stopped))
      (should (equal (vigil-snapshot-changes
                      root (plist-get (plist-get window :from) :commit)
                      (plist-get (plist-get window :to) :commit))
                     '(("M" . "a.py") ("A" . "new.txt"))))
      (should (equal (mapcar (lambda (s) (plist-get s :host)) (plist-get window :others))
                     '("other.1"))))
    ;; p2: not stopped, and nothing after it: until now, one taken to look.
    (should (= (length (vigil-snapshot-list root)) 4))
    (let ((window (vigil-snapshot-window root "p2")))
      (should (eq (plist-get window :end) 'now))
      (should (equal (plist-get (plist-get window :to) :event) "View"))
      (should (equal (vigil-snapshot-changes
                      root (plist-get (plist-get window :from) :commit)
                      (plist-get (plist-get window :to) :commit))
                     '(("M" . "b.el")))))
    (should (= (length (vigil-snapshot-list root)) 5))
    ;; Given another prompt without having stopped: until that prompt.
    (vigil-snapshot-tests--hook root "UserPromptSubmit" "s1" "p3")
    (let ((window (vigil-snapshot-window root "p2")))
      (should (eq (plist-get window :end) 'next-prompt))
      (should (equal (plist-get (plist-get window :to) :prompt) "p3")))))

(ert-deftest vigil-snapshot-says-who-changed-each-file ()
  "A file is one the prompt's edits changed, one a command of it wrote, or
one nothing is known to have changed."
  (skip-unless (executable-find "git"))
  (vigil-snapshot-tests--with-turns
    (let ((history (vigil-history root))
          (now (float-time)))
      (should (equal (vigil-snapshot-cause history "a.py" "p1" (- now 5) now)
                     "1 edit of this prompt"))
      (should (equal (vigil-snapshot-cause history "new.txt" "p1" (- now 5) now)
                     "nothing known to have changed it"))
      (should (equal (vigil-snapshot-cause history "b.el" "p2" (- now 5) now)
                     "a command of this prompt wrote it"))
      ;; An edit for another prompt, made in the window.
      (should (equal (vigil-snapshot-cause history "a.py" "p2" (- now 700) now)
                     "edited meanwhile by proj.1")))))

(ert-deftest vigil-snapshot-shows-the-diff ()
  "Without Magit, the diff is git's, under what it is of and who changed what."
  (skip-unless (executable-find "git"))
  (vigil-snapshot-tests--with-turns
    (let* ((prompt (vigil-history-prompt (vigil-history root) "p1"))
           (buffer (vigil-snapshot-show root prompt)))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'diff-mode))
            (let ((text (buffer-string)))
              (should (string-match-p
                       "Changed after “rename the variable in f please” (.*, to claude), until its agent stopped at .*At work here meanwhile: other\\.1 (pi)"
                       text))
              (should (string-match-p "^  a\\.py   1 edit of this prompt$" text))
              (should (string-match-p "^  new\\.txt   nothing known to have changed it$" text))
              (should (string-match-p "^\\+    w = 1$" text))
              (should (string-match-p "^\\+new$" text))
              ;; Not what changed after its agent stopped.
              (should-not (string-match-p "mine" text))))
        (kill-buffer buffer)))
    ;; The last prompt given here, asked for by no name.
    (let ((buffer (vigil-snapshot-latest root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-match-p "Changed after “now b” (.*, to claude), until now"
                                    (buffer-string)))
            (should (string-match-p "^\\+(defun b () 3)$" (buffer-string))))
        (kill-buffer buffer)))))

(ert-deftest vigil-snapshot-falls-back-to-the-archive ()
  "A prompt no snapshot was kept of shows the lines its edits added, and is
said to be less than a diff."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let* ((vigil-snapshot-program vigil-snapshot-tests--program)
           (history (vigil-history root))
           (buffer (vigil-snapshot-show root (vigil-history-prompt history "p1"))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-string)))
              (should (string-match-p "No snapshot was kept" text))
              (should (string-match-p "^a\\.py   Edit, .*, 2 out$" text))
              (should (string-match-p "^\\+    z = 1$" text))))
        (kill-buffer buffer))
      (setq buffer (vigil-snapshot-show root (vigil-history-prompt history "p2")))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-match-p "b\\.el  ←  \\$ python3 -" (buffer-string))))
        (kill-buffer buffer))
      ;; And one the archive has nothing of shows nothing.
      (should-not (vigil-snapshot-show root "no-such-prompt"))
      ;; Looking took no snapshot.
      (should-not (vigil-snapshot-list root)))))

(ert-deftest vigil-snapshot-is-asked-for-on-a-prompt ()
  "Wherever a prompt is listed, d on it shows what changed after it."
  (skip-unless (executable-find "git"))
  (vigil-codebase-tests--with-repository
    (let ((prompt (vigil-history-prompt (vigil-history root) "p1"))
          (asked nil))
      (with-temp-buffer
        (setq default-directory root)
        (vigil-codebase-insert-prompt prompt "a note")
        (goto-char (point-min))
        (search-forward "rename")
        (should (eq (lookup-key (get-text-property (point) 'keymap) (kbd "d"))
                    #'vigil-codebase-prompt-changes))
        ;; RET is still the button's.
        (should (eq (lookup-key (get-text-property (point) 'keymap) (kbd "RET"))
                    #'push-button))
        (cl-letf (((symbol-function 'vigil-snapshot-show)
                   (lambda (where what) (setq asked (list where what)))))
          (call-interactively #'vigil-codebase-prompt-changes))
        (should (equal (car asked) root))
        (should (equal (plist-get (cadr asked) :prompt) "p1"))))))

(ert-deftest vigil-snapshot-shows-the-diff-in-magit ()
  "With Magit, the diff is Magit's, between the two snapshots, and says
beside each file who changed it."
  (skip-unless (and (executable-find "git") vigil-snapshot-tests--magit))
  (vigil-snapshot-tests--with-turns
    (let* ((vigil-snapshot-use-magit t)
           (prompt (vigil-history-prompt (vigil-history root) "p1"))
           (buffer (vigil-snapshot-show root prompt)))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'magit-diff-mode))
            (should (string-match-p "Changed after “rename the variable in f please”"
                                    (format "%s" header-line-format)))
            (should (string-match-p "w = 1" (buffer-string)))
            (let ((said (mapcar (lambda (overlay) (overlay-get overlay 'after-string))
                                (cl-remove-if-not
                                 (lambda (overlay) (overlay-get overlay 'vigil-magit-range))
                                 (overlays-in (point-min) (point-max))))))
              ;; Each file where Magit names it: in the diff, and in the
              ;; summary over it where there is one.
              (should (>= (length said) 2))
              (should (cl-some (lambda (s) (string-match-p "nothing known" s)) said))
              (should (cl-some (lambda (s) (string-match-p "1 edit of this prompt" s)) said)))
            ;; Shown another range, it says no more of this one.
            (if (boundp 'magit-buffer-diff-range)
                (setq magit-buffer-diff-range "HEAD~1..HEAD")
              (setq magit-buffer-range "HEAD~1..HEAD"))
            (vigil-magit--annotate-range)
            (should-not vigil-magit--range)
            (should-not (cl-some (lambda (overlay) (overlay-get overlay 'vigil-magit-range))
                                 (overlays-in (point-min) (point-max)))))
        (kill-buffer buffer)))))

(provide 'vigil-snapshot-tests)
;;; vigil-snapshot-tests.el ends here
