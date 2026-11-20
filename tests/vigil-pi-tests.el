;;; vigil-pi-tests.el --- pi's reports, read by vigil -*- lexical-binding: t; -*-

;; Reports as pi/vigil.ts hands them to `vigil hook', their insides as pi
;; 1.5.2 gave them, written into a directory of the test's own.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-pi-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-turn)
(require 'vigil-edits)
(require 'vigil-archive)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-host)

(defvar vigil-pi-tests--n 0)

(defun vigil-pi-tests--report (event id tool input &rest more)
  "A report of pi's: EVENT of the call ID to TOOL with INPUT, and MORE."
  `((hook_event_name . ,event) (agent . "pi") (session_id . "s")
    (cwd . "/tmp/proj") (tool_name . ,tool) (tool_use_id . ,id)
    (tool_input . ,input) ,@more))

(defun vigil-pi-tests--result (text &rest more)
  "A tool's result as pi gives one: TEXT for the model, and MORE."
  `((content . [((type . "text") (text . ,text))]) ,@more))

(defun vigil-pi-tests--write (directory report)
  "Write REPORT into DIRECTORY the way the hook does."
  (let ((file (expand-file-name
               (format "%d.%06d-1-%d.json" 1700000000 (cl-incf vigil-pi-tests--n)
                       vigil-pi-tests--n)
               directory)))
    (with-temp-file file
      (insert (json-serialize report :false-object :false) "\n"))))

(defun vigil-pi-tests--call (directory id tool input result &rest more)
  "Write the two reports of a finished call into DIRECTORY."
  (vigil-pi-tests--write directory
                         (vigil-pi-tests--report "PreToolUse" id tool input
                                                 '(context_tokens . 2100)))
  (vigil-pi-tests--write directory
                         (apply #'vigil-pi-tests--report "PostToolUse" id tool input
                                `(tool_response . ,result) '(duration_ms . 250)
                                more)))

