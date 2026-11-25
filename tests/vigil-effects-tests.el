;;; vigil-effects-tests.el --- What each command changed -*- lexical-binding: t; -*-

;; A repository, an agent whose reports say it ran commands there, and the
;; snapshots bin/vigil keeps around each of them, as its hook keeps them.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-effects-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-turn)
(require 'vigil-edits)
(require 'vigil-effects)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-host)

(defconst vigil-effects-tests--program
  (expand-file-name "../bin/vigil"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The vigil of this checkout.")

(defvar vigil-effects-tests--n 0)

(defconst vigil-effects-tests--environment
  '("VIGIL_SESSION=proj.1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
  "What git and the hook are told, so that nothing of this machine's counts.")

(defun vigil-effects-tests--git (root &rest args)
  "Run git with ARGS in ROOT; it must not fail."
  (let ((default-directory root)
        (process-environment (append vigil-effects-tests--environment process-environment)))
    (should (eq 0 (apply #'call-process "git" nil nil nil
                         "-c" "user.name=T" "-c" "user.email=t@example.org" args)))))

(defun vigil-effects-tests--hook (root event &optional call)
  "Hand vigil's snapshot hook EVENT in ROOT, of the call with the id CALL."
  (let ((process-environment
         (append vigil-effects-tests--environment process-environment)))
    (with-temp-buffer
      (insert (json-serialize `((hook_event_name . ,event) (session_id . "s1")
                                (prompt_id . "p1") (cwd . ,root)
                                ,@(and call `((tool_name . "Bash") (tool_use_id . ,call))))))
      (should (eq 0 (call-process-region (point-min) (point-max)
                                         vigil-effects-tests--program
                                         t t nil "snapshot")))
      (should (equal (buffer-string) "")))))

(defun vigil-effects-tests--report (directory root alist)
  "Write ALIST as a report from ROOT under DIRECTORY, the way the hook would."
  (make-directory directory t)
  (with-temp-file (expand-file-name
                   (format "%d.%06d-1-%d.json" 1700000000
                           (cl-incf vigil-effects-tests--n) vigil-effects-tests--n)
                   directory)
    (insert (json-serialize `((cwd . ,root) ,@alist)) "\n")))

(defun vigil-effects-tests--command (directory root id command change &optional how)
  "Have the agent run COMMAND, the call ID, in ROOT; CHANGE is what it does.
Reported under DIRECTORY, with a snapshot asked for before it and after.
HOW is `failed' for one that failed, which is not reported done."
  (vigil-effects-tests--report
   directory root `((hook_event_name . "PreToolUse") (tool_name . "Bash")
                    (tool_use_id . ,id) (tool_input . ((command . ,command)))))
  (vigil-effects-tests--hook root "PreToolUse" id)
  (funcall change)
  (if (eq how 'failed)
      (vigil-effects-tests--hook root "PostToolUseFailure" id)
    (vigil-effects-tests--hook root "PostToolUse" id)
    (vigil-effects-tests--report
     directory root `((hook_event_name . "PostToolUse") (tool_name . "Bash")
                      (tool_use_id . ,id) (tool_input . ((command . ,command)))
                      (tool_response . ((stdout . "") (stderr . "")))))))

(defmacro vigil-effects-tests--with-commands (&rest body)
  "Run BODY in an agent buffer whose commands changed `file', in `root'.
After a prompt: the command b1 rewrote its second line; the edit e1 its
third; you its first, by hand; the command b2 added a line and a file that
is not text, and failed; b3 changed nothing; b4, in the next turn, took out
the line b1 wrote."
  (declare (indent 0))
  `(let* ((vigil-directory (make-temp-file "vigil" t))
          (dir (expand-file-name "proj.1" vigil-directory))
          (root (file-name-as-directory (file-truename (make-temp-file "vigil-repo" t))))
          (file (expand-file-name "notes.txt" root))
          (vigil-snapshot-program vigil-effects-tests--program)
          (vigil-effects--of (make-hash-table :test #'eq))
          (vigil-effects--roots (make-hash-table :test #'equal))
          (vigil-mark-edits nil)
          (write (lambda (text) (with-temp-file file (insert text))))
          (buffer (generate-new-buffer "*agent*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked-host-name "proj.1")
           (funcall write "alpha\nbeta\ngamma\n")
           (vigil-effects-tests--git root "init" "-q" "-b" "main")
           (vigil-effects-tests--git root "add" "-A")
           (vigil-effects-tests--git root "commit" "-q" "-m" "Notes")
           (vigil-effects-tests--report
            dir root '((hook_event_name . "UserPromptSubmit") (prompt . "fix the notes")))
           (vigil-effects-tests--hook root "UserPromptSubmit")
           (vigil-effects-tests--command
            dir root "b1" "sed -i s/beta/BETA/ notes.txt"
            (lambda () (funcall write "alpha\nBETA\ngamma\n")))
           (vigil-effects-tests--report
            dir root `((hook_event_name . "PostToolUse") (tool_name . "Edit")
                       (tool_use_id . "e1")
                       (tool_input . ((file_path . ,file) (old_string . "gamma")
                                      (new_string . "GAMMA")))
                       (tool_response . ((filePath . ,file)
                                         (originalFile . "alpha\nBETA\ngamma\n")))))
           (funcall write "ALPHA\nBETA\nGAMMA\n")
           (vigil-effects-tests--command
            dir root "b2" "python3 add.py"
            (lambda ()
              (funcall write "ALPHA\nBETA\nGAMMA\ndelta\n")
              (let ((coding-system-for-write 'no-conversion))
                (write-region (unibyte-string 0 1 2 0) nil
                              (expand-file-name "data.bin" root) nil 'silent)))
            'failed)
           (vigil-effects-tests--command dir root "b3" "ls" #'ignore)
           (vigil-effects-tests--report
            dir root '((hook_event_name . "UserPromptSubmit") (prompt . "and no beta")))
           (vigil-effects-tests--command
            dir root "b4" "sed -i /BETA/d notes.txt"
            (lambda () (funcall write "ALPHA\nGAMMA\ndelta\n")))
           (vigil-mode 1)
           (vigil--scan (current-buffer))
           (vigil-effects-update)
           (let* ((agent (current-buffer))
                  (calls vigil--calls)
                  (call (lambda (id) (gethash id calls))))
             (ignore agent call)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when vigil-effects--timer (cancel-timer vigil-effects--timer))
           (vigil--stop))
         (kill-buffer buffer))
       (dolist (other (buffer-list))
         (when (and (buffer-file-name other)
                    (string-prefix-p root (buffer-file-name other)))
           (with-current-buffer other (set-buffer-modified-p nil))
           (kill-buffer other)))
       (delete-directory root t)
       (delete-directory vigil-directory t))))

(ert-deftest vigil-effects-say-what-each-command-changed ()
  "A command that changed files has them, and the two snapshots; one that
changed nothing has nothing; one that failed still has what it changed, and
not what was changed by hand before it."
  (skip-unless (executable-find "git"))
  (vigil-effects-tests--with-commands
    (let ((b1 (vigil-effects-of (funcall call "b1")))
          (b2 (vigil-effects-of (funcall call "b2"))))
      (should (equal (vigil-effects-names (funcall call "b1")) '("notes.txt")))
      (should (equal (vigil-effect-event b1) "PostToolUse"))
      (should (equal (vigil-git root "show" (concat (vigil-effect-from b1) ":notes.txt"))
                     "alpha\nbeta\ngamma\n"))
      (should (equal (vigil-git root "show" (concat (vigil-effect-to b1) ":notes.txt"))
                     "alpha\nBETA\ngamma\n"))
      ;; The failed one: the line it added, not the edit or the hand before it.
      (should (equal (vigil-effect-event b2) "PostToolUseFailure"))
      (should (equal (mapcar (lambda (f) (list (plist-get f :status) (plist-get f :name)
                                               (plist-get f :followed)))
                             (vigil-effect-files b2))
                     '(("A" "data.bin" nil) ("M" "notes.txt" t))))
      (should (equal (vigil-git root "show" (concat (vigil-effect-from b2) ":notes.txt"))
                     "ALPHA\nBETA\nGAMMA\n"))
      (should-not (vigil-effects-of (funcall call "b3")))
      (should-not (vigil-effects-of (funcall call "e1")))
      (should (equal (vigil-effects-names (funcall call "b4")) '("notes.txt"))))
    ;; Asked again, nothing is read again, and nothing is kept twice.
    (let ((made vigil-edits-made))
      (vigil-effects-update)
      (should (= vigil-edits-made made))
      (should (= (length (gethash (file-truename file) vigil--edits)) 4)))))

(ert-deftest vigil-effects-make-a-commands-lines-its-own ()
  "The lines a command wrote are its own in the file, beside an edit's; what
was written by hand between two of them is nobody's."
  (skip-unless (executable-find "git"))
  (vigil-effects-tests--with-commands
    (with-current-buffer (find-file-noselect file)
      (should (equal (mapcar #'car (vigil-edits-owners))
                     (list nil (funcall call "e1") (funcall call "b2")))))
    ;; As the first turn left it: b1's line is b1's.
    (let* ((edits (cl-remove-if (lambda (pair)
                                  (eq (vigil-edit-call (car pair)) (funcall call "b4")))
                                (vigil-edits--of-file (file-truename file))))
           (lines nil) (owners nil))
      (should (equal (mapcar (lambda (pair) (vigil-call-id (vigil-edit-call (car pair))))
                             edits)
                     '("b1" "e1" "b2")))
      (dolist (pair edits)
        (let ((step (vigil-edits--step lines owners (car pair))))
          (setq lines (car step) owners (cdr step))))
      (should (equal lines '("ALPHA" "BETA" "GAMMA" "delta")))
      (should (equal owners (list nil (funcall call "b1") (funcall call "e1")
                                  (funcall call "b2")))))))

(ert-deftest vigil-effects-are-in-a-turns-diff-and-its-list ()
  "A turn's diff has what its commands changed, and a turn's list names the
files beside each command that changed any."
  (skip-unless (executable-find "git"))
  (vigil-effects-tests--with-commands
    (let ((case-fold-search nil)
          (first (cdr (vigil-edits--diff agent (vigil-turn-calls agent 1))))
          (second (cdr (vigil-edits--diff agent (vigil-turn-calls agent 2)))))
      (should (string-match-p "^-beta$" first))
      (should (string-match-p "^\\+BETA$" first))
      (should (string-match-p "^\\+delta$" first))
      (should (string-match-p "^-BETA$" second))
      (should-not (string-match-p "^[-+]delta" second))
      (should (string-match-p "changed notes.txt"
                              (vigil-turn--what (funcall call "b1"))))
      (should (string-match-p "changed data.bin, notes.txt"
                              (vigil-turn--what (funcall call "b2"))))
      (should-not (string-match-p "changed" (vigil-turn--what (funcall call "b3")))))))

(ert-deftest vigil-effects-show-a-commands-diff-where-it-is-inspected ()
  "Inspected, a command is shown with the files it changed and their diff; one
that changed nothing is shown as it was."
  (skip-unless (executable-find "git"))
  (vigil-effects-tests--with-commands
    (let ((case-fold-search nil)
          (shown (lambda (id)
                   (with-temp-buffer
                     (vigil--insert-body (funcall call id))
                     (buffer-substring-no-properties (point-min) (point-max))))))
      (let ((text (funcall shown "b1")))
        (should (string-match-p "sed -i" text))
        (should (string-match-p "^Changed 1 file" text))
        (should (string-match-p "^  M notes.txt  \\+1 −1$" text))
        (should (string-match-p "^-beta$" text))
        (should (string-match-p "^\\+BETA$" text)))
      (let ((text (funcall shown "b2")))
        (should (string-match-p "^Changed 2 files  ·  though it failed" text))
        (should (string-match-p "^  A data.bin   not text$" text))
        (should (string-match-p "^\\+delta$" text)))
      (should-not (string-match-p "Changed" (funcall shown "b3")))
      ;; A long diff is cut, and says where the rest is.
      (let ((vigil-effects-diff-lines 3))
        (should (string-match-p "more lines.  All of it: git diff [0-9a-f]+ [0-9a-f]+"
                                (funcall shown "b1")))))))

(ert-deftest vigil-effects-begin-again-with-the-agents-record ()
  "A record begun afresh has its commands' changes found again; and without
snapshots, or outside a repository, nothing is known and nothing fails."
  (skip-unless (executable-find "git"))
  (vigil-effects-tests--with-commands
    (vigil-mode -1)
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (should-not (vigil-effects-of (gethash "b1" vigil--calls)))
    (vigil-effects-update)
    (should (equal (vigil-effects-names (gethash "b1" vigil--calls)) '("notes.txt")))
    ;; The snapshots forgotten: nothing new, nothing lost, no error.
    (vigil-git root "update-ref" "-d" vigil-snapshot-ref)
    (vigil-effects-update)
    (should (vigil-effects-of (gethash "b1" vigil--calls)))
    (should-not (vigil-effects--root "/nowhere/at/all"))))

(provide 'vigil-effects-tests)
;;; vigil-effects-tests.el ends here
