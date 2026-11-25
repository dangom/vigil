;;; vigil-purpose.el --- What a command was for, and what it uses -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; An agent's command is seldom one thing: it changes three files, runs the
;; tests and commits.  This says what a command was for, as far as that can
;; be told without running anything and without guessing, and with what it
;; goes by:
;;
;; - `vigil-purpose-tags': what it was for, each with why.  Testing,
;;   checking (a linter, a compiler), version control and setting up, by
;;   the programs it runs and what it asks of them; writing code, tests or
;;   documentation, by the names of the files that differed after it.
;; - `vigil-purpose-python': what a Python program inside it does, read off
;;   its syntax tree by Python's own parser: what it imports, the files it
;;   writes and reads, the commands it runs, how many assertions it makes.
;; - `vigil-purpose-programs': the programs it runs, and where each is.
;; - `vigil-purpose-looks-p' and `vigil-purpose-writes-p': whether its words
;;   only look, and whether they write a file.
;;
;; All of it is of the command as text.  Python is asked to parse a
;; program, not to run it, and is started apart from its surroundings
;; (`-I').  What is not in the words is not found: a path that is worked
;; out, a program a script runs, what a script on disk does.  A command no
;; rule knows is one that ran something, and is said to be no more.
;;
;; Needs vigil-command.el and vigil-history.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-base)
(require 'vigil-command)
(require 'vigil-history)

(defgroup vigil-purpose nil
  "What a command was for, and what it uses."
  :group 'vigil)

(defcustom vigil-purpose-rules
  '((test
     "\\(?:pytest\\|py\\.test\\|bats\\|jest\\|vitest\\|mocha\\|rspec\\|tox\\|nox\\|ctest\\|busted\\|phpunit\\)\\_>"
     "python[0-9.]*[ \t]+-m[ \t]+\\(?:pytest\\|unittest\\)\\_>"
     "\\(?:cargo\\|go\\|npm\\|yarn\\|pnpm\\|bun\\|deno\\|mix\\|swift\\|dotnet\\|gradle\\|mvn\\|zig\\)[ \t]+\\(?:run[ \t]+\\)?test\\_>"
     "make[ \t]+\\(?:[^;|&\n]*[ \t]\\)?\\(?:test\\|check\\)\\_>"
     "node[ \t]+--test\\_>"
     (anywhere . "\\_<ert-run-tests[-a-z]*"))
    (check
     "\\(?:ruff\\|flake8\\|pylint\\|mypy\\|pyright\\|eslint\\|tsc\\|shellcheck\\|black\\|prettier\\|shfmt\\|rubocop\\|golangci-lint\\)\\_>"
     "\\(?:cargo\\|go\\|npm\\|yarn\\|pnpm\\|bun\\)[ \t]+\\(?:run[ \t]+\\)?\\(?:build\\|check\\|lint\\|vet\\|clippy\\|fmt\\)\\_>"
     "make\\(?:[ \t]+\\(?:build\\|all\\|lint\\)\\)?[ \t]*\\(?:\\'\\|[;|&\n]\\)"
     (anywhere . "\\_<batch-byte-compile\\_>"))
    (git
     "git\\(?:[ \t]+-[cC][ \t]+[^ \t]+\\|[ \t]+--?[-a-z]+\\(?:=[^ \t]+\\)?\\)*[ \t]+\\(?:add\\|commit\\|push\\|pull\\|fetch\\|merge\\|rebase\\|checkout\\|switch\\|reset\\|tag\\|branch\\|stash\\|restore\\|cherry-pick\\|revert\\|mv\\|rm\\|clone\\|init\\|remote\\|update-ref\\|filter-branch\\|worktree\\|apply\\|am\\|gc\\)\\_>"
     "gh[ \t]+[a-z]+")
    (setup
     "\\(?:pip[0-9.]*\\|uv\\|poetry\\|conda\\|brew\\|apt\\(?:-get\\)?\\|gem\\|cargo\\)[ \t]+\\(?:install\\|add\\|sync\\|update\\|upgrade\\)\\_>"
     "\\(?:npm\\|yarn\\|pnpm\\|bun\\)[ \t]+\\(?:install\\|ci\\|add\\|i\\)\\_>"
     "vigil[ \t]+\\(?:setup\\|install-[a-z]+\\|snapshots[ \t]+on\\|coverage[ \t]+on\\)\\_>"))
  "What a command is for, by what it runs: (TAG RULE...).
A RULE is a regexp for a program and what it is asked, which has to be
where a program is: at the beginning of a command, after `;', `|' or `&&',
and after such as `env X=1', `time', `sudo', `uv run' and `npx'; under any
path.  So `grep pytest' runs no tests.  Or (anywhere . REGEXP), for what is
an argument: the function Emacs is told to run.

A command is TAG where a RULE matches its words: those left when what is
quoted and what is in a heredoc are taken out, since a commit's message
that speaks of tests runs none.  A command may be several."
  :type '(alist :key-type symbol
                :value-type (repeat (choice regexp (cons (const anywhere) regexp)))))

(defconst vigil-purpose--program-at
  (concat "\\(?:\\`\\|[;|&(\n]\\)[ \t]*"
          ;; `FOO=1 BAR=2'
          "\\(?:[A-Za-z_][A-Za-z0-9_]*=[^ \t\n]*[ \t]+\\)*"
          ;; What runs another: `time', `sudo', `uv run', `npx'.
          "\\(?:\\(?:time\\|sudo\\|env\\|exec\\|command\\|xargs\\|nice\\|npx\\|bunx\\|uvx\\|\\(?:uv\\|poetry\\|pipenv\\|pdm\\|hatch\\|pnpm\\|bundle\\)[ \t]+\\(?:run\\|exec\\)\\)[ \t]+\\(?:-[^ \t\n]+[ \t]+\\)*\\)*"
          ;; Under any path.
          "\\(?:[^ \t\n;|&()]*/\\)?")
  "What comes before a program, where a program is.")

