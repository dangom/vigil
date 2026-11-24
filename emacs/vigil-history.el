;;; vigil-history.el --- What agents did to a repository, from the archive -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; The archive `vigil hook' keeps has every prompt, edit and command of
;; every session.  This reads it for one repository, and answers three
;; questions about a file of it:
;;
;;   (vigil-history-edits HISTORY "src/x.py")   which edits were made to it,
;;                                              and for which prompts
;;   (vigil-history-runs HISTORY "src/x.py")    which commands exercised it:
;;                                              named it, mentioned it in
;;                                              what they printed, or ran
;;                                              code of it (vigil-coverage)
;;   (vigil-history-origin HISTORY "src/x.py" LINES)
;;                                              which edits wrote these
;;                                              lines, by their text
;;
;; HISTORY is `(vigil-history ROOT)': the sessions that worked in ROOT or
;; under it, read once and then only as far as they have grown.
;;
;; What it can and cannot know:
;;
;; - An edit is a call of Edit, Write, MultiEdit or NotebookEdit, or of pi's
;;   edit or write.  A file changed by a command -- sed, a formatter -- is
;;   not one.  pi's reports are read as vigil-pi.el reads them; its prompts
;;   have an id, and so its work a prompt, only since pi/vigil.ts gives one.
;; - A command exercised a file it names, unless the program it gives the
;;   name to only reads files (`vigil-history-reading-programs': cat, grep,
;;   git and the like).  It mentioned a file whose name, with a line
;;   number, is in what it printed: a traceback, a compiler's error.
;; - A command that failed is known by its having begun and never been
;;   answered: its report is not kept, so what it printed is not known.
;;
;; This needs vigil-pi.el, which needs nothing, and nothing else of vigil
;; or beyond Emacs: it reads
;; files, and runs nothing.  What it reads of a session it keeps, in a
;; cache of its own (`vigil-history-cache-directory'), so that the archive
;; is read once: it writes nowhere else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-pi)
(require 'vigil-base)

(defgroup vigil-history nil
  "What agents did to a repository, from vigil's archive."
  :group 'tools)

(defcustom vigil-history-archive-directory nil
  "Where `vigil hook' keeps the archive, or nil for where it does by default.
That is `vigil-archive-directory' if vigil-archive.el is loaded, else
$VIGIL_ARCHIVE_DIR, else vigil/archive under $XDG_DATA_HOME."
  :type '(choice (const :tag "Where vigil keeps it" nil) directory))

(defcustom vigil-history-coverage-directory nil
  "Where the code commands ran is kept, or nil for where it is by default.
$VIGIL_COVERAGE_DIR, else vigil/coverage under $XDG_DATA_HOME.  See
bin/vigil-shell: nothing is kept there unless that is asked for."
  :type '(choice (const :tag "Where vigil keeps it" nil) directory))

(defcustom vigil-history-reading-programs
  '("cat" "head" "tail" "less" "more" "bat" "sed" "awk" "grep" "egrep" "fgrep"
    "rg" "ag" "ls" "wc" "git" "jj" "diff" "find" "fd" "cp" "mv" "rm" "mkdir"
    "touch" "chmod" "chown" "ln" "echo" "printf" "stat" "file" "open" "du"
    "tree" "nl" "sort" "uniq" "cut" "tr" "xxd" "hexdump" "md5" "shasum"
    "sha256sum" "tar" "zip" "unzip" "gzip" "code" "emacsclient" "cd" "pushd"
    "test" "[" "[[" "basename" "dirname" "realpath" "readlink" "tee" "jq" "yq"
    "cmp" "comm" "patch" "trash" "rsync" "scp" "curl" "wget")
  "Programs that read or move the files they are given, and run none of them.
A file named to one of these was not exercised by the command."
  :type '(repeat string))

(defcustom vigil-history-cache-directory nil
  "Where what was read of each archived session is kept, to be read faster.
Nil for vigil/history under $XDG_CACHE_HOME, by default ~/.cache.  A
session's file in the archive is tens of megabytes, most of it never
wanted here; what is wanted of it is kept beside, and only what the session
has written since is read from the archive.  Deleting the directory loses
nothing: it is made again."
  :type '(choice (const :tag "Under the cache directory" nil) directory))

(defvar vigil-archive-directory)

(defconst vigil-history--version 2
  "Which shape what is kept of a session has.  Another is read afresh.")

(defun vigil-history--cache-file (file)
  "Where what was read of FILE, a session's in the archive, is kept."
  (expand-file-name
   (concat (file-name-base file) ".eld")
   (or vigil-history-cache-directory
       (expand-file-name "vigil/history"
                         (or (getenv "XDG_CACHE_HOME") "~/.cache")))))

(defun vigil-history--archive ()
  "The archive's directory."
  (file-name-as-directory
   (expand-file-name
    (or vigil-history-archive-directory
        (and (boundp 'vigil-archive-directory) vigil-archive-directory)
        (let ((dir (getenv "VIGIL_ARCHIVE_DIR")))
          (and dir (not (string-empty-p dir)) dir))
        (vigil-base-data-directory "archive")))))

(defun vigil-history--coverage ()
  "The directory the code commands ran is kept in."
  (file-name-as-directory
   (expand-file-name
    (or vigil-history-coverage-directory
        (let ((dir (getenv "VIGIL_COVERAGE_DIR")))
          (and dir (not (string-empty-p dir)) dir))
        (vigil-base-data-directory "coverage")))))

;;;; One session's file

(cl-defstruct (vigil-history--file (:constructor vigil-history--file-make)
                                   (:copier nil))
  "What was read of one session's file in the archive."
  (offset 0 :documentation "How many bytes of it were read.")
  (prompts nil :documentation "Its prompts, newest first: plists.")
  (edits nil :documentation "Its edits, newest first: plists.")
  (commands (make-hash-table :test #'equal)
            :documentation "Its commands by the id of their calls: plists.")
  (order nil :documentation "The ids of its commands, newest first."))

(defvar vigil-history--files (make-hash-table :test #'equal)
  "What was read of each session's file, by its name.")

(defconst vigil-history--wanted
  (concat "\"hook_event_name\":\"UserPromptSubmit\""
          "\\|\"tool_name\":\"\\(?:Bash\\|Edit\\|Write\\|MultiEdit\\|NotebookEdit"
          ;; pi's names for its own.
          "\\|bash\\|edit\\|write\\)\"")
  "What a line of the archive worth parsing has in it.")

(defun vigil-history--words (command)
  "The words of COMMAND that could name files, and its programs.
A cons (WORDS . PROGRAMS).  Each of WORDS is (WORD PROGRAM HOW); PROGRAM
is the one the word is given to.  HOW is `argument'; or `written',
for what a redirection writes to and for a name inside a heredoc, which is
a program or a text the command was handed, not something it ran.  Split
roughly, as text: this is to find names, and nothing is done with what is
found but to look it up among a repository's files."
  (let ((words nil) (programs nil)
        (written (make-hash-table :test #'equal)) (rest command))
    ;; Heredocs out: their bodies are text, not the command's own words.
    (let ((guard 0))
      (while (and (< (cl-incf guard) 50)
                  (string-match "<<-?[ \t]*\\(['\"]?\\)\\([A-Za-z_][A-Za-z0-9_]*\\)\\1" rest))
        (let* ((beg (match-beginning 0))
               (body (match-end 0))
               (delimiter (match-string 2 rest))
               (close (string-match (concat "^[ \t]*" (regexp-quote delimiter) "[ \t]*$")
                                    rest body))
               (end (or close (length rest)))
               (after (if close (match-end 0) (length rest)))
               (text (substring rest body end)))
          ;; The rest first: what follows uses the match data.
          (setq rest (concat (substring rest 0 beg) " " (substring rest after)))
          (dolist (token (split-string text "[][ \t\n(){}<>'\",;:=]+" t))
            (when (and (string-match-p "[./]" token) (not (string-prefix-p "-" token)))
              (push (list token nil 'written) words))))))
    (let ((start 0))
      (while (string-match "[0-9]?>>?|?[ \t]*\\([^ \t\n;|&<>()]+\\)" rest start)
        (setq start (match-end 0))
        (let ((name (string-trim (match-string 1 rest) "['\"]+" "['\"]+")))
          (unless (or (string-prefix-p "&" name) (string-prefix-p "/dev/" name))
            (puthash name t written)))))
    ;; What is quoted is not the command's own words either: a pattern, a
    ;; program given to `-c'.  And it would be split where it should not be.
    (setq rest (replace-regexp-in-string
                "'[^']*'\\|\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"" " " rest t t))
    (dolist (segment (split-string rest "[;|&\n]+\\|\\$(" t))
      (let* ((tokens (split-string segment "[][ \t(){}<>'\",]+" t))
             ;; Past `FOO=1': the program is the first word that sets nothing.
             (program (cl-find-if-not
                       (lambda (token)
                         (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" token))
                       tokens))
             (program (and program (file-name-nondirectory program))))
        (when program (push program programs))
        (dolist (token tokens)
          ;; `--config=a/b.toml' names a/b.toml; `tests/x.py::test_a', tests/x.py.
          (let ((word (replace-regexp-in-string
                       "::.*\\'" "" (car (last (split-string token "="))))))
            (when (and (string-match-p "[./]" word) (not (string-prefix-p "-" word)))
              (push (list word program (if (gethash word written) 'written 'argument))
                    words))))))
    (cons (delete-dups (nreverse words)) (delete-dups (nreverse programs)))))

(defun vigil-history--runs-p (programs)
  "Whether PROGRAMS, a command's, are more than ones that read files.
What a command of `grep -n' and `sed' prints names files and lines as an
error does, and says nothing of what ran."
  (cl-some (lambda (program)
             (not (member program vigil-history-reading-programs)))
           programs))

(defun vigil-history--mentions (text)
  "The files TEXT, what a command printed, names with a line: (NAME . LINE).
As a compiler names where an error is, or a traceback where it passed."
  (let (mentions (start 0) (count 0)
        (text (if (> (length text) 200000) (substring text 0 200000) text)))
    (while (and (< count 400)
                (string-match
                 "\\([A-Za-z0-9_~./-]*[A-Za-z0-9_-]\\.[A-Za-z0-9]+\\)\\(?::\\|\", line \\)\\([0-9]+\\)"
                 text start))
      (setq start (match-end 0))
      (cl-incf count)
      (push (cons (match-string 1 text) (string-to-number (match-string 2 text)))
            mentions))
    (delete-dups (nreverse mentions))))

(defun vigil-history--added (input response)
  "The lines an edit added, as text: of its INPUT and RESPONSE."
  (let ((patch (and (consp response) (alist-get 'structuredPatch response))))
    (cond
     ((consp patch)
      (let (lines)
        (dolist (hunk patch)
          (dolist (line (alist-get 'lines hunk))
            (when (and (stringp line) (string-prefix-p "+" line))
              (push (substring line 1) lines))))
        (nreverse lines)))
     ((stringp (alist-get 'content input))
      (split-string (alist-get 'content input) "\n"))
     ((stringp (alist-get 'new_string input))
      (split-string (alist-get 'new_string input) "\n"))
     ((consp (alist-get 'edits input))
      (cl-mapcan (lambda (edit)
                   (and (stringp (alist-get 'new_string edit))
                        (split-string (alist-get 'new_string edit) "\n")))
                 (alist-get 'edits input))))))

(defun vigil-history--removed (response)
  "How many lines an edit removed, as its RESPONSE's patch says."
  (let ((n 0))
    (dolist (hunk (and (consp response) (alist-get 'structuredPatch response)))
      (dolist (line (alist-get 'lines hunk))
        (when (and (stringp line) (string-prefix-p "-" line)) (cl-incf n))))
    n))

(defun vigil-history--take (state line)
  "Read LINE, one line of the archive as an alist, into STATE."
  (let* ((event (let ((event (alist-get 'event line)))
                  ;; pi's reports say the same things in pi's words.
                  (if (equal (alist-get 'agent event) "pi")
                      (vigil-pi-report event)
                    event)))
         (name (alist-get 'hook_event_name event))
         (tool (alist-get 'tool_name event))
         (time (alist-get 't line))
         (common (list :time (if (numberp time) time 0)
                       :session (alist-get 'session_id event)
                       :host (alist-get 'host line)
                       :prompt (alist-get 'prompt_id event))))
    (cond
     ((and (equal name "UserPromptSubmit") (stringp (alist-get 'prompt event))
           (null (alist-get 'agent_id event)))
      (push (append (list :text (alist-get 'prompt event)) common)
            (vigil-history--file-prompts state)))
     ((and (equal tool "Bash") (member name '("PreToolUse" "PostToolUse"))
           (stringp (alist-get 'tool_use_id event)))
      (let* ((id (alist-get 'tool_use_id event))
             (input (alist-get 'tool_input event))
             (response (alist-get 'tool_response event))
             (command (alist-get 'command input))
             (known (gethash id (vigil-history--file-commands state))))
        (when (stringp command)
          (unless known
            (push id (vigil-history--file-order state))
            (setq known (append (list :call id :command command
                                      :cwd (alist-get 'cwd event)
                                      :words (car (vigil-history--words command))
                                      :runs (vigil-history--runs-p
                                             (cdr (vigil-history--words command)))
                                      :status 'unanswered)
                                common))
            (puthash id known (vigil-history--file-commands state)))
          (when (equal name "PostToolUse")
            (setq known (plist-put known :status
                                   (cond ((and (consp response)
                                               (alist-get 'interrupted response))
                                          'interrupted)
                                         ;; pi reports a command that failed;
                                         ;; Claude Code reports nothing of one.
                                         ((and (consp response)
                                               (alist-get 'is_error response))
                                          'failed)
                                         (t 'done))))
            (setq known (plist-put known :ended (plist-get common :time)))
            (setq known
                  (plist-put known :mentions
                             (and (plist-get known :runs) (vigil-history--mentions
                              (cond ((stringp response) response)
                                    ((consp response)
                                     (concat (or (alist-get 'stdout response) "") "\n"
                                             (or (alist-get 'stderr response) "")))
                                    (t ""))))))
            (puthash id known (vigil-history--file-commands state))))))
     ((and (equal name "PostToolUse")
           (member tool '("Edit" "Write" "MultiEdit" "NotebookEdit")))
      (let* ((input (alist-get 'tool_input event))
             (response (alist-get 'tool_response event))
             (file (or (alist-get 'file_path input) (alist-get 'notebook_path input)))
             (cwd (alist-get 'cwd event)))
        (when (stringp file)
          ;; pi names a file from where it is working.
          (when (and (stringp cwd) (not (file-name-absolute-p file)))
            (setq file (expand-file-name file cwd)))
          (push (append (list :file file
                              :call (alist-get 'tool_use_id event)
                              :tool tool
                              :created (and (consp response)
                                            (equal (alist-get 'type response) "create"))
                              :added (vigil-history--added input response)
                              :removed (vigil-history--removed response))
                        common)
                (vigil-history--file-edits state))))))))

(defun vigil-history--load (file)
  "What was kept of FILE, a session's in the archive, or nil if nothing good.
A `vigil-history--file'."
  (let ((cache (vigil-history--cache-file file)))
    (when (file-readable-p cache)
      (ignore-errors
        (pcase (with-temp-buffer
                 (insert-file-contents cache)
                 (read (current-buffer)))
          (`(,(pred (equal vigil-history--version)) ,(pred (equal file))
             ,offset ,prompts ,edits ,commands)
           (let ((state (vigil-history--file-make :offset offset :prompts prompts
                                                  :edits edits)))
             ;; Newest first, as they are kept; so is the order.
             (dolist (command commands)
               (puthash (plist-get command :call) command
                        (vigil-history--file-commands state)))
             (setf (vigil-history--file-order state)
                   (mapcar (lambda (command) (plist-get command :call)) commands))
             state)))))))

(defun vigil-history--save (file state)
  "Keep STATE, what was read of FILE, to be read faster next time.
Whatever goes wrong, nothing is kept and nothing is said: it is a cache."
  (ignore-errors
    (let ((cache (vigil-history--cache-file file))
          (print-length nil) (print-level nil)
          (coding-system-for-write 'utf-8-emacs))
      (make-directory (file-name-directory cache) t)
      (with-temp-file cache
        (prin1 (list vigil-history--version file
                     (vigil-history--file-offset state)
                     (vigil-history--file-prompts state)
                     (vigil-history--file-edits state)
                     (mapcar (lambda (id)
                               (gethash id (vigil-history--file-commands state)))
                             (vigil-history--file-order state)))
               (current-buffer)))
      (set-file-modes cache #o600))))

(defun vigil-history--read (file)
  "What FILE, a session's in the archive, says: a `vigil-history--file'.
Only what was written to it since it was last read is read: in this Emacs,
or in one before it, which kept what it read."
  (let* ((state (or (gethash file vigil-history--files)
                    (puthash file (or (vigil-history--load file)
                                      (vigil-history--file-make))
                             vigil-history--files)))
         (size (or (file-attribute-size (file-attributes file)) 0))
         (before (vigil-history--file-offset state)))
    (when (< size (vigil-history--file-offset state))
      ;; Not the file it was: read it afresh.
      (setq state (puthash file (vigil-history--file-make) vigil-history--files)
            before 0))
    (when (> size (vigil-history--file-offset state))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (let ((coding-system-for-read 'binary))
          (insert-file-contents-literally file nil (vigil-history--file-offset state) size))
        (goto-char (point-min))
        (let ((case-fold-search nil) (last (point-min)))
          (while (search-forward "\n" nil t)
            (let ((beg last) (end (1- (point))))
              (setq last (point))
              (goto-char beg)
              (when (re-search-forward vigil-history--wanted end t)
                (goto-char beg)
                (when-let* ((line (ignore-errors (vigil-base-json-read))))
                  (ignore-errors (vigil-history--take state line))))
              (goto-char last)))
          ;; A last line with no newline yet is still being written.
          (cl-incf (vigil-history--file-offset state) (1- last))))
      ;; Kept once enough is new that reading it again would be felt.
      (when (>= (- (vigil-history--file-offset state) before) (* 256 1024))
        (vigil-history--save file state)))
    state))

;;;; A repository's history

(cl-defstruct (vigil-history (:constructor vigil-history--make) (:copier nil)
                          (:conc-name vigil-history--))
  "What the archive says agents did to one repository."
  root
  (prompts (make-hash-table :test #'equal)
           :documentation "Its prompts by their ids: plists.")
  (edits (make-hash-table :test #'equal)
         :documentation "The edits to each file, by its name in the repository;
newest first.")
  (runs (make-hash-table :test #'equal)
        :documentation "The commands that exercised each file, likewise: each
(COMMAND HOW . DETAIL), HOW being `named', `mentioned' or `ran'.")
  (writes (make-hash-table :test #'equal)
          :documentation "The commands that seem to have written each file,
likewise: plists.")
  (commands nil :documentation "Every command, newest first: plists."))

(defun vigil-history--sessions (root)
  "The files of the archived sessions that worked in ROOT, under it or over it."
  (let* ((archive (vigil-history--archive))
         (index (expand-file-name "index.jsonl" archive))
         (root (file-name-as-directory (expand-file-name root)))
         files)
    (when (file-readable-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((entry (vigil-base-json-string
                              (buffer-substring (point) (line-end-position))))
                      (cwd (alist-get 'cwd entry))
                      ((stringp cwd))
                      (cwd (file-name-as-directory (expand-file-name cwd)))
                      ((or (string-prefix-p root cwd) (string-prefix-p cwd root)))
                      (name (alist-get 'file entry))
                      ((stringp name))
                      (file (expand-file-name name archive))
                      ((file-readable-p file)))
            (push file files))
          (forward-line 1))))
    (delete-dups (nreverse files))))

(defun vigil-history--relative (name root &optional cwd)
  "NAME as a file of the repository at ROOT, or nil if it is not under it.
Relative names are read against CWD, where that is known, and against ROOT."
  (let ((try (lambda (directory)
               (let ((file (expand-file-name name directory)))
                 (and (string-prefix-p root file)
                      (substring file (length root)))))))
    (if (file-name-absolute-p name)
        (funcall try root)
      (or (and (stringp cwd) (funcall try cwd))
          (funcall try root)))))

(defun vigil-history--exercise (history command files)
  "Note in HISTORY the files COMMAND exercised, among FILES.
FILES is a hash table of the repository's files by name, or nil where they
are not known: then whatever is named under its root."
  (let* ((root (vigil-history--root history))
         (cwd (plist-get command :cwd))
         (seen (make-hash-table :test #'equal))
         (note (lambda (name how detail)
                 (when-let* ((file (ignore-errors
                                     (vigil-history--relative name root cwd)))
                             ((not (string-empty-p file)))
                             ((if files (gethash file files) t))
                             ((not (gethash file seen))))
                   (puthash file t seen)
                   (push (cons command (cons how detail))
                         (gethash file (vigil-history--runs history)))))))
    (pcase-dolist (`(,word ,program ,how) (plist-get command :words))
      (if (eq how 'written)
          (when-let* ((file (ignore-errors (vigil-history--relative word root cwd)))
                      ((not (string-empty-p file)))
                      ((if files (gethash file files) t))
                      ((not (memq command (gethash file (vigil-history--writes history))))))
            (push command (gethash file (vigil-history--writes history))))
        (unless (member program vigil-history-reading-programs)
          (funcall note word 'named nil))))
    (pcase-dolist (`(,name . ,line) (plist-get command :mentions))
      (funcall note name 'mentioned line))))

(defvar vigil-history--known (make-hash-table :test #'equal)
  "The history last made of each repository, by its root: (STATE . HISTORY).
STATE is what it was made from: nothing is read again until that changes.")

(defun vigil-history--state (root sessions files)
  "What a history of ROOT is made from: SESSIONS' sizes, how many FILES, and
when the code commands ran was last added to."
  (list (mapcar (lambda (file) (file-attribute-size (file-attributes file))) sessions)
        sessions
        (length files) (car files) (car (last files))
        (let ((directory (vigil-history--coverage)))
          (and (file-directory-p directory)
               (mapcar (lambda (entry)
                         (file-attribute-modification-time (cdr entry)))
                       (directory-files-and-attributes directory nil "\\`[^.]" t))))
        root))

(defun vigil-history (root &optional files)
  "What the archive says agents did to the repository at ROOT.
A `vigil-history'.  FILES, a list of the repository's files by name, keeps
a command from being taken to exercise what is not one of them.  The one
made last is given again while the archive has nothing new."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (sessions (vigil-history--sessions root))
         (state (vigil-history--state root sessions files))
         (known (gethash root vigil-history--known)))
    (if (and known (equal (car known) state))
        (cdr known)
      (cdr (puthash root (cons state (vigil-history--build root sessions files))
                    vigil-history--known)))))

(defun vigil-history--build (root sessions files)
  "The history of the repository at ROOT, from SESSIONS.
FILES as for `vigil-history'."
  (let* ((history (vigil-history--make :root root))
         (known (and files
                     (let ((table (make-hash-table :test #'equal)))
                       (dolist (file files) (puthash file t table))
                       table)))
         (commands nil))
    (dolist (file sessions)
      (let ((state (vigil-history--read file)))
        (dolist (prompt (vigil-history--file-prompts state))
          (when (plist-get prompt :prompt)
            (puthash (plist-get prompt :prompt) prompt (vigil-history--prompts history))))
        (dolist (edit (reverse (vigil-history--file-edits state)))
          (when-let* ((name (vigil-history--relative (plist-get edit :file) root)))
            (push edit (gethash name (vigil-history--edits history)))))
        (dolist (id (vigil-history--file-order state))
          (push (gethash id (vigil-history--file-commands state)) commands))))
    (setq commands (sort commands (lambda (a b) (> (plist-get a :time)
                                                   (plist-get b :time)))))
    (setf (vigil-history--commands history) commands)
    ;; Oldest first, so that each file's list ends newest first.
    (dolist (command (reverse commands))
      (vigil-history--exercise history command known))
    (vigil-history--take-coverage history)
    (maphash (lambda (name edits)
               (puthash name (sort edits (lambda (a b) (> (plist-get a :time)
                                                         (plist-get b :time))))
                        (vigil-history--edits history)))
             (vigil-history--edits history))
    history))

;;;; The code commands ran

(defun vigil-history--file-text (file)
  "What FILE says, as text, or nil if it cannot be read."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun vigil-history--take-coverage (history)
  "Note in HISTORY the files whose code commands ran, as their programs said.
Under the coverage directory each session has a directory, and in it each
command that ran a Python or a Node program of the project has one, named
for when it began: command.txt and cwd.txt say which command it was, and
beside them each program left the functions it ran, by file (coverage/,
bin/vigil-shell)."
  (let ((root (vigil-history--root history))
        (directory (vigil-history--coverage))
        (by-text (make-hash-table :test #'equal)))
    (when (file-directory-p directory)
      (dolist (command (vigil-history--commands history))
        (let ((text (plist-get command :command)))
          ;; As much of it as vigil-shell keeps.
          (push command (gethash (substring text 0 (min 4096 (length text))) by-text))))
      (dolist (session (directory-files directory t "\\`[^.]"))
        (dolist (run (and (file-directory-p session)
                          (directory-files session t "\\`[0-9]+-[0-9]+\\'")))
          (when-let* ((cwd (vigil-history--file-text (expand-file-name "cwd.txt" run)))
                      ((let ((cwd (file-name-as-directory (file-truename cwd))))
                         (or (string-prefix-p root cwd) (string-prefix-p cwd root)
                             (string-prefix-p (file-truename root) cwd))))
                      (text (vigil-history--file-text
                             (expand-file-name "command.txt" run)))
                      (started (string-to-number (file-name-nondirectory run))))
            (let ((ran (make-hash-table :test #'equal))
                  ;; The command of the archive this run was, by its text
                  ;; and when it began; else one known only from here.
                  (command (or (cl-find-if
                                (lambda (command)
                                  (< (abs (- (plist-get command :time) started)) 10))
                                (gethash text by-text))
                               (list :command text :cwd cwd :time started :status 'done
                                     :host (file-name-nondirectory session)))))
              (dolist (file (directory-files run t "\\`\\(?:python\\|node\\)-.*\\.json\\'"))
                (pcase-dolist (`(,name . ,functions)
                               (alist-get 'files (vigil-base-json-file file)))
                  (when-let* ((name (if (symbolp name) (symbol-name name) name))
                              (name (or (vigil-history--relative name root)
                                        (vigil-history--relative
                                         name (file-name-as-directory
                                               (file-truename root))))))
                    (puthash name (append functions (gethash name ran)) ran))))
              (maphash
               (lambda (name functions)
                 (let ((runs (cl-remove-if (lambda (entry) (eq (car entry) command))
                                           (gethash name (vigil-history--runs history)))))
                   ;; That its code ran says more than that it was named.
                   (puthash name
                            (sort (cons (cons command
                                              (cons 'ran (sort (delete-dups functions)
                                                               #'string<)))
                                        runs)
                                  (lambda (a b) (> (plist-get (car a) :time)
                                                   (plist-get (car b) :time))))
                            (vigil-history--runs history))))
               ran))))))))

;;;; Asking it

(defun vigil-history-edits (history file)
  "The edits agents made to FILE of HISTORY's repository, newest first."
  (gethash file (vigil-history--edits history)))

(defun vigil-history-runs (history file)
  "The commands that exercised FILE of HISTORY's repository, newest first.
Each (COMMAND HOW . DETAIL): COMMAND a plist with :command, :time, :status
\(`done', `interrupted', `failed', or `unanswered' for one that never ended
or that failed with nothing said of it), :prompt and :session; HOW is
`named' (the command names the file),
`mentioned' (what it printed does, at the line DETAIL) or `ran' (it ran
the functions DETAIL of it)."
  (gethash file (vigil-history--runs history)))

(defun vigil-history-commands (history)
  "Every command run in HISTORY's repository, newest first: plists."
  (vigil-history--commands history))

(defun vigil-history-prompt (history id)
  "The prompt ID of HISTORY: a plist with :text, :time, :session and :host."
  (and id (gethash id (vigil-history--prompts history))))

(defun vigil-history-writes (history file)
  "The commands that seem to have written FILE, newest first: plists.
Ones that redirect to it, or were handed a program or a text that names
it: an agent that changes files with a script and not with its editing
tools leaves no edit, and this is what there is of it."
  (gethash file (vigil-history--writes history)))

(defun vigil-history-prompt-edits (history id)
  "The edits that followed the prompt ID of HISTORY, oldest first.
Each (FILE . EDIT), FILE by its name in the repository."
  (let (found)
    (maphash (lambda (file edits)
               (dolist (edit edits)
                 (when (equal (plist-get edit :prompt) id)
                   (push (cons file edit) found))))
             (vigil-history--edits history))
    (sort found (lambda (a b) (< (plist-get (cdr a) :time) (plist-get (cdr b) :time))))))

(defun vigil-history-prompt-writes (history id)
  "The commands after the prompt ID of HISTORY that seem to have written files.
Each (FILE . COMMAND), oldest first; see `vigil-history-writes'."
  (let (found)
    (maphash (lambda (file commands)
               (dolist (command commands)
                 (when (equal (plist-get command :prompt) id)
                   (push (cons file command) found))))
             (vigil-history--writes history))
    (sort found (lambda (a b) (< (plist-get (cdr a) :time) (plist-get (cdr b) :time))))))

(defun vigil-history-prompts-of (history file)
  "The prompts that led to changes of FILE, newest first: (PROMPT EDITS WRITES).
EDITS is how many edits of it followed PROMPT, and WRITES how many commands
that seem to have written it.  PROMPT is nil where the prompt is not kept."
  (let (found)
    (dolist (item (sort (append (mapcar (lambda (edit) (cons 'edit edit))
                                        (vigil-history-edits history file))
                                (mapcar (lambda (command) (cons 'write command))
                                        (vigil-history-writes history file)))
                        (lambda (a b) (> (plist-get (cdr a) :time)
                                         (plist-get (cdr b) :time)))))
      (let* ((prompt (vigil-history-prompt history (plist-get (cdr item) :prompt)))
             (entry (or (assq prompt found)
                        (car (push (list prompt 0 0) found)))))
        (if (eq (car item) 'edit)
            (cl-incf (nth 1 entry))
          (cl-incf (nth 2 entry)))))
    (nreverse found)))

(defun vigil-history-prompts-between (history from to)
  "The prompts given in HISTORY's repository from FROM to TO, oldest first.
Times in seconds.  What was asked while a commit was being made, where no
edit says which prompt its lines are from."
  (let (found)
    (maphash (lambda (_id prompt)
               (when (<= from (plist-get prompt :time) to)
                 (push prompt found)))
             (vigil-history--prompts history))
    (sort found (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

(defun vigil-history--telling-p (line)
  "Whether LINE, of a file, says enough to tell who wrote it by.
A brace alone or a blank line is in every edit."
  (>= (length (string-trim line)) 6))

(defun vigil-history-origin (history file lines)
  "The edits to FILE that wrote LINES, by their text: ((EDIT . COUNT)...).
Most lines first, and of two edits that wrote the same line the later one.
Lines that say too little to tell by are not counted."
  (let ((wanted (make-hash-table :test #'equal))
        found)
    (dolist (line lines)
      (when (vigil-history--telling-p line)
        (puthash (string-trim line) t wanted)))
    ;; Newest first: a line is given to the last edit that wrote it.
    (dolist (edit (vigil-history-edits history file))
      (let ((count 0))
        (dolist (line (plist-get edit :added))
          (let ((line (string-trim line)))
            (when (gethash line wanted)
              (remhash line wanted)
              (cl-incf count))))
        (when (> count 0) (push (cons edit count) found))))
    (sort found (lambda (a b) (> (cdr a) (cdr b))))))

(provide 'vigil-history)
;;; vigil-history.el ends here
