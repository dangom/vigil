;;; vigil-codebase.el --- Where a repository is changing, and why -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; When agents write the code, the code is not read as it is written.  This
;; is for keeping a feel for it all the same: `M-x vigil-codebase' lists
;; the files of a repository that changed lately, and says of each
;;
;; - what kind of change it has seen: whether it is new, growing, or
;;   churning -- changed again and again, with as much taken out as put in;
;; - how often, how much and how lately, from git's log, with what is not
;;   committed yet counted as one more change;
;; - how many prompts its changes go back to, and how many commands
;;   exercised it and how the last went, from vigil's archive
;;   (vigil-history.el) -- and whether it has changed since it was last
;;   exercised.
;;
;; The line over the list answers the first question for the whole
;; repository: how much of what was added went into new files, and how much
;; was taken out for each line put in.
;;
;; RET on a file shows it alone: the functions of it that changed most
;; often (as git's hunks name them), its commits, the prompts behind its
;; changes, and the commands that exercised it, each with how often.
;;
;; Git is asked for its log and its diffs, and the archive is read.  What
;; git said of a commit is kept, in a cache of this file's own
;; (`vigil-codebase-cache-directory'), since a commit does not change; so is
;; what was read of the archive.  Nothing else is written, and nothing here
;; needs the rest of vigil, cooked or magit: where magit is loaded, a commit
;; is shown by it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'vigil-history)
(require 'vigil-git)
(require 'vigil-base)

(declare-function magit-show-commit "ext:magit-diff")

(defgroup vigil-codebase nil
  "Where a repository is changing, and why."
  :group 'vigil)

(defcustom vigil-codebase-days 30
  "How many days back the changes of a repository are looked at."
  :type 'natnum)

(defcustom vigil-codebase-churn 0.35
  "A file churns when this many lines were taken out for each one put in.
And it changed in `vigil-codebase-churn-commits' commits or more: one
rewrite is not churn."
  :type 'number)

(defcustom vigil-codebase-churn-commits 3
  "How many changes of a file it takes for it to be said to churn."
  :type 'natnum)

(defcustom vigil-codebase-languages
  '(("py" . "python") ("rs" . "rust") ("rb" . "ruby") ("go" . "golang")
    ("sh" . "bash") ("bash" . "bash") ("zsh" . "bash") ("md" . "markdown")
    ("c" . "cpp") ("h" . "cpp") ("cc" . "cpp") ("cpp" . "cpp") ("hpp" . "cpp")
    ("java" . "java") ("kt" . "kotlin") ("php" . "php") ("css" . "css")
    ("html" . "html") ("tex" . "tex") ("ex" . "elixir") ("exs" . "elixir")
    ("pl" . "perl") ("scm" . "scheme") ("cs" . "csharp")
    ("el" . "vigil-lisp") ("js" . "vigil-js") ("mjs" . "vigil-js")
    ("ts" . "vigil-js") ("tsx" . "vigil-js") ("jsx" . "vigil-js"))
  "Which of git's ways of naming a hunk's function a file gets, by extension.
Git names the function a change is in by a pattern for the language, and
knows the language only where the repository's own attributes say it.
These are used where they do not: git's own patterns by their names, and
those of `vigil-codebase-patterns'."
  :type '(alist :key-type string :value-type string))

(defcustom vigil-codebase-patterns
  '(("vigil-lisp" . "^\\((def[^ \t]*[ \t]+[^ \t)]+)")
    ("vigil-js" . "^[ \t]*((export[ \t]+|default[ \t]+|async[ \t]+)*(function|class)[ \t*]+[A-Za-z0-9_$]+)"))
  "Patterns for naming a hunk's function that git has none of its own for.
Each (NAME . REGEXP), as git's `diff.NAME.xfuncname' takes one."
  :type '(alist :key-type string :value-type string))

(defface vigil-codebase-new '((t :inherit success))
  "A file that is new.")

(defface vigil-codebase-churning '((t :inherit warning :weight bold))
  "A file that keeps being changed.")

(defface vigil-codebase-stale '((t :inherit warning))
  "A file changed since it was last exercised.")

;;;; What git says

(defun vigil-codebase--parse-buffer ()
  "The commits this buffer says, what `git log -p -U0' printed: plists.
The buffer holds git's bytes as they came.  Each commit :hash, :time,
:author, :subject and :files; each file a plist with :file, :added,
:removed, :created, :deleted and :hunks, a list of (CONTEXT ADDED REMOVED)
-- CONTEXT being what git names the hunk by, the function it is in.  A
diff with no commit over it is one without a hash: what is not committed.

Only the lines that head a commit, a file or a hunk are looked at: a hunk's
own line says how many lines it adds and removes, and no line of a change
begins as one of these does."
  (let ((decode (lambda (string) (decode-coding-string string 'utf-8 t)))
        (case-fold-search nil)
        commits commit file in-hunk)
    (goto-char (point-min))
    (while (re-search-forward
            (concat "^\\(?:\x01\\(.*\\)"
                    "\\|diff --git .* b/\\(.*\\)"
                    "\\|\\(new\\|deleted\\) file mode.*"
                    "\\|@@ -[0-9]+\\(?:,\\([0-9]+\\)\\)? \\+[0-9]+\\(?:,\\([0-9]+\\)\\)? @@ ?\\(.*\\)\\)$")
            nil t)
      (cond
       ((match-beginning 1)
        (pcase-let ((`(,hash ,time ,author ,subject)
                     (split-string (funcall decode (match-string 1)) "\x02")))
          (setq commit (list :hash hash :time (string-to-number (or time "0"))
                             :author author :subject subject :files nil)
                file nil in-hunk nil)
          (push commit commits)))
       ((match-beginning 2)
        (unless commit
          (setq commit (list :hash nil :time (float-time) :author nil
                             :subject "Not committed" :files nil))
          (push commit commits))
        (setq file (list :file (funcall decode (match-string 2)) :added 0 :removed 0
                         :created nil :deleted nil :hunks nil)
              in-hunk nil)
        (plist-put commit :files (cons file (plist-get commit :files))))
       ((match-beginning 3)
        (when (and file (not in-hunk))
          (plist-put file (if (equal (match-string 3) "new") :created :deleted) t)))
       (file
        (let ((removed (if (match-beginning 4) (string-to-number (match-string 4)) 1))
              (added (if (match-beginning 5) (string-to-number (match-string 5)) 1)))
          (setq in-hunk t)
          (plist-put file :added (+ added (plist-get file :added)))
          (plist-put file :removed (+ removed (plist-get file :removed)))
          (plist-put file :hunks
                     (cons (list (string-trim (funcall decode (match-string 6)))
                                 added removed)
                           (plist-get file :hunks)))))))
    (dolist (commit commits)
      (plist-put commit :files (nreverse (plist-get commit :files)))
      (dolist (file (plist-get commit :files))
        (plist-put file :hunks (nreverse (plist-get file :hunks)))))
    (nreverse commits)))

(defun vigil-codebase--parse (text)
  "The commits TEXT says; see `vigil-codebase--parse-buffer'."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (encode-coding-string text 'utf-8 t))
    (vigil-codebase--parse-buffer)))

(defun vigil-codebase--untracked (root)
  "The files of ROOT git does not know yet, as one change not committed.
A commit as `vigil-codebase--parse' gives one, or nil if there are none."
  (let (files)
    (dolist (name (split-string
                   (or (vigil-git root "ls-files" "--others"
                                            "--exclude-standard")
                       "")
                   "\n" t))
      (let* ((path (expand-file-name name root))
             (size (file-attribute-size (file-attributes path))))
        (when (and size (< size (* 1024 1024)))
          (let ((lines (with-temp-buffer
                         (ignore-errors (insert-file-contents path))
                         (count-lines (point-min) (point-max)))))
            (push (list :file name :added lines :removed 0 :created t :deleted nil
                        :hunks (list (list "" lines 0)))
                  files)))))
    (and files (list :hash nil :time (float-time) :author nil
                     :subject "Not committed" :files (nreverse files)))))

(defun vigil-codebase--attributes ()
  "A file of attributes giving each language its way of naming functions.
For git's `core.attributesFile': the repository's own attributes come
before it.  The caller deletes it."
  (let ((file (make-temp-file "vigil-attributes")))
    (with-temp-file file
      (pcase-dolist (`(,extension . ,driver) vigil-codebase-languages)
        (insert (format "*.%s diff=%s\n" extension driver))))
    file))

(defun vigil-codebase--diff-options (attributes)
  "The options that make git name functions as ATTRIBUTES, a file, says."
  (cons "-c"
        (cons (concat "core.attributesFile=" attributes)
              (cl-mapcan (lambda (pattern)
                           (list "-c" (format "diff.%s.xfuncname=%s"
                                              (car pattern) (cdr pattern))))
                         vigil-codebase-patterns))))

(defun vigil-codebase--parse-counts ()
  "The commits this buffer says, what `git log --numstat --summary' printed.
As `vigil-codebase--parse-buffer' gives them, with no hunks: for each file
how many lines went in and out, and whether it was made or removed."
  (let ((decode (lambda (string) (decode-coding-string string 'utf-8 t)))
        (case-fold-search nil)
        commits commit)
    (goto-char (point-min))
    (while (re-search-forward
            (concat "^\\(?:\x01\\(.*\\)"
                    "\\|\\([0-9-]+\\)\t\\([0-9-]+\\)\t\\(.*\\)"
                    "\\| \\(create\\|delete\\) mode [0-9]+ \\(.*\\)\\)$")
            nil t)
      (cond
       ((match-beginning 1)
        (pcase-let ((`(,hash ,time ,author ,subject)
                     (split-string (funcall decode (match-string 1)) "\x02")))
          (setq commit (list :hash hash :time (string-to-number (or time "0"))
                             :author author :subject subject :files nil))
          (push commit commits)))
       ((match-beginning 2)
        (unless commit
          (setq commit (list :hash nil :time (float-time) :author nil
                             :subject "Not committed" :files nil))
          (push commit commits))
        (plist-put commit :files
                   (cons (list :file (funcall decode (match-string 4))
                               ;; A file that is not text has no lines: `-'.
                               :added (string-to-number (match-string 2))
                               :removed (string-to-number (match-string 3))
                               :created nil :deleted nil :hunks nil)
                         (plist-get commit :files))))
       (commit
        (when-let* ((name (funcall decode (match-string 6)))
                    (file (cl-find name (plist-get commit :files)
                                   :key (lambda (f) (plist-get f :file)) :test #'equal)))
          (plist-put file (if (equal (match-string 5) "create") :created :deleted) t)))))
    (dolist (commit commits)
      (plist-put commit :files (nreverse (plist-get commit :files))))
    (nreverse commits)))

(defvar vigil-codebase--known (make-hash-table :test #'equal)
  "The commits already read, by repository: a hash table from hash to commit.
A commit does not change, so each is read from git once.")

(defcustom vigil-codebase-cache-directory nil
  "Where the commits read of each repository are kept, to be read faster.
Nil for vigil/codebase under $XDG_CACHE_HOME, by default ~/.cache.  A
commit does not change, so what git said of one is kept and git is only
asked of new ones.  Deleting the directory loses nothing."
  :type '(choice (const :tag "Under the cache directory" nil) directory))

(defconst vigil-codebase--version 1
  "Which shape the commits kept have.  Another is read afresh.")

(defun vigil-codebase--cache-file (root)
  "Where the commits read of the repository at ROOT are kept."
  (expand-file-name
   (concat (secure-hash 'sha1 (expand-file-name root)) ".eld")
   (or vigil-codebase-cache-directory
       (expand-file-name "vigil/codebase"
                         (or (getenv "XDG_CACHE_HOME") "~/.cache")))))

(defun vigil-codebase--commits-known (root)
  "The commits already read of the repository at ROOT, by hash.
Those read in this Emacs, or kept by one before it."
  (or (gethash root vigil-codebase--known)
      (let ((known (make-hash-table :test #'equal))
            (cache (vigil-codebase--cache-file root)))
        (when (file-readable-p cache)
          (ignore-errors
            (pcase (with-temp-buffer
                     (insert-file-contents cache)
                     (read (current-buffer)))
              (`(,(pred (equal vigil-codebase--version)) ,(pred (equal root)) ,commits)
               (dolist (commit commits)
                 (puthash (plist-get commit :hash) commit known))))))
        (puthash root known vigil-codebase--known))))

(defun vigil-codebase--keep (root known)
  "Keep KNOWN, the commits read of the repository at ROOT, for next time.
Whatever goes wrong, nothing is kept and nothing is said: it is a cache."
  (ignore-errors
    (let ((cache (vigil-codebase--cache-file root))
          (print-length nil) (print-level nil)
          (coding-system-for-write 'utf-8-emacs)
          commits)
      (maphash (lambda (_hash commit) (push commit commits)) known)
      (make-directory (file-name-directory cache) t)
      (with-temp-file cache
        (prin1 (list vigil-codebase--version root commits) (current-buffer)))
      (set-file-modes cache #o600))))

(defun vigil-codebase-commits (root days &optional committed)
  "The changes of the repository at ROOT in the last DAYS days, newest first.
Commits as `vigil-codebase--parse-counts' gives them: how much each file
changed, not where.  First, as one without a hash, what is not committed:
the changes to files git knows and the files it does not know yet.  Git is
asked which commits there are, and for the changes of those not read
before.  With COMMITTED, only what is committed: nothing is asked of the
working tree."
  (let* ((known (vigil-codebase--commits-known root))
         (hashes (split-string
                  (or (vigil-git root "log" (format "--since=%d days ago" days)
                                           "--no-merges" "--format=%H")
                      "")
                  "\n" t))
         (missing (cl-remove-if (lambda (hash) (gethash hash known)) hashes)))
    (when missing
      (dolist (commit (vigil-git-parse
                       root #'vigil-codebase--parse-counts
                       (concat (string-join missing "\n") "\n")
                       "log" "--no-walk=unsorted" "--stdin" "--no-renames"
                       "--format=%x01%H%x02%at%x02%an%x02%s" "--numstat" "--summary"))
        (when (plist-get commit :hash)
          (puthash (plist-get commit :hash) commit known)))
      (vigil-codebase--keep root known))
    (let* ((commits (delq nil (mapcar (lambda (hash) (gethash hash known)) hashes)))
           (pending (and (not committed)
                         (car (vigil-git-parse
                          root #'vigil-codebase--parse-counts nil
                          "diff" "HEAD" "--no-renames" "--numstat" "--summary"))))
           (untracked (and (not committed) (vigil-codebase--untracked root)))
           (pending (cond ((and pending untracked)
                           (plist-put pending :files
                                      (append (plist-get pending :files)
                                              (plist-get untracked :files))))
                          (t (or pending untracked)))))
      (if pending (cons pending commits) commits))))

(defun vigil-codebase-functions (root file hashes)
  "The functions of FILE, of the repository at ROOT, that changed most often.
In the commits HASHES and in what is not committed: ((NAME TIMES ADDED
REMOVED)...), most times first.  NAME is what git names a hunk by, with the
patterns of `vigil-codebase-languages'.  Asked of one file at a time: git
is slow to name the functions of a whole repository's changes."
  (let* ((attributes (vigil-codebase--attributes))
         (options (vigil-codebase--diff-options attributes))
         (changes
          (unwind-protect
              (append
               (and hashes
                    (apply #'vigil-git-parse
                           root #'vigil-codebase--parse-buffer
                           (concat (string-join hashes "\n") "\n")
                           (append options
                                   (list "log" "--no-walk=unsorted" "--stdin"
                                         "--no-renames" "--format=%x01%H" "-p" "-U0"
                                         "--" file))))
               (apply #'vigil-git-parse
                      root #'vigil-codebase--parse-buffer nil
                      (append options
                              (list "diff" "HEAD" "--no-renames" "-U0" "--" file))))
            (delete-file attributes)))
         (functions (make-hash-table :test #'equal))
         list)
    (dolist (commit changes)
      (dolist (changed (plist-get commit :files))
        (let ((seen nil))
          (pcase-dolist (`(,context ,plus ,minus) (plist-get changed :hunks))
            (unless (string-empty-p context)
              (let ((entry (or (gethash context functions)
                               (puthash context (list 0 0 0) functions))))
                (unless (member context seen)
                  (push context seen)
                  (cl-incf (nth 0 entry)))
                (cl-incf (nth 1 entry) plus)
                (cl-incf (nth 2 entry) minus)))))))
    (maphash (lambda (context entry) (push (cons context entry) list)) functions)
    (sort list (lambda (a b) (or (> (nth 1 a) (nth 1 b))
                                 (and (= (nth 1 a) (nth 1 b))
                                      (> (+ (nth 2 a) (nth 3 a))
                                         (+ (nth 2 b) (nth 3 b)))))))))

;;;; A file's changes

(defun vigil-codebase--kind (commits added removed created exists)
  "What kind of change a file has seen, as a word.
In COMMITS changes, ADDED lines put in and REMOVED taken out; CREATED if it
was made among them, and EXISTS if it is still there."
  (let ((churns (and (>= commits vigil-codebase-churn-commits)
                     (>= removed (* vigil-codebase-churn (max 1 added))))))
    (cond ((not exists) "gone")
          ((and created churns) "new, reworked")
          (created "new")
          (churns "churning")
          ((> added (* 2 removed)) "growing")
          (t "changed"))))

(defun vigil-codebase-files (commits root &optional present)
  "What COMMITS did to each file of the repository at ROOT: plists.
Each :file, :commits (those that changed it, newest first, each with the
file's own entry as (COMMIT . FILE)), :added, :removed, :created, :exists,
:last (when it last changed) and :kind.  The most changed first.
PRESENT, a hash table of the files that are there now by name, saves asking
the file system of each."
  (let ((table (make-hash-table :test #'equal))
        files)
    (dolist (commit commits)
      (dolist (file (plist-get commit :files))
        (push (cons commit file) (gethash (plist-get file :file) table))))
    (maphash
     (lambda (name changes)
       (let* ((changes (nreverse changes))
              (added 0) (removed 0) (created nil)
              (exists (if present
                          (and (gethash name present)
                               (not (plist-get (cdr (car changes)) :deleted)))
                        (file-exists-p (expand-file-name name root)))))
         (dolist (change changes)
           (cl-incf added (plist-get (cdr change) :added))
           (cl-incf removed (plist-get (cdr change) :removed))
           (when (plist-get (cdr change) :created) (setq created t)))
         (push (list :file name :commits changes :added added :removed removed
                     :created created :exists exists
                     :last (plist-get (car (car changes)) :time)
                     :kind (vigil-codebase--kind (length changes) added removed
                                                 created exists))
               files)))
     table)
    (sort files (lambda (a b)
                  (let ((na (length (plist-get a :commits)))
                        (nb (length (plist-get b :commits))))
                    (or (> na nb)
                        (and (= na nb) (> (plist-get a :last) (plist-get b :last)))))))))

(defun vigil-codebase-summary (files commits)
  "What FILES, of COMMITS, say of the repository as a whole: a plist.
:commits, :files, :new (files made), :added, :removed, :into-new (the share
of the lines added that went into files made among them, 0 to 1) and
:rework (lines taken out for each put in)."
  (let* ((added (apply #'+ (mapcar (lambda (f) (plist-get f :added)) files)))
         (removed (apply #'+ (mapcar (lambda (f) (plist-get f :removed)) files)))
         (new (cl-remove-if-not (lambda (f) (plist-get f :created)) files))
         (into-new (apply #'+ (mapcar (lambda (f) (plist-get f :added)) new))))
    (list :commits (cl-count-if (lambda (c) (plist-get c :hash)) commits)
          :files (length files) :new (length new)
          :added added :removed removed
          :into-new (if (> added 0) (/ (float into-new) added) 0.0)
          :rework (if (> added 0) (/ (float removed) added) 0.0))))

;;;; With what the archive says

(defun vigil-codebase--since (history file from)
  "What the archive says of FILE of HISTORY since FROM, a time: a plist.
:prompts, how many prompts its changes go back to; :runs, the commands
that exercised it, as `vigil-history-runs' gives them; :last-run, the
newest; :last-edit, when an agent last changed it."
  (let* ((recent (lambda (time) (>= (or time 0) from)))
         (prompts (cl-remove-if-not
                   (lambda (entry)
                     (and (car entry) (funcall recent (plist-get (car entry) :time))))
                   (vigil-history-prompts-of history file)))
         (runs (cl-remove-if-not
                (lambda (run) (funcall recent (plist-get (car run) :time)))
                (vigil-history-runs history file)))
         (changes (append (vigil-history-edits history file)
                          (vigil-history-writes history file))))
    (list :prompts (length prompts) :runs runs :last-run (car runs)
          :last-edit (and changes
                          (apply #'max (mapcar (lambda (c) (plist-get c :time)) changes))))))

(defun vigil-codebase--stale-p (file said)
  "Whether FILE, a plist, changed after it was last exercised, by SAID.
SAID is what `vigil-codebase--since' gave of it.  A file never exercised is
not stale: nothing is known to run it."
  (when-let* ((run (plist-get said :last-run)))
    (let ((ran (plist-get (car run) :time)))
      (or (> (or (plist-get said :last-edit) 0) ran)
          (> (plist-get file :last) (+ ran 1))))))

;;;; For others to say of a file

(defvar vigil-codebase--stats (make-hash-table :test #'equal)
  "What was last worked out of each repository's files, by its root.
Each (HEAD TIME . TABLE): good while HEAD is its head and TIME is recent.")

(defun vigil-codebase-stats (root &optional days)
  "What is known of each file of the repository at ROOT that changed lately.
A hash table from a file's name to a plist: :kind, :changes, :added,
:removed, :last, :prompts, :runs (how many commands exercised it),
:last-run (the newest, a command of the archive) and :stale (whether it
changed since).  Of what is committed, over DAYS days, by default
`vigil-codebase-days'.  For showing beside a file wherever it is named: it
is worked out again only when the repository's head has moved, or after a
minute."
  (let* ((days (or days vigil-codebase-days))
         (head (string-trim (or (vigil-git root "rev-parse" "HEAD") "")))
         (key (cons root days))
         (known (gethash key vigil-codebase--stats)))
    (if (and known (equal (car known) head) (< (- (float-time) (cadr known)) 60))
        (cddr known)
      (let* ((commits (vigil-codebase-commits root days t))
             (tracked (split-string (or (vigil-git root "ls-files") "") "\n" t))
             (present (make-hash-table :test #'equal))
             (table (make-hash-table :test #'equal))
             (from (- (float-time) (* 86400 days)))
             (history nil))
        (dolist (name tracked) (puthash name t present))
        (setq history (vigil-history root tracked))
        (dolist (file (vigil-codebase-files commits root present))
          (let* ((name (plist-get file :file))
                 (said (vigil-codebase--since history name from)))
            (puthash name
                     (list :kind (plist-get file :kind)
                           :changes (length (plist-get file :commits))
                           :added (plist-get file :added)
                           :removed (plist-get file :removed)
                           :last (plist-get file :last)
                           :prompts (plist-get said :prompts)
                           :runs (length (plist-get said :runs))
                           :last-run (car (plist-get said :last-run))
                           :stale (vigil-codebase--stale-p file said))
                     table)))
        (puthash key (cons head (cons (float-time) table)) vigil-codebase--stats)
        table))))

(defun vigil-codebase-badge (stats)
  "STATS, a file's of `vigil-codebase-stats', in a few words; nil if none.
\"churning · 7 changes · 3 prompts · ran 2h ago ok, changed since\"."
  (when stats
    (let ((changes (plist-get stats :changes))
          (run (plist-get stats :last-run)))
      (string-join
       (delq nil
             (list (propertize (plist-get stats :kind)
                               'face (vigil-codebase--kind-face (plist-get stats :kind)))
                   (format "%d change%s" changes (if (= changes 1) "" "s"))
                   (and (> (plist-get stats :prompts) 0)
                        (format "%d prompt%s" (plist-get stats :prompts)
                                (if (= (plist-get stats :prompts) 1) "" "s")))
                   (and run
                        (concat "ran " (vigil-codebase--when (plist-get run :time)) " "
                                (vigil-codebase--status run)
                                (if (plist-get stats :stale)
                                    (propertize ", changed since"
                                                'face 'vigil-codebase-stale)
                                  "")))))
       " · "))))

;;;; Saying when

(defun vigil-codebase--ago (time)
  "How long ago TIME was, shortly: 5m, 3h, 12d."
  (let ((seconds (max 0 (- (float-time) time))))
    (cond ((< seconds 90) "now")
          ((< seconds 5400) (format "%dm" (round seconds 60)))
          ((< seconds 129600) (format "%dh" (round seconds 3600)))
          (t (format "%dd" (round seconds 86400))))))

(defun vigil-codebase--when (time)
  "How long ago TIME was, as words: \"3h ago\", \"just now\"."
  (let ((ago (vigil-codebase--ago time)))
    (if (equal ago "now") "just now" (concat ago " ago"))))

(defun vigil-codebase--status (command)
  "A mark for how COMMAND, a command of the archive, went."
  (pcase (plist-get command :status)
    ('done (propertize "ok" 'face 'success))
    ('interrupted (propertize "interrupted" 'face 'warning))
    (_ (propertize "failed" 'face 'error))))

;;;; The list

(defvar-local vigil-codebase--root nil "The repository this buffer is of.")
(defvar-local vigil-codebase--days nil "How many days back it looks.")
(defvar-local vigil-codebase--files nil "Its files, as `vigil-codebase-files'.")
(defvar-local vigil-codebase--history nil "What the archive says of it.")
(defvar-local vigil-codebase--commits nil "Its changes.")

(defun vigil-codebase--kind-face (kind)
  "The face KIND, a word for what a file has seen, is shown in."
  (pcase kind
    ((or "churning" "new, reworked") 'vigil-codebase-churning)
    ("new" 'vigil-codebase-new)
    ("gone" 'shadow)
    (_ 'default)))

(defun vigil-codebase--entries ()
  "The rows of the list: a file each, the most changed first."
  (let ((from (- (float-time) (* 86400 vigil-codebase--days)))
        (history vigil-codebase--history))
    (mapcar
     (lambda (file)
       (let* ((name (plist-get file :file))
              (said (vigil-codebase--since history name from))
              (run (plist-get said :last-run))
              (stale (vigil-codebase--stale-p file said))
              (commits (length (plist-get file :commits))))
         (list name
               (vector
                (propertize name 'face (if (plist-get file :exists) 'default 'shadow))
                (propertize (plist-get file :kind)
                            'face (vigil-codebase--kind-face (plist-get file :kind)))
                (vigil-base-number (number-to-string commits) commits)
                (vigil-base-number (format "+%d" (plist-get file :added))
                                        (plist-get file :added))
                (vigil-base-number (format "-%d" (plist-get file :removed))
                                        (plist-get file :removed))
                (vigil-base-number (vigil-codebase--ago (plist-get file :last))
                                        (plist-get file :last))
                (vigil-base-number (if (> (plist-get said :prompts) 0)
                                            (number-to-string (plist-get said :prompts))
                                          "")
                                        (plist-get said :prompts))
                (vigil-base-number (if run
                                            (number-to-string (length (plist-get said :runs)))
                                          "")
                                        (length (plist-get said :runs)))
                (if (null run)
                    ""
                  (concat (vigil-codebase--ago (plist-get (car run) :time)) " "
                          (vigil-codebase--status (car run))
                          (if stale
                              (propertize ", changed since" 'face 'vigil-codebase-stale)
                            "")))))))
     vigil-codebase--files)))

(defun vigil-codebase--header ()
  "The line over the list: what the changes come to, for the repository."
  (let ((s (vigil-codebase-summary vigil-codebase--files vigil-codebase--commits)))
    (string-replace
     "%" "%%"
     (format " %s  ·  %d days  ·  %d commits  ·  %d files changed, %d new  ·  +%d -%d  ·  %d%% of what was added is in new files  ·  %.2f lines out for each one in"
             (abbreviate-file-name (directory-file-name vigil-codebase--root))
             vigil-codebase--days (plist-get s :commits) (plist-get s :files)
             (plist-get s :new) (plist-get s :added) (plist-get s :removed)
             (round (* 100 (plist-get s :into-new))) (plist-get s :rework)))))

(defun vigil-codebase--load ()
  "Read this buffer's repository again: git's log, and the archive."
  (let* ((root vigil-codebase--root)
         (commits (vigil-codebase-commits root vigil-codebase--days))
         (tracked (split-string (or (vigil-git root "ls-files") "") "\n" t))
         (present (make-hash-table :test #'equal)))
    (dolist (name tracked) (puthash name t present))
    ;; And the files git does not know yet, which are of what is not committed.
    (unless (plist-get (car commits) :hash)
      (dolist (file (plist-get (car commits) :files))
        (when (plist-get file :created) (puthash (plist-get file :file) t present))))
    (setq vigil-codebase--commits commits
          vigil-codebase--files (vigil-codebase-files commits root present)
          vigil-codebase--history
          (vigil-history root
                         (delete-dups
                          (append tracked
                                  (mapcar (lambda (f) (plist-get f :file))
                                          vigil-codebase--files)))))))

(defvar vigil-codebase-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-codebase-file)
    (define-key map (kbd "v") #'vigil-codebase-visit)
    (define-key map (kbd "d") #'vigil-codebase-days)
    map)
  "Keys of `vigil-codebase-mode'.")

(define-derived-mode vigil-codebase-mode tabulated-list-mode "Codebase"
  "The files of a repository that changed lately, the most changed first.
\\{vigil-codebase-mode-map}"
  (setq tabulated-list-format
        `[("File" 38 t) ("Kind" 14 t)
          ("Changes" 7 ,(vigil-base-by-number 2) :right-align t)
          ("In" 6 ,(vigil-base-by-number 3) :right-align t)
          ("Out" 6 ,(vigil-base-by-number 4) :right-align t)
          ("Last" 5 ,(vigil-base-by-number 5) :right-align t)
          ("Prompts" 7 ,(vigil-base-by-number 6) :right-align t)
          ("Runs" 5 ,(vigil-base-by-number 7) :right-align t)
          ("Last run" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'vigil-codebase--entries)
  ;; The columns' names are a line of the buffer: the header line says what
  ;; the changes come to.
  (setq-local tabulated-list-use-header-line nil)
  (setq-local mode-line-format
              " RET the file  v visit  d days  g look again  q quit")
  (add-hook 'tabulated-list-revert-hook #'vigil-codebase--reload nil t))

(defun vigil-codebase--reload ()
  "Read the repository again, before the list is drawn again."
  (vigil-codebase--load)
  (setq header-line-format (vigil-codebase--header)))

;;;###autoload
(defun vigil-codebase (&optional directory days)
  "List the files that changed lately in the repository DIRECTORY is in.
By default this buffer's, over the last `vigil-codebase-days' days; with a
prefix argument, over that many DAYS.  See vigil-codebase.el."
  (interactive (list nil (and current-prefix-arg
                              (prefix-numeric-value current-prefix-arg))))
  (let* ((root (or (vigil-git-root directory)
                   (user-error "Not in a git repository")))
         (buffer (get-buffer-create
                  (format "*vigil codebase: %s*"
                          (file-name-nondirectory (directory-file-name root))))))
    (with-current-buffer buffer
      (vigil-codebase-mode)
      (setq vigil-codebase--root root
            vigil-codebase--days (or days vigil-codebase-days)
            default-directory root)
      (vigil-codebase--load)
      (setq header-line-format (vigil-codebase--header))
      (tabulated-list-print))
    (pop-to-buffer buffer)
    buffer))

(defun vigil-codebase-days (days)
  "Look DAYS days back, in this list."
  (interactive (list (read-number "Days back: " vigil-codebase--days)))
  (setq vigil-codebase--days (max 1 (round days)))
  (revert-buffer))

(defun vigil-codebase--at-point ()
  "The file on this line, as a plist, or an error saying there is none."
  (or (cl-find (tabulated-list-get-id) vigil-codebase--files
               :key (lambda (file) (plist-get file :file)) :test #'equal)
      (user-error "No file on this line")))

(defun vigil-codebase-visit ()
  "Visit the file on this line."
  (interactive)
  (let ((file (expand-file-name (plist-get (vigil-codebase--at-point) :file)
                                vigil-codebase--root)))
    (unless (file-exists-p file) (user-error "It is no longer there"))
    (find-file-other-window file)))

;;;; One file

(defun vigil-codebase--button (text action help)
  "TEXT as a button doing ACTION, a function of no arguments; HELP says what."
  ;; The button is the string it gives back: the one it is given is left.
  (make-text-button (copy-sequence text) nil
                    'action (lambda (_) (funcall action))
                    'follow-link t
                    'help-echo help))

(defun vigil-codebase--show-text (title text)
  "Show TEXT whole, under TITLE, in a buffer of its own."
  (with-current-buffer (get-buffer-create "*vigil codebase: text*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize title 'face 'bold) "\n\n" text "\n")
      (goto-char (point-min)))
    (special-mode)
    (setq-local word-wrap t)
    (display-buffer (current-buffer))
    (current-buffer)))

(defun vigil-codebase--show-commit (root hash)
  "Show the commit HASH of the repository at ROOT: by magit, if it is there."
  (let ((default-directory root))
    (if (fboundp 'magit-show-commit)
        (magit-show-commit hash)
      (with-current-buffer (get-buffer-create (format "*vigil codebase: %s*"
                                                      (substring hash 0 8)))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or (vigil-git root "show" "--stat" "-p" hash) ""))
          (goto-char (point-min)))
        (diff-mode)
        (setq buffer-read-only t)
        (display-buffer (current-buffer))))))

;; What changed after a prompt is vigil-snapshot.el's to show, which is
;; loaded when it is first asked.
(autoload 'vigil-snapshot-show "vigil-snapshot")

(defun vigil-codebase-prompt-changes ()
  "Show what changed in the repository after the prompt at point.
The diff between the snapshot kept when it was given and the one kept when
its agent stopped; see vigil-snapshot.el."
  (interactive)
  (let ((prompt (or (get-text-property (point) 'vigil-prompt)
                    (user-error "No prompt here")))
        (root (or (vigil-git-root) (user-error "Not in a repository"))))
    (vigil-snapshot-show root prompt)))

(defvar vigil-codebase-prompt-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map (kbd "d") #'vigil-codebase-prompt-changes)
    map)
  "Keys on a prompt, wherever one is listed.")

(defun vigil-codebase-insert-prompt (prompt &optional note)
  "Insert a line for PROMPT, a prompt of the archive, with NOTE after it."
  (insert "  " (propertize (format-time-string "%Y-%m-%d %H:%M" (plist-get prompt :time))
                           'face 'shadow)
          "  "
          (propertize
           (vigil-codebase--button
            (vigil-base-one-line (plist-get prompt :text) 78)
            (lambda ()
              (vigil-codebase--show-text
               (format "Prompt, %s%s"
                       (format-time-string "%Y-%m-%d %H:%M" (plist-get prompt :time))
                       (if (plist-get prompt :host)
                           (format ", to %s" (plist-get prompt :host))
                         ""))
               (plist-get prompt :text)))
            "RET: the whole prompt.  d: what changed after it")
           'vigil-prompt prompt
           'keymap vigil-codebase-prompt-map)
          (if note (propertize (concat "  " note) 'face 'shadow) "")
          "\n"))

(defun vigil-codebase--group-runs (runs)
  "RUNS, as `vigil-history-runs' gives them, by their commands' text.
Each (TEXT COUNT LAST HOWS FUNCTIONS): how often it ran, its newest run,
how it exercised the file, and the functions of the file it ran, if known."
  (let ((table (make-hash-table :test #'equal)) order)
    (pcase-dolist (`(,command ,how . ,detail) runs)
      (let* ((text (plist-get command :command))
             (entry (or (gethash text table)
                        (progn (push text order)
                               (puthash text (list text 0 command nil nil) table)))))
        (cl-incf (nth 1 entry))
        (cl-pushnew how (nth 3 entry))
        (when (eq how 'ran)
          (dolist (function detail)
            (cl-pushnew function (nth 4 entry) :test #'equal)))))
    (sort (mapcar (lambda (text) (gethash text table)) order)
          (lambda (a b) (> (nth 1 a) (nth 1 b))))))

(defun vigil-codebase--insert-file (file history root days)
  "Insert what is known of FILE, a plist, of the repository at ROOT.
Over the last DAYS days; HISTORY is what the archive says."
  (let* ((name (plist-get file :file))
         (from (- (float-time) (* 86400 days)))
         (said (vigil-codebase--since history name from))
         (section (lambda (title) (insert "\n" (propertize title 'face 'bold) "\n"))))
    (insert (propertize name 'face 'bold) "\n"
            (propertize
             (format "%s  ·  %d changes in %d days  ·  +%d -%d  ·  last %s%s\n"
                     (plist-get file :kind) (length (plist-get file :commits)) days
                     (plist-get file :added) (plist-get file :removed)
                     (vigil-codebase--when (plist-get file :last))
                     (if (vigil-codebase--stale-p file said)
                         "  ·  changed since it was last exercised"
                       ""))
             'face 'shadow))
    (when-let* ((functions
                 (vigil-codebase-functions
                  root name
                  (delq nil (mapcar (lambda (change) (plist-get (car change) :hash))
                                    (plist-get file :commits))))))
      (funcall section "Changed most often")
      (pcase-dolist (`(,context ,times ,added ,removed) (take 12 functions))
        (insert (format "  %3d×  %s" times (vigil-base-one-line context 70))
                (propertize (format "  +%d -%d\n" added removed) 'face 'shadow))))
    (funcall section "Changes")
    (pcase-dolist (`(,commit . ,change) (plist-get file :commits))
      (let ((hash (plist-get commit :hash)))
        (insert "  " (propertize (format-time-string "%Y-%m-%d %H:%M" (plist-get commit :time))
                                 'face 'shadow)
                "  "
                (if hash
                    (vigil-codebase--button
                     (substring hash 0 (min 8 (length hash)))
                     (lambda () (vigil-codebase--show-commit root hash))
                     "RET: the commit")
                  (propertize "--------" 'face 'shadow))
                "  " (vigil-base-one-line (or (plist-get commit :subject) "") 60)
                (propertize (format "  +%d -%d%s\n" (plist-get change :added)
                                    (plist-get change :removed)
                                    (cond ((plist-get change :created) "  made")
                                          ((plist-get change :deleted) "  removed")
                                          (t "")))
                            'face 'shadow))))
    (funcall section "Prompts behind its changes")
    (let ((prompts (vigil-history-prompts-of history name)))
      (if (null prompts)
          (insert (propertize "  (none in the archive: not changed by an agent's edits, or before the archive)\n"
                              'face 'shadow))
        (pcase-dolist (`(,prompt ,edits ,writes) prompts)
          (let ((note (string-join
                       (delq nil (list (and (> edits 0)
                                            (format "%d edit%s" edits (if (= edits 1) "" "s")))
                                       (and (> writes 0)
                                            (format "%d command%s that wrote it" writes
                                                    (if (= writes 1) "" "s")))))
                       ", ")))
            (if prompt
                (vigil-codebase-insert-prompt prompt note)
              (insert (propertize (format "  (a prompt not kept)  %s\n" note)
                                  'face 'shadow)))))))
    (funcall section "Exercised by")
    (let ((groups (vigil-codebase--group-runs (vigil-history-runs history name))))
      (if (null groups)
          (insert (propertize "  (no command is known to have named it, mentioned it or run it)\n"
                              'face 'shadow))
        (pcase-dolist (`(,text ,count ,last ,hows ,functions) groups)
          (insert (format "  %3d×  " count)
                  (vigil-codebase--button
                   (vigil-base-one-line text 70)
                   (lambda () (vigil-codebase--show-text "Command" text))
                   "RET: the whole command")
                  (propertize (format "  %s  ·  last %s  "
                                      ;; What says most first.
                                      (mapconcat #'symbol-name
                                                 (cl-remove-if-not
                                                  (lambda (how) (memq how hows))
                                                  '(ran mentioned named))
                                                 ", ")
                                      (vigil-codebase--when (plist-get last :time)))
                              'face 'shadow)
                  (vigil-codebase--status last)
                  "\n")
          (when functions
            (insert (propertize
                     (format "        ran: %s\n"
                             (vigil-base-one-line
                              (string-join (sort (copy-sequence functions) #'string<) ", ")
                              110))
                     'face 'shadow))))))))

(defvar vigil-codebase-file-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keys of `vigil-codebase-file-mode'.")

(define-derived-mode vigil-codebase-file-mode special-mode "Codebase file"
  "One file of a repository: what changed in it, why, and what runs it.
\\{vigil-codebase-file-mode-map}"
  (setq-local mode-line-format " RET what is at point  TAB next  q quit"))

(defun vigil-codebase-file ()
  "Show the file on this line alone: what changed in it, why, and what runs it."
  (interactive)
  (let* ((file (vigil-codebase--at-point))
         (history vigil-codebase--history)
         (root vigil-codebase--root)
         (days vigil-codebase--days)
         (buffer (get-buffer-create
                  (format "*vigil codebase: %s*" (plist-get file :file)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (vigil-codebase--insert-file file history root days)
        (goto-char (point-min)))
      (vigil-codebase-file-mode)
      (setq default-directory root))
    (pop-to-buffer buffer)
    buffer))

(provide 'vigil-codebase)
;;; vigil-codebase.el ends here
