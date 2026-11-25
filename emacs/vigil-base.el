;;; vigil-base.el --- What every reader of vigil's files shares -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools

;;; Commentary:

;; `vigil hook' (bin/vigil) keeps reports as JSON in files.  Several things
;; here read them -- an agent's buffer (vigil.el), a session read by its name
;; (vigil-survey.el), the archive (vigil-archive.el, vigil-history.el) -- and
;; this is what they all need, written once: where the files are unless told
;; otherwise, JSON as alists and lists, when a report happened, and a few
;; words about laying text and numbers out in a list.
;;
;; Nothing here needs anything but Emacs.

;;; Code:

(require 'subr-x)

(defgroup vigil nil
  "What a coding agent did, kept and shown."
  :group 'tools
  :prefix "vigil-")

;;;; Where things are kept

(defun vigil-base-data-directory (name)
  "Where bin/vigil keeps NAME, a directory of its data, unless told otherwise.
Under $XDG_DATA_HOME/vigil, as the program has it."
  (expand-file-name (concat "vigil/" name)
                    (or (getenv "XDG_DATA_HOME") "~/.local/share")))

;;;; JSON

(defun vigil-base-json-read ()
  "The JSON value at point in this buffer, as alists and lists.
Null and false are nil.  Signals what `json-parse-buffer' does."
  (json-parse-buffer :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun vigil-base-json-string (string)
  "The JSON object STRING says, as an alist; nil if it says none."
  (ignore-errors
    (let ((value (json-parse-string string :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)))
      (and (consp value) value))))

(defun vigil-base-json-file (file)
  "The JSON object in FILE, as an alist; nil if it is not there or not one."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((value (vigil-base-json-read)))
        (and (consp value) value)))))

;;;; A call that failed

(defun vigil-base-settled (report)
  "REPORT, with a call that failed said the way one that ended is.
Claude Code reports a call that failed as an event of its own,
\"PostToolUseFailure\", with what went wrong as `error' and no
`tool_response'.  Readers know one way a call ends: \"PostToolUse\", whose
response says `is_error' where it failed, as pi's does.  So this is that
event in those words, `interrupted' too where the user stopped it; and any
other report is itself."
  (if (equal (alist-get 'hook_event_name report) "PostToolUseFailure")
      (let ((error (alist-get 'error report)))
        (append `((hook_event_name . "PostToolUse")
                  (tool_response . ((is_error . t)
                                    (error . ,(if (stringp error) error ""))
                                    ,@(and (alist-get 'is_interrupt report)
                                           '((interrupted . t))))))
                (assq-delete-all 'hook_event_name
                                 (assq-delete-all 'tool_response (copy-alist report)))))
    report))

;;;; When a report happened

(defun vigil-base-report-time (file &optional attributes)
  "When the report in FILE happened, in seconds.
The time in its name, to the microsecond, where the hook was given one --
by bash, or by a reporter that says when each event happened, which is not
the order its reports arrive in.  Otherwise the file system's, from
ATTRIBUTES where they are already known."
  (let ((name (file-name-nondirectory file)))
    (if (string-match "\\`[0-9]\\{9,\\}\\.[0-9]+" name)
        (string-to-number (match-string 0 name))
      (or (ignore-errors
            (float-time (file-attribute-modification-time
                         (or attributes (file-attributes file)))))
          (if (string-match "\\`[0-9]\\{9,\\}" name)
              (float (string-to-number (match-string 0 name)))
            0.0)))))

;;;; Text and numbers in a list

(defun vigil-base-one-line (text limit)
  "TEXT on one line, and no more than LIMIT characters of it."
  (let ((line (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))))
    (if (> (length line) limit)
        (concat (substring line 0 (max 0 (1- limit))) "…")
      line)))

(defun vigil-base-number (text value)
  "TEXT, a cell of a tabulated list, saying VALUE: what its column is sorted by."
  (propertize text 'vigil-base-number value))

(defun vigil-base-by-number (column)
  "A predicate sorting a tabulated list's rows by the number in COLUMN, most first.
The number each cell was given by `vigil-base-number'."
  (lambda (a b)
    (> (or (get-text-property 0 'vigil-base-number (aref (cadr a) column)) -1)
       (or (get-text-property 0 'vigil-base-number (aref (cadr b) column)) -1))))

(provide 'vigil-base)
;;; vigil-base.el ends here
