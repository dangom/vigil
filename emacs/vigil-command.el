;;; vigil-command.el --- A shell command, untangled and explained -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; Agents write shell the way nobody reads it: five commands chained with
;; `&&' and `|' on one line, a Python program in the double-quoted argument
;; of `python3 -c', a file's contents in a heredoc.  This lays such a command
;; out to be read, and says what its programs and options are.
;;
;; - `vigil-command-tidy': the command parsed by shfmt, a real parser for
;;   the shell's language (`--to-json'), and printed again by it with each
;;   long chain broken before its operators.  The programs inside it -- the
;;   argument of `python3 -c', `node -e', `osascript -e', `emacs --eval',
;;   `bash -c', the heredoc fed to an
;;   interpreter or written to a file -- are taken out to blocks of their
;;   own, highlighted in their language, and marked where they were by a
;;   numbered placeholder, and laid out by its formatter (ruff for Python,
;;   prettier for JavaScript, Emacs's own `pp' for Emacs Lisp, see `vigil-command-formatters'), whether the command runs it or writes
;;   it to a file; showing the command as given shows it as written.
;; - `vigil-command-explain': each program the command runs, and each option
;;   it gives one, with what the program's manual says of it: bash's own
;;   `help' for a builtin, `man' for the rest.  Only manuals on this machine.
;;
;; Both work on the command as text.  shfmt and the formatters are given it on their
;; standard input, to parse and print; nothing in it is run, and a command
;; either cannot parse is shown as it was given.  Without shfmt, nothing here
;; does anything.  `man' and `help' are only given names that are names: no
;; paths, nothing starting with a dash.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'subr-x)
(require 'vigil-base)
(require 'ansi-color)

(defgroup vigil-command nil
  "Shell commands an agent ran, laid out and explained."
  :group 'vigil)

(defcustom vigil-command-shfmt "shfmt"
  "The shfmt program, which parses and prints the shell's language.
Without it commands are shown as they were given."
  :type 'string)

(defcustom vigil-command-width 60
  "A chain of commands longer than this is broken before its operators.
Its length counted without the programs taken out of it."
  :type 'integer)

(defcustom vigil-command-interpreters
  '(("\\`python[0-9.]*\\'" "c" python-mode)
    ("\\`pypy[0-9.]*\\'" "c" python-mode)
    ("\\`\\(?:ba\\|z\\|da\\|k\\)?sh\\'" "c" sh-mode)
    ("\\`\\(?:node\\|bun\\)\\'" "e" js-mode)
    ("\\`ruby\\'" "e" ruby-mode)
    ("\\`perl\\'" "e" perl-mode)
    ("\\`osascript\\'" "e" applescript-mode ("l" ("JavaScript" . js-mode)))
    ("\\`emacs\\(?:-[0-9.]+\\)?\\'" ("eval" "execute") emacs-lisp-mode)
    ("\\`emacsclient\\'" ("e" "eval") emacs-lisp-mode))
  "Programs that run a program given to them: (NAME-REGEXP FLAG MODE [LANGUAGES]).
FLAG is the letter of the option whose argument is the program, as in
`python3 -c CODE'; it may end a cluster of letters, as in `perl -ne CODE'.
A FLAG of more letters is a long option, as in `emacs --eval CODE', with one
hyphen or two; a list of FLAGs is any of them.  An option given more than
once gives a program each time.  A heredoc on the interpreter's standard
input is its program too.  MODE
highlights the program and picks its formatter in `vigil-command-formatters'.
LANGUAGES, (LETTER (NAME . MODE)...), is for a program whose language is
named by an option, as in `osascript -l JavaScript': the option of LETTER
naming NAME, in any case, gives MODE in place of the one before it."
  :type '(repeat (list regexp (choice string (repeat string)) function
                       (choice (const nil)
                               (cons string (alist :key-type string
                                                   :value-type function))))))

(defcustom vigil-command-wrappers
  '("env" "uv" "uvx" "run" "poetry" "pipx" "pdm" "hatch" "rye" "timeout"
    "nice" "nohup" "time" "exec" "command" "sudo" "caffeinate")
  "Programs that run the program after them, looked past for an interpreter.
With their options and numbers, and variable assignments, as in
`timeout 60 uv run python3 -c CODE'."
  :type '(repeat string))

(defcustom vigil-command-formatters
  '((python-mode "ruff" "format" "--isolated" "--stdin-filename" "vigil.py" "-")
    (sh-mode "shfmt" "-i" "2" "-ci" "-sr" "-bn")
    (js-mode "prettier" "--stdin-filepath" "vigil.js")
    (emacs-lisp-mode vigil-command-format-elisp))
  "Formatters for the programs a command runs: (MODE PROGRAM ARGS...).
PROGRAM reads the program on its standard input and prints it laid out;
where it is missing or fails, the program is shown as given.  Or
\(MODE FUNCTION): FUNCTION is given the program and returns it laid out,
or nil to show it as given."
  :type '(repeat (cons function (choice (list function) (repeat string)))))

(defcustom vigil-command-subcommands
  '("git" "cargo" "npm" "pnpm" "yarn" "docker" "podman" "kubectl" "uv" "gh"
    "go" "brew" "pip" "pip3" "jj" "systemctl" "apt" "nix" "launchctl")
  "Programs whose first word is a command with a manual of its own.
`git log' is explained from git-log(1)."
  :type '(repeat string))

(defface vigil-command-placeholder
  '((t :inherit font-lock-constant-face :weight bold))
  "A program taken out of a command, where it was.")

(defface vigil-command-heading
  '((t :inherit shadow))
  "The heading of a program taken out of a command.")

(defface vigil-command-program
  '((t :inherit font-lock-function-name-face :weight bold))
  "A program, in the explanation of a command.")

(defface vigil-command-option
  '((t :inherit font-lock-builtin-face))
  "An option, in the explanation of a command.")

;;;; Running a filter

(defun vigil-command--filter (program args input)
  "INPUT through PROGRAM with ARGS: what it prints.
Nil if PROGRAM is missing or fails."
  (when-let* ((exe (executable-find program)))
    (with-temp-buffer
      (insert input)
      (let ((default-directory temporary-file-directory)
            (coding-system-for-read 'utf-8)
            (coding-system-for-write 'utf-8))
        (and (eq 0 (apply #'call-process-region (point-min) (point-max) exe
                          t '(t nil) nil args))
             (buffer-string))))))

(defun vigil-command-fontify (text mode)
  "TEXT with the faces MODE's font lock gives it; TEXT as it is without MODE."
  (if (not (and mode (fboundp mode)))
      text
    (with-temp-buffer
      (insert text)
      ;; Quietly: some modes say how they set themselves up.
      (let ((inhibit-message t) (message-log-max nil))
        (delay-mode-hooks (funcall mode)))
      (ignore-errors (font-lock-ensure))
      (buffer-string))))

(defconst vigil-command-remembered 256
  "How many results a table of them holds before it is begun again.")

(defun vigil-command-remember (table key make)
  "What MAKE gives for KEY, worked out once and kept in TABLE.
MAKE is called with nothing.  What it gives is kept even when it is nil: a
command that could not be parsed is not parsed again.  A table that has
grown to `vigil-command-remembered' is emptied first."
  (let ((known (gethash key table table)))
    ;; The table itself stands for nothing kept: no value is ever it.
    (if (not (eq known table))
        known
      (when (>= (hash-table-count table) vigil-command-remembered)
        (clrhash table))
      (puthash key (funcall make) table))))

;;;; The parse

(defun vigil-command--parse (command)
  "COMMAND's syntax tree as shfmt gives it, as alists; nil if it is not shell."
  (when-let* ((json (vigil-command--filter vigil-command-shfmt
                                           '("-ln" "bash" "--to-json") command)))
    (vigil-base-json-string json)))

(defun vigil-command--node-p (value)
  "Whether VALUE is a node of the tree, rather than a list of them."
  (and (consp value) (consp (car value)) (symbolp (caar value))))

(defun vigil-command--beg (node) (alist-get 'Offset (alist-get 'Pos node)))
(defun vigil-command--end (node) (alist-get 'Offset (alist-get 'End node)))

(defun vigil-command--walk (node function)
  "Call FUNCTION on NODE and every node under it, parents first.
FUNCTION returning `skip' leaves the nodes under that one out."
  (when (and (vigil-command--node-p node)
             (not (assq 'Offset node))
             (not (eq (funcall function node) 'skip)))
    (dolist (pair node)
      (let ((value (cdr pair)))
        (cond ((vigil-command--node-p value) (vigil-command--walk value function))
              ((and (consp value) (vigil-command--node-p (car value)))
               (dolist (child value) (vigil-command--walk child function))))))))

(defun vigil-command--slice (source beg end)
  "The text between the byte offsets BEG and END of SOURCE, its UTF-8 bytes."
  (decode-coding-string (substring source beg end) 'utf-8))

(defun vigil-command--unescape (text chars)
  "TEXT with its backslashes taken away as the shell does.
Before a newline, the backslash and newline go; before one of CHARS (a
regexp character class), the backslash; any other stays."
  (replace-regexp-in-string
   (concat "\\\\\\(\n\\|" chars "\\)")
   (lambda (match) (if (equal match "\\\n") "" (substring match 1)))
   text t t))

(defun vigil-command--word (word source &optional raw)
  "WORD's value, as the shell would make it, from SOURCE.
Where that takes an expansion, nil; with RAW, the expansion as written."
  (catch 'expands
    (let ((raw-part (lambda (part)
                      (if raw
                          (vigil-command--slice source (vigil-command--beg part)
                                                (vigil-command--end part))
                        (throw 'expands nil)))))
      (mapconcat
       (lambda (part)
         (pcase (alist-get 'Type part)
           ("Lit" (vigil-command--unescape (alist-get 'Value part) "[^\n]"))
           ("SglQuoted" (if (alist-get 'Dollar part)
                            (funcall raw-part part)
                          (alist-get 'Value part)))
           ("DblQuoted"
            (mapconcat (lambda (inner)
                         (if (equal (alist-get 'Type inner) "Lit")
                             (vigil-command--unescape (alist-get 'Value inner)
                                                      "[$`\"\\\\]")
                           (funcall raw-part inner)))
                       (alist-get 'Parts part) ""))
           (_ (funcall raw-part part))))
       (alist-get 'Parts word) ""))))

(defun vigil-command--args (call source)
  "The words of the command CALL, a CallExpr, as (WORD . VALUE) from SOURCE."
  (mapcar (lambda (word) (cons word (vigil-command--word word source)))
          (alist-get 'Args call)))

(defun vigil-command--interpreter (args)
  "Where in ARGS, a command's words, an interpreter is: (INDEX . ENTRY).
ENTRY is its `vigil-command-interpreters' entry.  The program itself, or
the first program after `vigil-command-wrappers' and their options."
  (let ((index 0) found)
    (while (and (not found) (< index (min (length args) 8)))
      (let* ((value (cdr (nth index args)))
             (name (and value (file-name-nondirectory value)))
             (entry (and name (cl-find-if (lambda (entry)
                                            (string-match-p (car entry) name))
                                          vigil-command-interpreters))))
        (cond (entry (setq found (cons index entry)))
              ((and value
                    (or (member name vigil-command-wrappers)
                        (and (> index 0)
                             (string-match-p "\\`\\(?:-.*\\|[0-9.]+[smhd]?\\|[A-Za-z_][A-Za-z0-9_]*=.*\\)\\'"
                                             value))))
               (cl-incf index))
              (t (setq index (length args))))))
    found))

(defun vigil-command--flag-regexp (flag)
  "A regexp matching the option FLAG, of a `vigil-command-interpreters' entry."
  (format "\\`\\(?:%s\\)\\'"
          (mapconcat (lambda (name)
                       (format (if (= (length name) 1) "-[A-Za-z]*%s" "--?%s")
                               (regexp-quote name)))
                     (ensure-list flag) "\\|")))

(defun vigil-command--interpreter-mode (interpreter args)
  "The mode of the program INTERPRETER, from `vigil-command--interpreter', runs.
Its entry's MODE, unless an option among ARGS after it names another language."
  (let* ((mode (nth 2 (cdr interpreter)))
         (languages (nth 3 (cdr interpreter)))
         (option (and languages
                      (format "\\`-%s\\(.*\\)\\'" (regexp-quote (car languages)))))
         (rest (nthcdr (1+ (car interpreter)) args))
         (name (and option
                    (cl-loop for (arg next) on rest
                             for value = (cdr arg)
                             when (and value (string-match option value))
                             return (let ((attached (match-string 1 value)))
                                      (if (string-empty-p attached)
                                          (cdr next)
                                        attached))))))
    (or (and name (cdr (assoc-string name (cdr languages) t)))
        mode)))

(defun vigil-command--dedent (text)
  "TEXT without the blank lines around it and the indentation all its lines share."
  (let* ((text (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+\\|\\s-+\\'" "" text))
         (lines (split-string text "\n"))
         (indent (cl-loop for line in lines
                          unless (string-blank-p line)
                          minimize (- (length line)
                                      (length (string-trim-left line "[ \t]+"))))))
    (if (and indent (> indent 0))
        (mapconcat (lambda (line) (if (string-blank-p line) "" (substring line indent)))
                   lines "\n")
      text)))

(defun vigil-command--mode-for-file (file)
  "The major mode FILE would be visited in, if it has one by its name."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (and (symbolp mode) (fboundp mode) mode)))

(defun vigil-command--scripts (tree source)
  "The programs and texts inside the command TREE, in SOURCE, to take out.
Each a plist: :beg and :end, the bytes it stands in; :token, whether it
stands where a word was (else it is a heredoc's lines); :code, :mode,
:run (whether the command runs it) and :label."
  (let (scripts)
    (vigil-command--walk
     tree
     (lambda (node)
       (when (assq 'Cmd node)               ; a statement
         (let* ((cmd (alist-get 'Cmd node))
                (args (and (equal (alist-get 'Type cmd) "CallExpr")
                           (vigil-command--args cmd source)))
                (interpreter (and args (vigil-command--interpreter args)))
                (taken nil))
           ;; The argument of `python3 -c' and its like.
           (when interpreter
             (let* ((flag (vigil-command--flag-regexp (nth 1 (cdr interpreter))))
                    (rest (nthcdr (1+ (car interpreter)) args)))
               ;; Every time the option is given: `emacs --eval A --eval B'.
               (while (cdr rest)
                 (if (not (and (cdr (car rest)) (string-match-p flag (cdr (car rest)))))
                     (pop rest)
                   (let ((word (car (cadr rest))))
                     (setq taken t)
                     (push (list :beg (vigil-command--beg word)
                                 :end (vigil-command--end word)
                                 :token t
                                 :code (vigil-command--word word source t)
                                 :mode (vigil-command--interpreter-mode interpreter args)
                                 :run t
                                 :label (format "%s %s"
                                                (file-name-nondirectory
                                                 (cdr (nth (car interpreter) args)))
                                                (cdr (car rest))))
                           scripts))
                   (setq rest (cddr rest))))))
           ;; Heredocs: an interpreter's program, or what is written to a file.
           (dolist (redirect (alist-get 'Redirs node))
             (when-let* ((hdoc (alist-get 'Hdoc redirect))
                         (beg (vigil-command--beg hdoc))
                         (body (substring source beg (vigil-command--end hdoc)))
                         (last (string-match-p "\n[^\n]*\\'" body)))
               (let* ((file (cl-some
                             (lambda (other)
                               (and (member (alist-get 'Op other) '(">" ">>" ">|" "&>"))
                                    (vigil-command--word (alist-get 'Word other) source)))
                             (alist-get 'Redirs node)))
                      (file (or file
                                (and args (equal (cdr (car args)) "tee")
                                     (cl-some (lambda (arg)
                                                (and (cdr arg)
                                                     (not (string-prefix-p "-" (cdr arg)))
                                                     (cdr arg)))
                                              (cdr args)))))
                      (run (and interpreter (not taken) (not file))))
                 (push (list :beg beg :end (+ beg last 1) :token nil
                             :code (vigil-command--slice source beg (+ beg last 1))
                             :mode (cond (run (vigil-command--interpreter-mode interpreter args))
                                         (file (vigil-command--mode-for-file file)))
                             :run run
                             :label (cond (run (format "%s, from its standard input"
                                                       (cdr (nth (car interpreter) args))))
                                          (file (format "written to %s" file))
                                          (t "heredoc")))
                       scripts))))))
       nil))
    (sort scripts (lambda (a b) (< (plist-get a :beg) (plist-get b :beg))))))

(defun vigil-command--inside-p (offset scripts)
  "Whether the byte OFFSET is inside one of SCRIPTS."
  (cl-some (lambda (script) (and (>= offset (plist-get script :beg))
                                 (< offset (plist-get script :end))))
           scripts))

(defun vigil-command--class (node)
  "The kind of chain the command NODE is a link of: `and', `pipe' or nil."
  (and (equal (alist-get 'Type node) "BinaryCmd")
       (pcase (alist-get 'Op node)
         ((or "&&" "||") 'and)
         ((or "|" "|&") 'pipe))))

(defun vigil-command--breaks (tree source scripts)
  "The byte offsets of SOURCE, the command TREE, to break a line before.
Before every operator of a chain longer than `vigil-command-width', not
counting the SCRIPTS taken out of it, and not already starting a line."
  (let (breaks)
    (vigil-command--walk
     tree
     (lambda (node)
       (when-let* ((class (vigil-command--class node)))
         (let ((ops nil))
           ;; The whole chain: `a && b || c' is one, `a | b' inside it another.
           (cl-labels ((flatten (cmd)
                         (cl-pushnew (alist-get 'Offset (alist-get 'OpPos cmd)) ops)
                         (dolist (side (list (alist-get 'X cmd) (alist-get 'Y cmd)))
                           (let ((inner (alist-get 'Cmd side)))
                             (when (and (eq (vigil-command--class inner) class)
                                        (not (alist-get 'Redirs side))
                                        (not (alist-get 'Negated side))
                                        (not (alist-get 'Background side)))
                               (flatten inner))))))
             (flatten node))
           (let* ((beg (vigil-command--beg node))
                  (end (vigil-command--end node))
                  (length (- end beg)))
             (dolist (script scripts)
               (when (and (>= (plist-get script :beg) beg) (<= (plist-get script :end) end))
                 (cl-decf length (- (plist-get script :end) (plist-get script :beg) 4))))
             (when (> length vigil-command-width)
               (dolist (op ops)
                 (unless (or (vigil-command--inside-p op scripts)
                             (string-match-p "\n[ \t]*\\'" (substring source beg op)))
                   (push op breaks)))))))
       nil))
    breaks))

(defun vigil-command--edit (source edits)
  "SOURCE with EDITS made: each (BEG END TEXT), not overlapping."
  (let ((pieces nil) (at (length source)))
    (dolist (edit (sort (copy-sequence edits) (lambda (a b) (> (car a) (car b)))))
      (push (substring source (nth 1 edit) at) pieces)
      (push (encode-coding-string (nth 2 edit) 'utf-8) pieces)
      (setq at (car edit)))
    (decode-coding-string (apply #'concat (substring source 0 at) pieces) 'utf-8)))

(defun vigil-command--format-script (script)
  "SCRIPT's code, laid out by its formatter, highlighted.
A program written to a file is laid out as well: what it says, not where its
lines break, is what there is to read; `t' shows the command as given."
  (let* ((code (plist-get script :code))
         (mode (plist-get script :mode))
         (code (if (plist-get script :run) (vigil-command--dedent code) code))
         (formatter (alist-get mode vigil-command-formatters))
         (formatted (cond ((null formatter) nil)
                          ((stringp (car formatter))
                           (vigil-command--filter (car formatter) (cdr formatter) code))
                          (t (ignore-errors (funcall (car formatter) code))))))
    (vigil-command-fontify (string-trim-right (or formatted code)) mode)))

(defun vigil-command--elisp-forms (text)
  "The forms TEXT reads as, Emacs Lisp; nil where it is not to be printed again.
That is where it does not read, and where printing what it reads as would
not say what it says: a comment would be lost, and a character, `?a',
come out as a number."
  (with-temp-buffer
    (with-syntax-table emacs-lisp-mode-syntax-table
      (insert text)
      (goto-char (point-min))
      (unless (cl-loop while (re-search-forward "[;?]" nil t)
                       for state = (save-excursion (syntax-ppss))
                       thereis (or (nth 4 state) (not (nth 3 state))))
        (goto-char (point-min))
        (ignore-errors
          (let (forms)
            (while (progn (skip-chars-forward " \t\n\r\f") (not (eobp)))
              (push (read (current-buffer)) forms))
            (nreverse forms)))))))

(defun vigil-command-format-elisp (code)
  "CODE, Emacs Lisp, laid out by `pp-emacs-lisp-code'; nil to show it as given.
Emacs's own, so nothing to install.  It prints what CODE reads as, which
is shown only where it reads back as the same forms, and CODE has
nothing printing would lose (`vigil-command--elisp-forms')."
  (when-let* (((fboundp 'pp-emacs-lisp-code))
              (forms (vigil-command--elisp-forms code)))
    (with-temp-buffer
      (let ((indent-tabs-mode nil)
            (pp-max-width vigil-command-width))
        ;; It would print 80 as ?P: a number is a number here.  And it fails
        ;; on some forms.
        (cl-letf (((symbol-function 'prin1-char) #'number-to-string))
          (ignore-errors
            (dolist (form forms)
              (pp-emacs-lisp-code form)
              (unless (bolp) (insert "\n")))
            (let ((laid-out (string-trim-right (buffer-string))))
              (and (equal forms (vigil-command--elisp-forms laid-out))
                   laid-out))))))))

(defvar vigil-command--tidied (make-hash-table :test #'equal)
  "Commands tidied, by their text.")

(defun vigil-command-tidy (command)
  "COMMAND laid out to be read, or nil without shfmt or where it is not shell.
A plist: :shell, the command highlighted as shell, its long chains broken
and the programs inside it replaced by numbered placeholders; :blocks,
those programs, as (LABEL . TEXT), each highlighted in its language."
  (when (and (stringp command) (executable-find vigil-command-shfmt))
    (vigil-command-remember vigil-command--tidied command
                            (lambda () (vigil-command--tidy command)))))

;;;; On one line

(defun vigil-command--string-p (pos)
  "Whether POS is inside a string, by the faces font lock gave it."
  (let ((face (get-text-property pos 'face)))
    (memq 'font-lock-string-face (ensure-list face))))

(defun vigil-command-line (command)
  "COMMAND on one line, to be listed, or nil where `vigil-command-tidy' is.
Laid out as that lays it out and highlighted: the programs inside it are
their placeholders, a heredoc is its placeholder after its `<<', and the
lines are joined as the shell would read them.  A line break inside a
quoted string is shown as one."
  (when-let* ((tidy (vigil-command-tidy command)))
    (with-temp-buffer
      (insert (plist-get tidy :shell))
      ;; Each heredoc, its body and the line that ends it, to `<< ‹n›'.
      (goto-char (point-min))
      (while (re-search-forward "<<-? *\\(['\"]?\\)\\([A-Za-z0-9_]+\\)\\1" nil t)
        (let ((op (copy-marker (match-beginning 0)))
              (op-end (copy-marker (match-end 0)))
              (end (match-string 2)))
          (unless (eq (char-before op) ?<)
            (save-excursion
              (forward-line 1)
              (let ((body (point)))
                (when (re-search-forward
                       (concat "^[ \t]*" (regexp-quote end) "$") nil t)
                  (let* ((closing (match-beginning 0))
                         (closed (match-end 0))
                         ;; Trimming looks things up too: where the heredoc
                         ;; ends is taken down first.
                         (text (string-trim (buffer-substring body closing))))
                    (delete-region (1- body) closed)
                    (goto-char op)
                    (delete-region op op-end)
                    (insert "<< " (if (string-match-p "\\`‹[0-9]+›\\'" text)
                                      text
                                    (propertize "…" 'face 'shadow))))))))))
      ;; The lines, joined.
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (let ((at (1- (point))))
          (if (vigil-command--string-p at)
              (progn (delete-region at (point))
                     (insert (propertize "⏎" 'face 'shadow)))
            (delete-region at (progn (skip-chars-forward " \t") (point)))
            (goto-char at)
            (cond ((eq (char-before at) ?\\)
                   (delete-region (progn (backward-char) (skip-chars-backward " ") (point))
                                  at)
                   (insert " "))
                  ((looking-back "\\(?:\\_<\\(?:then\\|do\\|else\\|in\\)\\|[{(|]\\|&&\\) *"
                                 (line-beginning-position))
                   (insert " "))
                  (t (insert "; "))))))
      (buffer-string))))

(defun vigil-command--tidy (command)
  "COMMAND laid out to be read; see `vigil-command-tidy'."
  (when-let* ((tree (vigil-command--parse command)))
    (let* ((source (encode-coding-string command 'utf-8 t))
           (scripts (vigil-command--scripts tree source))
           (breaks (vigil-command--breaks tree source scripts))
           (n 0)
           (edits (mapcar (lambda (script)
                            (list (plist-get script :beg) (plist-get script :end)
                                  (format (if (plist-get script :token)
                                              "__VIGIL_%d__" "__VIGIL_%d__\n")
                                          (cl-incf n))))
                          scripts))
           (shfmt (lambda (text)
                    (vigil-command--filter vigil-command-shfmt
                                           '("-ln" "bash" "-i" "2" "-ci" "-sr" "-bn")
                                           text)))
           (shell (or (funcall shfmt (vigil-command--edit
                                      source
                                      (append edits
                                              (mapcar (lambda (op) (list op op " \\\n"))
                                                      breaks))))
                      (funcall shfmt (vigil-command--edit source edits)))))
      (when shell
        (with-temp-buffer
          (insert (vigil-command-fontify (string-trim-right shell) 'sh-mode))
          (goto-char (point-min))
          (while (re-search-forward "__VIGIL_\\([0-9]+\\)__" nil t)
            (replace-match (propertize (format "‹%s›" (match-string 1))
                                       'face 'vigil-command-placeholder)
                           t t))
          (list :shell (buffer-string)
                :blocks (let ((i 0))
                          (mapcar (lambda (script)
                                    (cons (concat
                                           (propertize (format "‹%d›" (cl-incf i))
                                                       'face 'vigil-command-placeholder)
                                           (propertize (concat " " (plist-get script :label))
                                                       'face 'vigil-command-heading))
                                          (vigil-command--format-script script)))
                                  scripts))))))))

;;;; The scripts a command names

(defcustom vigil-command-script-extensions
  '("sh" "bash" "zsh" "fish" "py" "rb" "pl" "js" "mjs" "ts" "lua" "R" "r" "jl"
    "el" "awk" "sed" "tcl" "php" "nu")
  "File name extensions of scripts: a file a command names that has one is
shown with the command.  So is any that begins with `#!'."
  :type '(repeat string))

(defcustom vigil-command-script-size (* 256 1024)
  "A file larger than this many bytes is not taken for a script."
  :type 'integer)

(defcustom vigil-command-script-lines 60
  "How many lines of a script are shown with the command that names it."
  :type 'integer)

(defun vigil-command--script-p (file)
  "Whether FILE is a script to show: there, of this machine, small, and text
that begins with `#!' or is named as `vigil-command-script-extensions' says."
  (and (not (file-remote-p file))
       (file-regular-p file)
       (file-readable-p file)
       (<= (or (file-attribute-size (file-attributes file)) 0)
           vigil-command-script-size)
       (with-temp-buffer
         (ignore-errors (insert-file-contents file nil 0 1024))
         (and (not (search-forward "\0" nil t))
              (or (progn (goto-char (point-min)) (looking-at-p "#!"))
                  (member (file-name-extension file)
                          vigil-command-script-extensions))))))

(defvar vigil-command--named (make-hash-table :test #'equal)
  "The words of commands that may name files, by (COMMAND . DIRECTORY).")

(defun vigil-command--named (command directory)
  "What the words of COMMAND could name as files, absolute, in order.
Read against DIRECTORY, and against where a `cd' before them goes.  Only
words that are written out: nothing the shell would have to expand."
  (vigil-command-remember
   vigil-command--named (cons command directory)
   (lambda ()
     (when-let* ((tree (vigil-command--parse command)))
       (let ((source (encode-coding-string command 'utf-8 t))
             (directory (or directory default-directory))
             (names nil))
         (vigil-command--walk
          tree
          (lambda (node)
            (when (equal (alist-get 'Type node) "CallExpr")
              (let ((values (delq nil (mapcar #'cdr (vigil-command--args node source)))))
                (if (and (equal (car values) "cd") (cadr values))
                    (setq directory (expand-file-name (cadr values) directory))
                  (dolist (value values)
                    (unless (or (string-empty-p value) (string-prefix-p "-" value))
                      (push (expand-file-name value directory) names))))))))
         (delete-dups (nreverse names)))))))

(defun vigil-command-scripts (command &optional directory)
  "The scripts COMMAND names: files that are there now, absolute, in order.
Its programs and their arguments alike, so that the script a wrapper is
given to run is among them.  Relative names are read against DIRECTORY.
Nil without shfmt.  The command is only parsed, and the files only looked
at: nothing is run."
  (when (and (stringp command) (executable-find vigil-command-shfmt))
    (cl-remove-if-not #'vigil-command--script-p
                      (vigil-command--named command directory))))

(defvar vigil-command--headers (make-hash-table :test #'equal)
  "What scripts say they are, by file: (MODIFIED . HEADER).")

(defun vigil-command--read-header ()
  "The comment this buffer, the start of a script, begins with; nil if none.
After its `#!' line, and with the marks of a comment taken away.  A Python
file's first string is its comment."
  (goto-char (point-min))
  (when (looking-at-p "#!") (forward-line 1))
  (while (and (not (eobp))
              (looking-at-p "[ \t]*$\\|.*-\\*-.*-\\*-\\|#.*coding[:=]"))
    (forward-line 1))
  (let ((lines nil))
    (cond
     ((looking-at "[ \t]*[ru]?\\(\"\"\"\\|'''\\)")
      (let ((quote (match-string 1))
            (start (match-end 0)))
        (goto-char start)
        (setq lines (split-string
                     (buffer-substring start (if (search-forward quote nil t)
                                                 (match-beginning 0)
                                               (point-max)))
                     "\n"))))
     (t
      (while (and (not (eobp))
                  (looking-at "[ \t]*\\(?:#+\\|//+\\|;+\\|--+\\)!? ?\\(.*\\)$"))
        (push (match-string 1) lines)
        (forward-line 1))
      (setq lines (nreverse lines))))
    (let ((text (string-trim (string-join lines "\n"))))
      (and (not (string-empty-p text)) text))))

(defun vigil-command-script-header (file)
  "What the script FILE says it is: the comment it begins with, or nil."
  (let* ((modified (file-attribute-modification-time (file-attributes file)))
         (known (gethash file vigil-command--headers)))
    (if (and known (equal (car known) modified))
        (cdr known)
      (when (>= (hash-table-count vigil-command--headers) vigil-command-remembered)
        (clrhash vigil-command--headers))
      (cdr (puthash file
                    (cons modified
                          (with-temp-buffer
                            (ignore-errors (insert-file-contents file nil 0 4096))
                            (vigil-command--read-header)))
                    vigil-command--headers)))))

(defun vigil-command-summary (command &optional directory)
  "What the last script COMMAND names says it is, in a line; nil if none says.
The last, because the ones before it are what runs it: a wrapper, an
interpreter's own."
  (cl-some (lambda (file)
             (when-let* ((header (vigil-command-script-header file)))
               (string-trim (car (split-string header "\n")))))
           (reverse (vigil-command-scripts command directory))))

(defun vigil-command--script-mode (file)
  "The mode to highlight the script FILE in: by its name, or its `#!' line."
  (or (vigil-command--mode-for-file file)
      (with-temp-buffer
        (ignore-errors (insert-file-contents file nil 0 256))
        (when (looking-at "#![ \t]*\\(?:\\S-*/env[ \t]+\\(?:-\\S-+[ \t]+\\)*\\)?\\(\\S-+\\)")
          (let* ((name (file-name-nondirectory (match-string 1)))
                 (mode (assoc-default name interpreter-mode-alist #'string-match-p)))
            (and (symbolp mode) (fboundp mode) mode))))))

(defun vigil-command-insert-scripts (files)
  "Insert FILES, the scripts a command names, as they are now.
They are what `vigil-command-scripts' gives.
Each under its name, highlighted, its first `vigil-command-script-lines'
lines.  As they are now: a script changed since the command ran is shown
as it was changed.  One that can no longer be read is passed over."
  (dolist (file files)
    (when-let* ((text (ignore-errors
                        (with-temp-buffer
                          (insert-file-contents file)
                          (string-trim-right (buffer-string)))))
                (lines (split-string text "\n")))
      (let ((more (- (length lines) vigil-command-script-lines)))
        (insert "\n"
                (abbreviate-file-name file)
                (propertize (format "  %d lines, as it is now\n" (length lines))
                            'face 'vigil-command-heading)
                (vigil-command-fontify
                 (if (> more 0)
                     (string-join (take vigil-command-script-lines lines) "\n")
                   text)
                 (vigil-command--script-mode file))
                "\n")
        (when (> more 0)
          (insert (propertize (format "… %d more lines\n" more)
                              'face 'vigil-command-heading)))))))

;;;; Manuals

(defvar vigil-command--manuals (make-hash-table :test #'equal)
  "The text of manuals read, by name; `none' for one there is not.")

(defun vigil-command--name-p (name)
  "Whether NAME may be given to `man' or `help' as a name, and nothing else."
  (and (stringp name)
       (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_.+-]*\\'" name)))

(defun vigil-command--run (program &rest args)
  "What PROGRAM with ARGS prints, or nil if it fails or prints nothing."
  (when (executable-find program)
    (with-temp-buffer
      (let ((default-directory temporary-file-directory)
            (process-environment (append '("MANPAGER=cat" "PAGER=cat" "MANWIDTH=80"
                                           "MAN_KEEP_FORMATTING=" "GROFF_NO_SGR=1")
                                         process-environment)))
        (and (eq 0 (apply #'call-process program nil '(t nil) nil args))
             (> (buffer-size) 0)
             (ansi-color-filter-apply
              (replace-regexp-in-string "[^\b]\b" "" (buffer-string))))))))

(defun vigil-command--manual (name)
  "The text of NAME's manual on this machine.
Bash's `help' for a builtin, else `man'."
  (when (vigil-command--name-p name)
    (vigil-command-remember
     vigil-command--manuals name
     (lambda ()
       ;; Only of what bash itself runs: `help' takes a name for the start
       ;; of one, and would say of tr what it says of trap.
       (or (vigil-command--run
            "bash" "-c"
            "case \"$(type -t -- \"$1\")\" in builtin|keyword) help -- \"$1\" ;; *) exit 1 ;; esac"
            "vigil" name)
           (vigil-command--run "man" name))))))

(defun vigil-command--sentence (text)
  "TEXT's first sentence, on one line."
  (let ((text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text))))
    (if (string-match "\\.\\(?: \\|\\'\\)" text)
        (substring text 0 (1+ (match-beginning 0)))
      text)))

(defun vigil-command--manual-summary (text)
  "What the manual TEXT says its program is, in a line."
  (cond
   ;; man: the NAME section, `grep, egrep -- file pattern searcher'.
   ((string-match "^NAME[ \t]*\n\\(\\(?:[ \t]+.*\n\\)+\\)" text)
    (let ((name (replace-regexp-in-string "[ \t\n]+" " " (match-string 1 text))))
      (string-trim (if (string-match " \\(?:-\\|‐\\|–\\|—\\|\\\\-\\)+ " name)
                       (substring name (match-end 0))
                     name))))
   ;; help: its usage, then what it does.
   ((string-match "\\`[^\n]*\n[ \t]+\\([^\n]+\\)" text)
    (vigil-command--sentence (match-string 1 text)))))

(defun vigil-command--manual-option (text option)
  "What the manual TEXT says of OPTION, in a sentence, or nil if it does not."
  (let ((case-fold-search nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (catch 'found
        ;; The lines an option is described under start with one, indented.
        (while (re-search-forward "^\\([ \t]+\\)\\(-[^\n]*\\)" nil t)
          (let ((indent (length (match-string 1)))
                (line (match-string 2)))
            (when (string-match (concat "\\(?:\\`\\|[ \t,|[]\\)"
                                        (regexp-quote option)
                                        "\\(?:[^A-Za-z0-9_-]\\|\\'\\)")
                                line)
              ;; Said on the same line, after a gap, or in the lines under it.
              (let ((same (and (string-match "\\(?:\t\\|  \\)[ \t]*\\([^- \t].*\\)" line)
                               (match-string 1 line)))
                    (under nil))
                (forward-line 1)
                (while (and (not (eobp))
                            (looking-at "^\\([ \t]*\\)\\(.+\\)$")
                            (> (length (match-string 1)) indent))
                  (push (match-string 2) under)
                  (forward-line 1))
                (let ((said (string-join (delq nil (cons same (nreverse under))) " ")))
                  (unless (string-blank-p said)
                    (throw 'found (truncate-string-to-width
                                   (vigil-command--sentence said) 160 nil nil "…"))))))))
        nil))))

(defun vigil-command--options (value)
  "The options to look up for the word VALUE: itself first, then its parts.
`-rn' may be `-r' and `-n'; `-i.bak' is `-i'; `--color=never', `--color'."
  (cond ((string-match "\\`\\(--[^=]+\\)=" value) (list (match-string 1 value)))
        ((string-match-p "\\`-[A-Za-z0-9]\\{2,\\}\\'" value)
         (cons value (mapcar (lambda (c) (string ?- c)) (substring value 1))))
        ((string-match "\\`\\(-[A-Za-z0-9]\\)[^A-Za-z0-9]" value)
         (list value (match-string 1 value)))
        (t (list value))))

(defun vigil-command-explain (command)
  "What COMMAND's programs are, and its options, from the manuals on this machine.
A list of (PROGRAM SUMMARY OPTIONS), one for each program in the order they
come; OPTIONS is a list of (OPTION . WHAT), WHAT nil where its manual does
not say.  Nil without shfmt or where COMMAND is not shell."
  (when-let* ((source (and (stringp command) (encode-coding-string command 'utf-8 t)))
              (tree (vigil-command--parse command)))
    (let ((programs nil))
      (vigil-command--walk
       tree
       (lambda (node)
         (when (equal (alist-get 'Type node) "CallExpr")
           (let* ((args (vigil-command--args node source))
                  (program (cdr (car args))))
             (when (and program (not (string-empty-p program)))
               (let* ((name (file-name-nondirectory program))
                      (sub (and (member name vigil-command-subcommands)
                                (cdr (nth 1 args))
                                (string-match-p "\\`[a-z][a-z0-9-]*\\'" (cdr (nth 1 args)))
                                (cdr (nth 1 args))))
                      (page (or (and sub (vigil-command--manual (concat name "-" sub))
                                     (concat name "-" sub))
                                name))
                      (title (if (equal page name) program (concat program " " sub)))
                      (entry (or (assoc title programs)
                                 (car (push (list title page nil) programs))))
                      (done nil))
                 (dolist (arg (cdr args))
                   (let ((value (cdr arg)))
                     (cond (done)
                           ((equal value "--") (setq done t))
                           ((and value (string-match-p "\\`--?[A-Za-z0-9]" value)
                                 (not (string-match-p "\\`-[0-9]+\\'" value)))
                            (unless (assoc value (nth 2 entry))
                              (setcar (nthcdr 2 entry)
                                      (append (nth 2 entry) (list (list value)))))))))))))
         nil))
      (mapcar
       (lambda (entry)
         (let ((manual (vigil-command--manual (nth 1 entry))))
           (list (car entry)
                 (and manual (vigil-command--manual-summary manual))
                 (let ((said nil))
                   (dolist (option (nth 2 entry))
                     (let* ((tries (vigil-command--options (car option)))
                            (whole (and manual (vigil-command--manual-option
                                                manual (car tries)))))
                       (dolist (pair (if (or whole (null manual) (null (cdr tries)))
                                         (list (cons (car option) whole))
                                       (mapcar (lambda (part)
                                                 (cons part (vigil-command--manual-option
                                                             manual part)))
                                               (cdr tries))))
                         (unless (assoc (car pair) said) (push pair said)))))
                   (nreverse said)))))
       (nreverse programs)))))

(defun vigil-command-insert-explanation (command)
  "Insert what COMMAND's programs and options are; see `vigil-command-explain'."
  (let ((programs (vigil-command-explain command)))
    (if (null programs)
        (insert (propertize "(nothing to explain: no shfmt, or not shell)\n" 'face 'shadow))
      (let ((width (apply #'max (mapcar (lambda (p) (string-width (car p))) programs))))
        (dolist (program programs)
          (insert (propertize (car program) 'face 'vigil-command-program)
                  (make-string (- (+ width 2) (string-width (car program))) ?\s)
                  (or (nth 1 program) (propertize "no manual here" 'face 'shadow))
                  "\n")
          (dolist (option (nth 2 program))
            (insert (make-string (+ width 4) ?\s)
                    (propertize (car option) 'face 'vigil-command-option) "  "
                    (or (cdr option) (propertize "not in its manual" 'face 'shadow))
                    "\n")))))))

(provide 'vigil-command)
;;; vigil-command.el ends here