(defcustom vigil-purpose-test-files
  "\\(?:\\`\\|/\\)tests?/\\|_test\\.\\|\\(?:\\`\\|/\\)test_\\|-tests?\\.\\|\\.bats\\'\\|[._]spec\\."
  "What the name of a file of tests looks like."
  :type 'regexp)

(defcustom vigil-purpose-doc-files
  "\\.\\(?:md\\|org\\|rst\\|txt\\|adoc\\)\\'\\|\\(?:\\`\\|/\\)docs?/\\|\\(?:\\`\\|/\\)\\(?:README\\|CHANGELOG\\|LICEN[SC]E\\|NEWS\\)"
  "What the name of a file of documentation looks like."
  :type 'regexp)

;; What these three went by when vigil-status.el had them.
(define-obsolete-variable-alias 'vigil-status-looking-programs
  'vigil-purpose-looking-programs "0.8.0")
(define-obsolete-variable-alias 'vigil-status-looking-git
  'vigil-purpose-looking-git "0.8.0")
(define-obsolete-variable-alias 'vigil-status-writing-programs
  'vigil-purpose-writing-programs "0.8.0")

(defcustom vigil-purpose-looking-programs
  '("cat" "head" "tail" "less" "more" "bat" "grep" "egrep" "fgrep" "rg" "ag" "ls"
    "wc" "stat" "file" "du" "df" "tree" "nl" "sort" "uniq" "cut" "tr" "xxd" "hexdump"
    "md5" "shasum" "sha256sum" "diff" "cmp" "comm" "find" "fd" "basename" "dirname"
    "realpath" "readlink" "test" "[" "[[" "cd" "pushd" "popd" "echo" "printf" "jq" "yq"
    "which" "type" "command" "pwd" "date" "true" "false" "env" "printenv" "sed" "awk"
    "git" "column" "fold" "rev" "tac" "seq" "expr" "sleep" "uname" "whoami" "id"
    "ps" "pgrep" "lsof" "otool" "strings" "nm")
  "Programs that only look: a command of these alone is a look, not a command.
`sed' counts unless it edits in place, `find' unless it deletes or runs
something, and `git' only with one of `vigil-purpose-looking-git'.  A command
that writes a file with a redirection, or that changed a file, is not one
whatever its programs."
  :type '(repeat string))

(defcustom vigil-purpose-looking-git
  '("log" "status" "diff" "show" "rev-parse" "ls-files" "ls-tree" "for-each-ref"
    "reflog" "describe" "blame" "grep" "cat-file" "shortlog" "rev-list" "merge-base"
    "name-rev" "whatchanged" "count-objects" "check-ignore" "var" "version" "help")
  "What `git' is asked that only looks."
  :type '(repeat string))

(defcustom vigil-purpose-writing-programs
  '("cp" "mv" "rm" "mkdir" "rmdir" "touch" "ln" "chmod" "chown" "tee" "patch"
    "install" "truncate" "unzip" "trash" "rsync" "dd")
  "Programs that write, move or remove files: a command of one is a write.
As is one that writes a file with a redirection, or edits one in place with
`sed -i'.  What a script does is not in its command's words: that is known
only by the files having differed after it."
  :type '(repeat string))

(defcustom vigil-purpose-python "python3"
  "The Python that parses a Python program, to say what it does."
  :type 'string)

(defconst vigil-purpose-names
  '((look . "look") (code . "code") (tests . "tests") (docs . "docs")
    (write . "write") (test . "test") (check . "check") (git . "git")
    (setup . "setup") (run . "run"))
  "What each tag is called, in the order they are said in.")

;;;; The words that are the command's own

(defun vigil-purpose--bare (command)
  "COMMAND without what is quoted in it, and without its heredocs' lines.
What is left is what it runs and asks, not what it is told to say.  Read a
character at a time, as the shell reads it: a heredoc begins only outside
quotes, and a quote inside a heredoc opens nothing."
  (let ((i 0) (n (length command)) (out nil) (waiting nil))
    (while (< i n)
      (let ((c (aref command i)))
        (cond
         ;; A character made plain by a backslash is nobody's.
         ((eq c ?\\) (push ?\s out) (setq i (+ i 2)))
         ((eq c ?')
          (let ((end (string-search "'" command (1+ i))))
            (push ?\" out) (push ?\" out)
            (setq i (if end (1+ end) n))))
         ((eq c ?\")
          (let ((j (1+ i)))
            (while (and (< j n) (not (eq (aref command j) ?\")))
              (setq j (+ j (if (eq (aref command j) ?\\) 2 1))))
            (push ?\" out) (push ?\" out)
            (setq i (min n (1+ j)))))
         ;; `<<<' is a string given at once, not a heredoc.
         ((and (eq c ?<) (< (+ i 2) n)
               (eq (aref command (1+ i)) ?<) (eq (aref command (+ i 2)) ?<))
          (push ?\s out)
          (setq i (+ i 3)))
         ((and (eq c ?<)
               (< (+ i 2) n) (eq (aref command (1+ i)) ?<)
               (not (eq (aref command (+ i 2)) ?<))
               (eq i (string-match
                      "<<-?[ \t]*\\(['\"]?\\)\\([A-Za-z_][A-Za-z0-9_]*\\)\\1" command i)))
          (setq waiting (append waiting (list (match-string 2 command))))
          (push ?\s out)
          (setq i (match-end 0)))
         ((and (eq c ?\n) waiting)
          ;; The lines of each heredoc begun on the line that ends here.
          (setq i (1+ i))
          (dolist (delimiter waiting)
            (let ((close (string-match
                          (concat "^[ \t]*" (regexp-quote delimiter) "[ \t]*$")
                          command i)))
              (setq i (if close (min n (1+ (match-end 0))) n))))
          (setq waiting nil)
          (push ?\n out))
         (t (push c out) (setq i (1+ i))))))
    (concat (nreverse out))))

