;;; vigil-pi.el --- pi's reports, read as vigil reads Claude Code's -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; pi (pi.dev) reports to an extension, pi/vigil.ts, which hands `vigil hook'
;; each report under the names Claude Code's hooks use -- hook_event_name,
;; tool_name, tool_input, tool_response -- and says whose it is: "agent":
;; "pi".  What is inside is pi's own and is kept as pi gave it: its tools are
;; `bash', `read', `edit' and `write', a file is a `path', and every result is
;;
;;   {"content": [{"type": "text", "text": ...}, ...],   what the model saw
;;    "details": {...}, "structuredContent": ...}        what the tool adds
;;
;; `vigil-pi-report' says the same thing in the words the rest of vigil
;; reads, which are Claude Code's: a `Bash' call's `stdout', an `Edit' call's
;; `file_path' and `structuredPatch'.  It is the only place that knows pi's;
;; a report is translated as it is read, never where it is kept.
;;
;; Nothing here needs the rest of vigil, or a terminal.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst vigil-pi--tools
  '(("bash" . "Bash") ("read" . "Read") ("edit" . "Edit") ("write" . "Write")
    ("grep" . "Grep") ("find" . "Glob"))
  "pi's tools that are a tool of Claude Code's by another name.")

(defun vigil-pi--text (result)
  "The text in RESULT, a tool's result as pi gives it; nil if it has none."
  (let* ((content (and (consp result) (alist-get 'content result)))
         (texts (and (consp content)
                     (delq nil (mapcar (lambda (part)
                                         (and (consp part)
                                              (equal (alist-get 'type part) "text")
                                              (stringp (alist-get 'text part))
                                              (alist-get 'text part)))
                                       content)))))
    (cond ((stringp content) content)
          (texts (string-join texts "\n")))))

(defun vigil-pi--image (result)
  "The first image in RESULT, a tool's result as pi gives it, if it has one."
  (let ((content (and (consp result) (alist-get 'content result))))
    (and (consp content)
         (cl-find-if (lambda (part)
                       (and (consp part)
                            (equal (alist-get 'type part) "image")
                            (stringp (alist-get 'data part))))
                     content))))

(defun vigil-pi-patch (diff)
  "The hunks of DIFF, a unified diff as text, as Claude Code reports a patch.
A list of ((oldStart . N) (oldLines . N) (newStart . N) (newLines . N)
\(lines . LINES)), each of LINES with its space, `-' or `+'; nil if DIFF has
no hunk."
  (when (stringp diff)
    (let (hunks hunk lines)
      (dolist (line (split-string diff "\n"))
        (cond
         ((string-match
           "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           line)
          (when hunk (push (append hunk `((lines . ,(nreverse lines)))) hunks))
          (setq lines nil
                hunk `((oldStart . ,(string-to-number (match-string 1 line)))
                       (oldLines . ,(if (match-string 2 line)
                                        (string-to-number (match-string 2 line))
                                      1))
                       (newStart . ,(string-to-number (match-string 3 line)))
                       (newLines . ,(if (match-string 4 line)
                                        (string-to-number (match-string 4 line))
                                      1)))))
         ((and hunk (string-match-p "\\`[-+ \\\\]" line))
          (push line lines))))
      (when hunk (push (append hunk `((lines . ,(nreverse lines)))) hunks))
      (nreverse hunks))))

(defun vigil-pi--input (name input patched)
  "INPUT of pi's tool NAME, in Claude Code's words.
PATCHED says the call reported the patch it made: then what an edit asked
for is left in pi's words, so that the patch is what says what it did --
pi looks for each piece in the file as it was, not one after another."
  (if (not (and (consp input) (consp (car input))))
      input
    (let ((input (copy-alist input))
          (path (alist-get 'path input)))
      (when (and (member name '("read" "edit" "write")) (stringp path))
        (push (cons 'file_path path) input))
      (when (and (equal name "edit") (not patched))
        (let ((edits (alist-get 'edits input)))
          (when (and (consp edits) (cl-every #'consp edits))
            (setf (alist-get 'edits input)
                  (mapcar (lambda (edit)
                            `((old_string . ,(alist-get 'oldText edit))
                              (new_string . ,(alist-get 'newText edit))))
                          edits)))))
      input)))

(defun vigil-pi--response (name report)
  "What pi's tool NAME gave back, from REPORT, in Claude Code's words."
  (let* ((result (alist-get 'tool_response report))
         (text (vigil-pi--text result))
         (failed (alist-get 'is_error report))
         (path (alist-get 'path (alist-get 'tool_input report))))
    (cond
     ;; Cut short by the hook, or nothing pi's results look like: as it is.
     ((not (and (consp result) (assq 'content result))) result)
     ;; A command that fails still printed what it printed.
     ((equal name "bash")
      (let ((code (let ((structured (alist-get 'structuredContent result)))
                    (and (consp structured) (alist-get 'exit_code structured)))))
        `((stdout . ,(or text "")) (stderr . "")
          ,@(and (numberp code) `((exit_code . ,code)))
          ,@(and failed '((is_error . t))))))
     (failed `((is_error . t) (error . ,(or text ""))))
     ((equal name "read")
      (let ((image (vigil-pi--image result)))
        `((file . ,(if image
                       `((filePath . ,path) (base64 . ,(alist-get 'data image))
                         (type . ,(alist-get 'mimeType image)))
                     `((filePath . ,path) (content . ,(or text ""))))))))
     ((member name '("edit" "write"))
      (let ((patch (vigil-pi-patch (alist-get 'patch (alist-get 'details result))))
            (original (alist-get 'original_file report)))
        `((filePath . ,path)
          (type . ,(cond ((alist-get 'created report) "create")
                         ((equal name "write") "update")
                         (t "edit")))
          ,@(and patch `((structuredPatch . ,patch)))
          ,@(cond ((stringp original) `((originalFile . ,original)))
                  ((alist-get 'created report) '((originalFile . "")))))))
     ((member name '("grep" "find")) `((content . ,(or text ""))))
     ;; A tool nothing here knows: what the model saw of it, if that is text.
     ((and text (null (vigil-pi--image result))) text)
     (t result))))

(defun vigil-pi-report (report)
  "REPORT, one of pi's as pi/vigil.ts hands it over, in Claude Code's words.
Only a tool call's report says anything differently; the others are
returned as they are."
  (if (not (member (alist-get 'hook_event_name report) '("PreToolUse" "PostToolUse")))
      report
    (let* ((name (alist-get 'tool_name report))
           (post (equal (alist-get 'hook_event_name report) "PostToolUse"))
           (response (and post (vigil-pi--response name report)))
           (patched (and (consp response) (alist-get 'structuredPatch response) t))
           (report (copy-alist report)))
      (setf (alist-get 'tool_name report)
            (or (cdr (assoc name vigil-pi--tools)) name))
      (when (assq 'tool_input report)
        (setf (alist-get 'tool_input report)
              (vigil-pi--input name (alist-get 'tool_input report) patched)))
      (when post
        (setf (alist-get 'tool_response report) response))
      report)))

(provide 'vigil-pi)
;;; vigil-pi.el ends here