(defmacro vigil-pi-tests--with-agent (&rest body)
  "Run BODY in an agent buffer whose reports are in `dir'."
  (declare (indent 0))
  `(let* ((vigil-directory (make-temp-file "vigil" t))
          (dir (expand-file-name "proj.1" vigil-directory))
          (buffer (generate-new-buffer "*agent*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked-host-name "proj.1")
           (make-directory dir t)
           ,@body)
       (with-current-buffer buffer (vigil--stop))
       (kill-buffer buffer)
       (delete-directory vigil-directory t))))

(defun vigil-pi-tests--body (call)
  "What CALL is shown as, as text."
  (with-temp-buffer
    (vigil--insert-body call)
    (buffer-substring-no-properties (point-min) (point-max))))

(defconst vigil-pi-tests--patch
  "--- notes.txt\n+++ notes.txt\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n")

(ert-deftest vigil-pi-a-command-is-a-bash-call ()
  "pi's `bash' is shown as a command with what it printed; one that failed
says how it exited, and the context it was made in is the report's own."
  (vigil-pi-tests--with-agent
    (vigil-pi-tests--call
     dir "c1" "bash" '((command . "echo hi; ls nope"))
     (vigil-pi-tests--result
      "hi\nls: nope: No such file or directory\n\n\nCommand exited with code 1"
      '(structuredContent . ((output . "hi\n") (exit_code . 1))))
     '(is_error . t))
    (vigil-pi-tests--call dir "c2" "bash" '((command . "true"))
                          (vigil-pi-tests--result "(no output)"
                                                  '(structuredContent . ((exit_code . 0))))
                          '(is_error . :false))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (should (= (length vigil--order) 2))
    (let ((call (car vigil--order)))
      (should (equal (vigil-call-name call) "Bash"))
      (should (equal (vigil--summary call) "echo hi; ls nope"))
      (should (equal (vigil--status call) "exit 1"))
      (should (equal (vigil-call-duration call) 0.25))
      (should (equal (vigil--context call (current-buffer)) 2100))
      (should (string-match-p "ls: nope: No such file" (vigil-pi-tests--body call))))
    (should (equal (vigil--status (cadr vigil--order)) "done"))))

(ert-deftest vigil-pi-an-edit-is-its-patch ()
  "pi's `edit' is shown as the patch it reports, and the file is known before
and after it: from the file as the extension found it, and that patch."
  (vigil-pi-tests--with-agent
    (vigil-pi-tests--call
     dir "c1" "edit"
     '((path . "notes.txt") (edits . [((oldText . "beta") (newText . "BETA"))]))
     (vigil-pi-tests--result "Successfully replaced 1 block(s) in notes.txt."
                             `(details . ((diff . " 1 alpha") (patch . ,vigil-pi-tests--patch)
                                          (firstChangedLine . 2))))
     '(is_error . :false) '(original_file . "alpha\nbeta\ngamma\n"))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((call (car vigil--order)))
      (should (equal (vigil-call-name call) "Edit"))
      (should (equal (vigil--summary call) "notes.txt"))
      (should (equal (vigil-turn--what call) "edited notes.txt"))
      (should (equal (vigil-diff call)
                     (concat "--- a/notes.txt\n+++ b/notes.txt\n@@ -1,3 +1,3 @@\n"
                             " alpha\n-beta\n+BETA\n gamma\n")))
      (let ((edit (car (gethash (file-truename "/tmp/proj/notes.txt") vigil--edits))))
        (should (eq (vigil-edit-call edit) call))
        (should (equal (vigil-edit-before edit) "alpha\nbeta\ngamma\n"))
        (should (equal (vigil-edit-after edit) "alpha\nBETA\ngamma\n")))
      ;; The whole file is kept with the edit, not with the call.
      (should-not (alist-get 'originalFile (vigil-call-response call))))))

(ert-deftest vigil-pi-a-write-makes-or-replaces-a-file ()
  "pi's `write' says nothing of what was there: the extension does, and a file
replaced is shown as what changed in it."
  (vigil-pi-tests--with-agent
    (vigil-pi-tests--call dir "c1" "write" '((path . "new.txt") (content . "made\n"))
                          (vigil-pi-tests--result "Successfully wrote to new.txt")
                          '(is_error . :false) '(created . t))
    (vigil-pi-tests--call dir "c2" "write" '((path . "new.txt") (content . "made\nagain\n"))
                          (vigil-pi-tests--result "Successfully wrote to new.txt")
                          '(is_error . :false) '(original_file . "made\n"))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((made (car vigil--order)) (again (cadr vigil--order)))
      (should (equal (vigil-turn--what made) "created new.txt"))
      (should (equal (vigil-diff made)
                     "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+made\n"))
      (should (equal (vigil-turn--what again) "rewrote new.txt"))
      (should (string-match-p "^ made\n\\+again$" (vigil-diff again)))
      (should (equal (mapcar (lambda (edit) (list (vigil-edit-before edit)
                                                  (vigil-edit-after edit)))
                             (gethash (file-truename "/tmp/proj/new.txt") vigil--edits))
                     '(("" "made\n") ("made\n" "made\nagain\n")))))))

(ert-deftest vigil-pi-a-refused-edit-changed-nothing ()
  "An edit pi could not make is said to have failed, with why; it is no diff,
and the file is not taken to have been edited."
  (vigil-pi-tests--with-agent
    (vigil-pi-tests--call
     dir "c1" "edit"
     '((path . "notes.txt") (edits . [((oldText . "zzz") (newText . "yyy"))]))
     (vigil-pi-tests--result "Could not find the exact text in notes.txt.")
     '(is_error . t) '(original_file . "alpha\n"))
    (vigil-mode 1)
    (vigil--scan (current-buffer))
    (let ((call (car vigil--order)))
      (should (equal (vigil--status call) "failed"))
      (should-not (vigil-diff call))
      (should (string-match-p "Could not find the exact text" (vigil-pi-tests--body call)))
      (should (zerop (hash-table-count vigil--edits))))))

(ert-deftest vigil-pi-a-read-is-the-file-or-the-image ()
  "pi's `read' is shown as the file it read; an image is not shown as base64."
  (let ((text (vigil-pi-report
               (vigil-pi-tests--report
                "PostToolUse" "c1" "read" '((path . "notes.txt"))
                '(tool_response
                  . ((content . (((type . "text") (text . "alpha\nbeta\n")))))))))
        (image (vigil-pi-report
                (vigil-pi-tests--report
                 "PostToolUse" "c2" "read" '((path . "shot.png"))
                 '(tool_response
                   . ((content . (((type . "text") (text . "Read image file [image/png]"))
                                  ((type . "image") (data . "aGVsbG8=")
                                   (mimeType . "image/png"))))))))))
    (should (equal (alist-get 'tool_name text) "Read"))
    (should (equal (alist-get 'file_path (alist-get 'tool_input text)) "notes.txt"))
    (should (equal (alist-get 'content (alist-get 'file (alist-get 'tool_response text)))
                   "alpha\nbeta\n"))
    (let ((file (alist-get 'file (alist-get 'tool_response image))))
      (should (equal (alist-get 'base64 file) "aGVsbG8="))
      (should (equal (alist-get 'type file) "image/png")))))

(ert-deftest vigil-pi-reads-a-patch ()
  "A unified diff as text is the hunks Claude Code would report."
  (should (equal (vigil-pi-patch "--- a\n+++ a\n@@ -3 +3,2 @@\n-c\n+C\n+d\n\\ No newline at end of file\n")
                 '(((oldStart . 3) (oldLines . 1) (newStart . 3) (newLines . 2)
                    (lines . ("-c" "+C" "+d" "\\ No newline at end of file"))))))
  (should (= (length (vigil-pi-patch "@@ -1,2 +1,2 @@\n a\n-b\n+B\n@@ -9,1 +9,1 @@\n-x\n+y\n")) 2))
  (should-not (vigil-pi-patch "nothing of the kind"))
  (should-not (vigil-pi-patch nil)))

(ert-deftest vigil-pi-leaves-what-is-not-a-call-and-what-it-does-not-know ()
  "A prompt is returned as it is; a tool nothing here knows keeps its name,
and is what the model saw of it."
  (let ((prompt '((hook_event_name . "UserPromptSubmit") (agent . "pi") (prompt . "hi"))))
    (should (eq (vigil-pi-report prompt) prompt)))
  (let ((report (vigil-pi-report
                 (vigil-pi-tests--report
                  "PostToolUse" "c1" "todo" '((action . "list"))
                  '(tool_response . ((content . (((type . "text") (text . "1. tests"))))))))))
    (should (equal (alist-get 'tool_name report) "todo"))
    (should (equal (alist-get 'tool_response report) "1. tests"))))

(ert-deftest vigil-pi-an-export-names-the-tool-as-pi-does ()
  "In an eval dataset a call keeps pi's name for its tool, and says its file."
  (let* ((pre (vigil-pi-tests--report "PreToolUse" "c1" "read" '((path . "/tmp/proj/a.txt"))))
         (row (vigil-archive--call-summary pre nil)))
    (should (equal (alist-get 'tool row) "read"))
    (should (equal (alist-get 'summary row) "a.txt"))))

(provide 'vigil-pi-tests)
;;; vigil-pi-tests.el ends here