(defun vigil-purpose--matches (rules text)
  "What of TEXT each of RULES matches, each once, in the order found.
A rule as `vigil-purpose-rules' has them."
  (let (found)
    (dolist (rule rules)
      (let* ((anywhere (consp rule))
             (regexp (if anywhere
                         (concat "\\(" (cdr rule) "\\)")
                       (concat vigil-purpose--program-at "\\(" rule "\\)")))
             (start 0) (case-fold-search nil))
        (while (and (< start (length text)) (string-match regexp text start))
          ;; From where what matched began: the `;' that ends one command
          ;; is what the next begins after.
          (setq start (max (1+ start) (match-beginning 1)))
          (cl-pushnew (string-trim (replace-regexp-in-string
                                    "[ \t\n;|&]+" " " (match-string 1 text)))
                      found :test #'equal))))
    (nreverse found)))

;;;; What a Python program does

(defconst vigil-purpose--scan "
import ast, json, sys
src = sys.stdin.read()
out = {'imports': [], 'writes': [], 'reads': [], 'runs': [], 'asserts': 0, 'defines': 0}
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print(json.dumps({'error': '%s, line %s' % (e.msg, e.lineno)}))
    sys.exit(0)
std = getattr(sys, 'stdlib_module_names', ())
def standard(n):
    if std: return n in std
    try:
        import importlib.util, sysconfig
        spec = importlib.util.find_spec(n)
        if spec is None: return False
        if spec.origin in ('built-in', 'frozen'): return True
        origin = spec.origin or ''
        return origin.startswith(sysconfig.get_paths()['stdlib']) and 'site-packages' not in origin
    except Exception:
        return False
known = {}
for node in tree.body:
    if (isinstance(node, ast.Assign) and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
        known.setdefault(node.targets[0].id, node.value.value)
def name(f):
    if isinstance(f, ast.Name): return f.id
    if isinstance(f, ast.Attribute): return name(f.value) + '.' + f.attr
    if isinstance(f, ast.Call): return name(f.func) + '()'
    return '?'
def lit(n):
    if isinstance(n, ast.Constant): return n.value if isinstance(n.value, str) else repr(n.value)
    if isinstance(n, ast.Name): return known.get(n.id, '<' + n.id + '>')
    if isinstance(n, ast.JoinedStr): return '<worked out>'
    if isinstance(n, (ast.List, ast.Tuple)): return ' '.join(lit(e) for e in n.elts)
    if isinstance(n, ast.Call) and name(n.func).split('.')[-1] in ('Path', 'PurePath') and n.args:
        return lit(n.args[0])
    if isinstance(n, ast.BinOp): return '<worked out>'
    return '<' + name(n) + '>' if isinstance(n, ast.Attribute) else '<worked out>'
def add(key, value):
    if value and value not in out[key]: out[key].append(value)
RUNS = ('run', 'call', 'check_call', 'check_output', 'Popen', 'system', 'popen', 'getoutput')
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for a in node.names: add('imports', a.name.split('.')[0])
    elif isinstance(node, ast.ImportFrom):
        add('imports', node.module.split('.')[0] if node.module and node.level == 0 else '.')
    elif isinstance(node, ast.Assert):
        out['asserts'] += 1
    elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        out['defines'] += 1
    elif isinstance(node, ast.Call):
        f = name(node.func); last = f.split('.')[-1]
        if last == 'open':
            if f in ('open', 'io.open', 'codecs.open') and node.args:
                target, rest = lit(node.args[0]), node.args[1:]
            elif isinstance(node.func, ast.Attribute):
                target, rest = lit(node.func.value), node.args
            else:
                continue
            mode = next((lit(k.value) for k in node.keywords if k.arg == 'mode'),
                        lit(rest[0]) if rest else 'r')
            add('writes' if any(c in mode for c in 'wax+') else 'reads', target)
        elif last in ('write_text', 'write_bytes', 'touch', 'mkdir', 'unlink', 'rmdir') \\
                and isinstance(node.func, ast.Attribute):
            add('writes', lit(node.func.value))
        elif last in ('read_text', 'read_bytes') and isinstance(node.func, ast.Attribute):
            add('reads', lit(node.func.value))
        elif last in RUNS and (f.startswith(('subprocess.', 'os.')) or f == last) and node.args:
            add('runs', lit(node.args[0]))
        elif f in ('shutil.copy', 'shutil.copy2', 'shutil.copyfile', 'shutil.move',
                   'os.rename', 'os.replace') and node.args:
            add('writes', lit(node.args[-1]))
        elif f in ('os.remove', 'os.unlink', 'shutil.rmtree', 'os.makedirs', 'os.mkdir') \\
                and node.args:
            add('writes', lit(node.args[0]))
out['standard'] = sorted(i for i in out['imports'] if standard(i))
out['others'] = sorted(i for i in out['imports'] if not standard(i))
del out['imports']
print(json.dumps(out))
"
  "The Python that says what a Python program does, from its syntax tree.
Given the program on its standard input; it parses it and runs none of it.")

(defvar vigil-purpose--scanned (make-hash-table :test #'equal)
  "What was read off each Python program, by its text.")

(defun vigil-purpose-python (code)
  "What the Python program CODE does, read off its syntax tree: a plist.
:standard and :others, the modules it imports, of Python's own library and
not; :writes and :reads, the files it writes (or makes, or removes) and
reads; :runs, the commands it runs; :asserts, how many assertions it makes;
:defines, how many functions and classes.  Or only :error, where it does not
parse.  A name that is worked out and not written is said as such.  Nil
without Python to ask.  CODE is parsed, and none of it is run."
  (when (and (stringp code) (executable-find vigil-purpose-python))
    (vigil-command-remember
     vigil-purpose--scanned code
     (lambda ()
       (with-temp-buffer
         (insert code)
         (let ((default-directory temporary-file-directory)
               (coding-system-for-read 'utf-8)
               (coding-system-for-write 'utf-8))
           (when (eq 0 (ignore-errors
                         (call-process-region (point-min) (point-max)
                                              (executable-find vigil-purpose-python)
                                              t '(t nil) nil
                                              "-I" "-c" vigil-purpose--scan)))
             (when-let* ((said (vigil-base-json-string (buffer-string))))
               (list :standard (alist-get 'standard said)
                     :others (alist-get 'others said)
                     :writes (alist-get 'writes said)
                     :reads (alist-get 'reads said)
                     :runs (alist-get 'runs said)
                     :asserts (or (alist-get 'asserts said) 0)
                     :defines (or (alist-get 'defines said) 0)
                     :error (alist-get 'error said))))))))))

(defun vigil-purpose-scripts (command)
  "The Python programs inside COMMAND: each (LABEL . CODE).
The argument of `python3 -c', a heredoc fed to Python, one written to a
file whose name is Python's.  Nil without shfmt, which finds them."
  (when-let* (((stringp command))
              ((executable-find vigil-command-shfmt))
              (tree (ignore-errors (vigil-command--parse command))))
    (let ((source (encode-coding-string command 'utf-8 t)) found)
      (dolist (script (ignore-errors (vigil-command--scripts tree source)))
        (when (memq (plist-get script :mode) '(python-mode python-ts-mode))
          (push (cons (plist-get script :label)
                      (decode-coding-string (plist-get script :code) 'utf-8 t))
                found)))
      (nreverse found))))

;;;; The programs a command runs

(defconst vigil-purpose--shell-words
  '("cd" "echo" "printf" "test" "true" "false" "pwd" "export" "set" "unset" "source"
    "read" "wait" "exit" "eval" "exec" "type" "command" "kill" "alias" "local"
    "return" "shift" "trap" "umask" "pushd" "popd" "for" "while" "until" "if" "then"
    "else" "elif" "fi" "do" "done" "case" "esac" "in" "function" "select" "time")
  "The shell's own words: what a command begins with that is no program.")

(defun vigil-purpose-programs (command &optional directory)
  "The programs COMMAND runs, and where each is now: ((NAME . FILE)...).
Those found on the path, and those named by a path of their own that is a
file, from DIRECTORY.  The shell's own words and what is not there are left
out.  Where a program is now is not always where it was when it ran."
  (when (stringp command)
    (let ((bare (vigil-purpose--bare command))
          found named)
      ;; A program named by where it is: `bin/vigil', `./run.sh'.
      (let ((start 0))
        (while (string-match "\\(?:\\`\\|[;|&\n(]\\)[ \t]*\\(\\.?\\.?/?[A-Za-z0-9_.+-]+/[A-Za-z0-9_./+-]+\\)"
                             bare start)
          (setq start (match-end 0))
          (let* ((name (match-string 1 bare))
                 (file (expand-file-name name (or directory default-directory))))
            (when (and (not (assoc name named)) (file-regular-p file))
              (push (cons name file) named)))))
      (dolist (program (cdr (vigil-history--words
                             (replace-regexp-in-string "[0-9]*>&[0-9-]+" " "
                                                       (vigil-purpose--bare command)))))
        (when (and (string-match-p "\\`[A-Za-z0-9_.+-]+\\'" program)
                   (not (member program vigil-purpose--shell-words))
                   (not (assoc program found))
                   ;; Not one already named by where it is.
                   (not (cl-some (lambda (entry)
                                   (equal (file-name-nondirectory (car entry)) program))
                                 named)))
          (when-let* ((file (executable-find program)))
            (push (cons program file) found))))
      (append (nreverse named) (nreverse found)))))

;;;; A command that only looks, and one that writes

(defun vigil-purpose--words (command)
  "The words and programs of COMMAND, as `vigil-history--words' gives them.
With one stream sent to another (`2>&1') taken out first: that names no
file and runs no program."
  (vigil-history--words
   (replace-regexp-in-string "[0-9]*>&[0-9-]+" " " command)))

(defun vigil-purpose-looks-p (command)
  "Whether COMMAND, a shell command as text, only looks, going by its words.
Every program it runs is one of `vigil-purpose-looking-programs', used so as
only to look; and it writes no file with a redirection."
  (when (and (stringp command) (not (string-empty-p (string-trim command))))
    (pcase-let ((`(,words . ,programs) (vigil-purpose--words command)))
      (and programs
           (not (cl-some (lambda (word) (eq (nth 2 word) 'written)) words))
           (cl-every (lambda (program) (member program vigil-purpose-looking-programs))
                     programs)
           (not (string-match-p
                 "\\_<sed\\_>[^|;&\n]*\\(?:[ \t]-[a-zA-Z]*i\\|--in-place\\)" command))
           (not (string-match-p "\\_<find\\_>[^|;&\n]*[ \t]-\\(?:delete\\|exec\\|ok\\)" command))
           (let ((start 0) (looks t))
             (while (and looks
                         (string-match
                          "\\_<git\\(?:[ \t]+-[cC][ \t]+[^ \t]+\\|[ \t]+--?[-a-z]+\\(?:=[^ \t]+\\)?\\)*[ \t]+\\([a-z][-a-z]*\\)"
                          command start))
               (setq start (match-end 0)
                     looks (and (member (match-string 1 command) vigil-purpose-looking-git)
                                t)))
             looks)))))

(defun vigil-purpose-writes-p (command)
  "Whether COMMAND, a shell command as text, writes files, going by its words.
It writes one with a redirection, runs one of
`vigil-purpose-writing-programs', or edits in place with `sed -i'.  Nil says
only that its words do not show it."
  (when (and (stringp command) (not (string-empty-p (string-trim command))))
    (pcase-let ((`(,words . ,programs) (vigil-purpose--words command)))
      (or (cl-some (lambda (word)
                     ;; What a redirection writes to: not a name in a heredoc,
                     ;; which is text handed to a program.
                     (and (eq (nth 2 word) 'written) (nth 1 word)))
                   words)
          (cl-some (lambda (program) (member program vigil-purpose-writing-programs))
                   programs)
          (and (string-match-p
                "\\_<sed\\_>[^|;&\n]*\\(?:[ \t]-[a-zA-Z]*i\\|--in-place\\)" command)
               t)))))

;;;; What a command was for

(defun vigil-purpose--files-said (files)
  "FILES, names, in a few words: the first of them, and how many more."
  (concat (string-join (seq-take files 3) ", ")
          (if (> (length files) 3) (format ", and %d more" (- (length files) 3)) "")))

(defun vigil-purpose--result-said (result)
  "What RESULT, the end of what a command printed, says of tests run; or nil."
  (when (and (stringp result)
             (string-match
              "\\(?:[0-9]+ \\(?:passed\\|failed\\|tests?\\|results as expected\\|examples?\\)[^\n]*\\|Ran [0-9]+ tests?[^\n]*\\|test result:[^\n]*\\)"
              result))
    (string-trim (match-string 0 result))))

(defun vigil-purpose-tags (command &optional changed result shallow)
  "What COMMAND was for: ((TAG . WHY)...), in the order of `vigil-purpose-names'.
CHANGED is the names of the files that differed after it, where that is
known; RESULT, the end of what it printed.  TAG is one of:

  code, tests, docs   it wrote files of that kind, going by CHANGED; or
                      without it, by what a Python program inside it says
                      it writes
  write               it wrote a file whose name is not known
  test                it ran tests
  check               it ran a linter, a formatter or a compiler
  git                 it changed the repository's history or its branches
  setup               it installed something

by `vigil-purpose-rules', applied to its own words and to the commands a
Python program inside it runs.  Nil where it is none of these: it ran
something, or only looked.

It is never nil.  Where it is none of those: `write', if its words write a
file (`vigil-purpose-writes-p'); `look', if they only look
(`vigil-purpose-looks-p'); and else `run', it ran something no rule knows.

With SHALLOW, a Python program inside it is not looked into: nothing is
started but what was already asked, which is what a list of many commands
can afford."
  (when (stringp command)
    (let* ((bare (vigil-purpose--bare command))
           (scans (and (not shallow)
                       (delq nil (mapcar (lambda (script)
                                           (vigil-purpose-python (cdr script)))
                                         (vigil-purpose-scripts command)))))
           ;; What a Python program inside it runs is run by it.
           (text (string-join
                  (cons bare (apply #'append
                                    (mapcar (lambda (scan) (plist-get scan :runs)) scans)))
                  "\n"))
           (asserts (apply #'+ (mapcar (lambda (scan) (plist-get scan :asserts)) scans)))
           ;; Where nothing says which files differed, the files a Python
           ;; program inside it says it writes: those it names.
           (said (and (null changed)
                      (apply #'append
                             (mapcar (lambda (scan) (plist-get scan :writes)) scans))))
           (named (seq-remove (lambda (file) (string-prefix-p "<" file)) said))
           (changed (or changed named))
           (by (if named ", by the Python inside it" ""))
           (tests (seq-filter (lambda (file)
                                (string-match-p vigil-purpose-test-files file))
                              changed))
           (docs (seq-filter (lambda (file)
                               (and (not (member file tests))
                                    (string-match-p vigil-purpose-doc-files file)))
                             changed))
           (code (seq-remove (lambda (file) (or (member file tests) (member file docs)))
                             changed))
           found)
      (when code (push (cons 'code (concat (vigil-purpose--files-said code) by)) found))
      (when tests (push (cons 'tests (concat (vigil-purpose--files-said tests) by)) found))
      (when docs (push (cons 'docs (concat (vigil-purpose--files-said docs) by)) found))
      (when (and said (null named))
        (push (cons 'write "the Python inside it writes a file whose name is worked out")
              found))
      (pcase-dolist (`(,tag . ,regexps) vigil-purpose-rules)
        (when-let* ((matches (vigil-purpose--matches regexps text)))
          (push (cons tag
                      (concat (string-join (seq-take matches 3) ", ")
                              (if-let* (((eq tag 'test))
                                        (said (vigil-purpose--result-said result)))
                                  (concat ": " said)
                                "")))
                found)))
      ;; A program that only asserts is a test of something, whatever runs it.
      (when (and (> asserts 0) (not (assq 'test found)))
        (push (cons 'test (format "%d assertion%s in the Python it runs"
                                  asserts (if (= asserts 1) "" "s")))
              found))
      ;; It writes, by its words, and nothing says which files.
      (when (and (not (cl-some (lambda (tag) (memq (car tag) '(code tests docs write)))
                               found))
                 (vigil-purpose-writes-p command))
        (push (cons 'write "by its words: which files, nothing says") found))
      (cond
       (found (sort found (lambda (a b)
                            (< (cl-position (car a) vigil-purpose-names :key #'car)
                               (cl-position (car b) vigil-purpose-names :key #'car)))))
       ((vigil-purpose-looks-p command) (list (cons 'look "its programs only read")))
       (t (list (cons 'run "it ran something no rule knows")))))))

;;;; Names these went by

(define-obsolete-function-alias 'vigil-status-looks-p #'vigil-purpose-looks-p "0.8.0")
(define-obsolete-function-alias 'vigil-status-writes-p #'vigil-purpose-writes-p "0.8.0")

(provide 'vigil-purpose)
;;; vigil-purpose.el ends here
