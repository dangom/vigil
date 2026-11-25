;;; vigil-effects.el --- What each command changed -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; An agent changes most files with commands, not with its editing tools: a
;; `sed -i', a script handed to python.  The report of a command says what it
;; printed and nothing of what it changed.
;;
;; With snapshots on (`vigil snapshots on'), bin/vigil keeps one of the
;; repository before and after each command, where the files had changed
;; (see there, and vigil-snapshot.el).  This reads them, for the agents open
;; in this Emacs, and makes of each command that changed files what an edit
;; already is:
;;
;; - inspected, the command is shown with the files it changed and their
;;   diff, under what it printed;
;; - in a turn's list it says which files it changed;
;; - the lines it wrote are marked as its own in the files' buffers, and what
;;   it changed is in the turn's diff (vigil-edits.el): each file it changed
;;   is an edit of that call, from the file before it to the file after.
;;
;; What is not known this way:
;;
;; - Two commands run at once, or a command and something else at work in the
;;   repository while it ran: what changed in that time is the command's that
;;   ended last.  A snapshot is of the repository.
;; - A command left running in the background has ended, as far as its report
;;   goes, before it has changed anything.  What it changes later is nobody's,
;;   and is kept before the next command as such.
;; - Files outside the repository the command was run in, files git ignores,
;;   and files over the size a snapshot keeps.
;;
;; Only git is run, to read what was kept; nothing is changed, and nothing of
;; a file is evaluated.  Needs vigil.el, vigil-snapshot.el and git.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil)
(require 'vigil-git)
(require 'vigil-snapshot)

(declare-function vigil-edits--update "vigil-edits")

(defgroup vigil-effects nil
  "What each command an agent ran changed."
  :group 'vigil)

(defcustom vigil-effects-max-file-size (* 1024 1024)
  "The biggest file, in bytes, whose lines a command wrote are followed.
A bigger one the command changed is still named."
  :type 'natnum)

(defcustom vigil-effects-diff-lines 200
  "How many lines of a command's diff are shown where it is inspected."
  :type 'natnum)

(defcustom vigil-effects-delay 0.4
  "Seconds after an agent's reports before the snapshots are looked at.
The snapshot after a command is kept as its report is written, not before."
  :type 'number)

(defcustom vigil-effects-batch 25
  "How many commands' changes are read at once, before Emacs is let go on."
  :type 'natnum)

(defcustom vigil-effects-recent 200
  "How many of the newest snapshots are looked through for new ones."
  :type 'natnum)

(defvar vigil-effects-changed-hook nil
  "Run in an agent's buffer when more of what its commands changed is known.")

(cl-defstruct (vigil-effect (:constructor vigil-effect--make) (:copier nil))
  "What one command changed: two snapshots of the repository at ROOT.
FROM and TO are their commits; EVENT is the hook's event TO was kept for,
\"PostToolUseFailure\" for a command that failed.  FILES are plists, one for
each file that differs: :status, git's letter (A new, M changed, D gone);
:name, as the repository names it; :file, its true name; and :followed,
whether its lines are followed as an edit's are.  STAT and DIFF are what git
says of the two, asked for when first shown."
  root from to event files stat diff)

(defvar vigil-effects--of (make-hash-table :test #'eq :weakness 'key)
  "What each call changed, for the calls known to have changed something.")

(defvar vigil-effects--roots (make-hash-table :test #'equal)
  "The repository each directory a call ran in is in, or `none'.")

(defvar vigil-effects--blobs (make-hash-table :test #'equal :weakness 'value)
  "The text of each file read from a snapshot, by git's name for it.
Kept while an edit has it, so that one text is one string.")

(defvar-local vigil-effects--calls nil
  "The table of this agent's calls the rest here was worked out for.")

(defvar-local vigil-effects--tips nil
  "For each repository, the newest snapshot this agent's calls were looked for in.")

(defvar-local vigil-effects--pending nil
  "Calls whose snapshot is found and not yet read, oldest first.
Each (CALL ROOT SNAPSHOT).")

(defvar-local vigil-effects--timer nil
  "The timer that looks at the snapshots next.")

(defun vigil-effects-of (call)
  "What CALL, a command, changed: a `vigil-effect', or nil if nothing is known.
Nil for a command that changed nothing, and for one no snapshot was kept
around."
  (and call (gethash call vigil-effects--of)))

(defun vigil-effects-names (call)
  "The files CALL changed, as the repository names them."
  (when-let* ((effect (vigil-effects-of call)))
    (mapcar (lambda (file) (plist-get file :name)) (vigil-effect-files effect))))

;;;; Reading the snapshots

(defun vigil-effects--root (directory)
  "The repository DIRECTORY is in, or nil."
  (when (stringp directory)
    (let ((known (gethash directory vigil-effects--roots)))
      (unless known
        (setq known (or (and (file-directory-p directory)
                             (not (file-remote-p directory))
                             (vigil-git-root directory))
                        'none))
        (puthash directory known vigil-effects--roots))
      (and (stringp known) known))))

(defun vigil-effects--tip (root)
  "The newest snapshot kept of ROOT, or nil."
  (when-let* ((tip (vigil-git root "rev-parse" "-q" "--verify" vigil-snapshot-ref)))
    (string-trim tip)))

(defun vigil-effects--changes (root from to)
  "The files that differ between the snapshots FROM and TO of ROOT: plists.
:status and :name; :old and :new, git's names for the file's two texts; and
:plain, whether both are plain files, not links or repositories."
  (let ((words (split-string
                (or (vigil-git root "diff" "--raw" "--no-abbrev" "--no-renames" "-z"
                               from to "--")
                    "")
                "\0" t))
        found)
    (while (cdr words)
      (let ((fields (split-string (pop words) " " t))
            (name (pop words)))
        (when (= (length fields) 5)
          (push (list :status (nth 4 fields) :name name
                      :old (nth 2 fields) :new (nth 3 fields)
                      :plain (cl-every (lambda (mode)
                                         (member mode '("100644" "100755" "000000")))
                                       (list (string-remove-prefix ":" (nth 0 fields))
                                             (nth 1 fields))))
                found))))
    (nreverse found)))

(defun vigil-effects--null-p (name)
  "Whether NAME is git's name for no file at all."
  (string-match-p "\\`0+\\'" name))

(defun vigil-effects--read (root names)
  "Read the texts git names NAMES in ROOT into `vigil-effects--blobs'.
Gives them back as a list, so that they are kept until they are used.  A
text too big, or not text, is not read."
  (let ((wanted (cl-remove-if (lambda (name)
                                (or (vigil-effects--null-p name)
                                    (gethash name vigil-effects--blobs)))
                              (delete-dups (copy-sequence names))))
        (held (delq nil (mapcar (lambda (name) (gethash name vigil-effects--blobs))
                                names))))
    (when wanted
      (vigil-git-parse
       root
       (lambda ()
         (goto-char (point-min))
         (while (looking-at "\\([0-9a-f]+\\) \\([a-z]+\\)\\(?: \\([0-9]+\\)\\)?\n")
           (let ((name (match-string 1))
                 (kind (match-string 2))
                 (size (and (match-string 3) (string-to-number (match-string 3)))))
             (goto-char (match-end 0))
             (when size
               (let ((end (+ (point) size)))
                 (when (and (equal kind "blob")
                            (<= size vigil-effects-max-file-size)
                            (not (save-excursion (search-forward "\0" end t))))
                   (let ((text (decode-coding-string
                                (buffer-substring-no-properties (point) end) 'utf-8)))
                     (puthash name text vigil-effects--blobs)
                     (push text held)))
                 ;; The text, and the newline git ends it with.
                 (goto-char (min (point-max) (1+ end))))))))
       (concat (string-join wanted "\n") "\n")
       "cat-file" "--batch"))
    held))

(defun vigil-effects--text (name)
  "The text git names NAME: empty for no file, nil where it was not read."
  (if (vigil-effects--null-p name) "" (gethash name vigil-effects--blobs)))

;;;; A command's changes, as edits

(defun vigil-effects--add-edit (file edit)
  "Put EDIT among this agent's edits of FILE, where its call came."
  (puthash file
           (sort (append (gethash file vigil--edits) (list edit))
                 (lambda (a b)
                   (< (vigil--call-when (vigil-edit-call a))
                      (vigil--call-when (vigil-edit-call b)))))
           vigil--edits))

(defun vigil-effects--take (call root snapshot changes)
  "Keep what CALL changed in ROOT: CHANGES, up to SNAPSHOT.
In the agent's buffer, with the texts of CHANGES read."
  (let (files)
    (dolist (change changes)
      (let* ((file (file-truename (expand-file-name (plist-get change :name) root)))
             (before (and (plist-get change :plain)
                          (vigil-effects--text (plist-get change :old))))
             (after (and (plist-get change :plain)
                         (vigil-effects--text (plist-get change :new))))
             (followed (and before after t)))
        (when followed
          (vigil-effects--add-edit
           file (vigil-edit--make :call call :before before :after after)))
        (push (list :status (plist-get change :status) :name (plist-get change :name)
                    :file file :followed followed)
              files)))
    (puthash call
             (vigil-effect--make :root root
                                 :from (plist-get snapshot :before)
                                 :to (plist-get snapshot :commit)
                                 :event (plist-get snapshot :event)
                                 :files (nreverse files))
             vigil-effects--of)))

(defun vigil-effects--find ()
  "Find the snapshots kept after this agent's calls that are not read yet."
  (unless (eq vigil-effects--calls vigil--calls)
    ;; Its record was begun afresh: so is this.
    (setq vigil-effects--calls vigil--calls
          vigil-effects--tips nil
          vigil-effects--pending nil))
  (let (roots)
    (dolist (call vigil--order)
      (when-let* ((cwd (vigil-call-cwd call))
                  (root (vigil-effects--root cwd)))
        (cl-pushnew root roots :test #'equal)))
    (dolist (root roots)
      (let ((tip (vigil-effects--tip root))
            (seen (alist-get root vigil-effects--tips nil nil #'equal))
            found)
        (when (and tip (not (equal tip seen)))
          (dolist (snapshot (vigil-snapshot-list root (and seen vigil-effects-recent)))
            (when-let* (((member (plist-get snapshot :event)
                                 '("PostToolUse" "PostToolUseFailure")))
                        ((plist-get snapshot :before))
                        (id (plist-get snapshot :call))
                        (call (gethash id vigil--calls))
                        ((not (gethash call vigil-effects--of)))
                        ((not (assq call vigil-effects--pending))))
              (push (list call root snapshot) found)))
          (setq vigil-effects--pending (nconc vigil-effects--pending (nreverse found)))
          (setf (alist-get root vigil-effects--tips nil nil #'equal) tip))))))

(defun vigil-effects--work ()
  "Read what some of the calls waiting changed.  Whether any are left."
  (let* ((batch (seq-take vigil-effects--pending vigil-effects-batch))
         ;; Each (CALL ROOT SNAPSHOT CHANGES).
         (found (mapcar (pcase-lambda (`(,call ,root ,snapshot))
                          (list call root snapshot
                                (vigil-effects--changes root (plist-get snapshot :before)
                                                        (plist-get snapshot :commit))))
                        batch))
         ;; Every text of a repository at once.  The texts are held here until
         ;; the edits below have them: nothing else keeps them.
         (texts (mapcar (pcase-lambda (`(,root . ,of-root))
                          (vigil-effects--read
                           root
                           (cl-loop for (_call _root _snapshot changes) in of-root
                                    append (cl-loop for change in changes
                                                    when (plist-get change :plain)
                                                    collect (plist-get change :old)
                                                    and collect (plist-get change :new)))))
                        (seq-group-by #'cadr found)))
         (changed nil))
    (setq vigil-effects--pending (nthcdr (length batch) vigil-effects--pending))
    (pcase-dolist (`(,call ,root ,snapshot ,changes) found)
      (when changes
        (vigil-effects--take call root snapshot changes)
        (setq changed t)))
    (ignore texts)
    (when changed
      (cl-incf vigil-edits-made)
      (when (fboundp 'vigil-edits--update)
        (vigil-edits--update))
      (run-hooks 'vigil-effects-changed-hook))
    (and vigil-effects--pending t)))

(defun vigil-effects--look (buffer)
  "Look for what the commands of BUFFER's agent changed, and go on until read."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq vigil-effects--timer nil)
      (when vigil--calls
        (with-demoted-errors "vigil: could not read what a command changed: %S"
          (unless vigil-effects--pending
            (vigil-effects--find))
          (when (and vigil-effects--pending (vigil-effects--work))
            (setq vigil-effects--timer
                  (run-with-timer 0.05 nil #'vigil-effects--look buffer))))))))

(defun vigil-effects-update (&optional buffer)
  "Read now everything the commands of BUFFER's agent are known to have changed.
BUFFER is by default the current one.  What happens by itself, a little at a
time, shortly after each of the agent's reports."
  (with-current-buffer (or buffer (current-buffer))
    (when vigil-effects--timer
      (cancel-timer vigil-effects--timer)
      (setq vigil-effects--timer nil))
    (when vigil--calls
      (vigil-effects--find)
      (while (and vigil-effects--pending (vigil-effects--work))))))

(defun vigil-effects--schedule ()
  "Look at the snapshots shortly: this buffer's agent has reported.
On `vigil-changed-hook'."
  (when (and vigil--calls (not vigil-effects--timer))
    (setq vigil-effects--timer
          (run-with-timer vigil-effects-delay nil
                          #'vigil-effects--look (current-buffer)))))

;;;; Showing them

(defun vigil-effects--stat (effect)
  "For each file of EFFECT, by name, the lines put in and taken out: (IN . OUT).
Nil for a file git does not count the lines of."
  (or (vigil-effect-stat effect)
      (setf (vigil-effect-stat effect)
            (let ((words (split-string
                          (or (vigil-git (vigil-effect-root effect) "diff" "--numstat"
                                         "--no-renames" "-z"
                                         (vigil-effect-from effect) (vigil-effect-to effect)
                                         "--")
                              "")
                          "\0" t))
                  found)
              (dolist (word words)
                (when (string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t\\(.*\\)\\'" word)
                  (push (cons (match-string 3 word)
                              (and (not (equal (match-string 1 word) "-"))
                                   (cons (string-to-number (match-string 1 word))
                                         (string-to-number (match-string 2 word)))))
                        found)))
              (nreverse found)))))

(defun vigil-effects--diff (effect)
  "The diff of EFFECT, as text."
  (or (vigil-effect-diff effect)
      (setf (vigil-effect-diff effect)
            (or (vigil-git (vigil-effect-root effect) "diff" "--no-renames"
                           (vigil-effect-from effect) (vigil-effect-to effect) "--")
                ""))))

(defun vigil-effects--insert-files (effect)
  "Insert a line for each file of EFFECT: what became of it, and its lines."
  (let* ((files (vigil-effect-files effect))
         (stat (vigil-effects--stat effect))
         (width (apply #'max (mapcar (lambda (file) (string-width (plist-get file :name)))
                                     files))))
    (dolist (file files)
      (let ((lines (cdr (assoc (plist-get file :name) stat))))
        (insert (format "  %s %s  " (plist-get file :status)
                        (string-pad (plist-get file :name) width))
                (if lines
                    (concat (propertize (format "+%d" (car lines)) 'face 'diff-added)
                            " "
                            (propertize (format "−%d" (cdr lines)) 'face 'diff-removed))
                  (propertize "not text" 'face 'shadow))
                "\n")))))

(defun vigil-effects--insert-diff (effect)
  "Insert the diff of EFFECT: its first `vigil-effects-diff-lines' lines."
  (let* ((diff (vigil-effects--diff effect))
         (lines (split-string diff "\n"))
         (more (- (length lines) vigil-effects-diff-lines)))
    (unless (string-empty-p diff)
      (insert "\n"
              (vigil-command-fontify
               (if (> more 0)
                   (concat (string-join (seq-take lines vigil-effects-diff-lines) "\n") "\n")
                 diff)
               #'diff-mode))
      (when (> more 0)
        (insert (propertize
                 (format "… %d more lines.  All of it: git diff %s %s\n" more
                         (substring (vigil-effect-from effect) 0 10)
                         (substring (vigil-effect-to effect) 0 10))
                 'face 'shadow))))))

(defun vigil-effects-insert (call)
  "Insert the files CALL changed and their diff, if it changed any.
On `vigil-call-body-functions'."
  (when-let* ((effect (vigil-effects-of call))
              (files (vigil-effect-files effect)))
    (unless (bolp) (insert "\n"))
    (insert "\n"
            (propertize (format "Changed %d file%s" (length files) (if (cdr files) "s" ""))
                        'face 'bold)
            (propertize
             (concat (if (equal (vigil-effect-event effect) "PostToolUseFailure")
                         "  ·  though it failed"
                       "")
                     "  ·  the repository after it, against before it")
             'face 'shadow)
            "\n")
    (vigil-effects--insert-files effect)
    (vigil-effects--insert-diff effect)))

(setq vigil-call-changed-function #'vigil-effects-names)
(add-hook 'vigil-call-body-functions #'vigil-effects-insert)
(add-hook 'vigil-changed-hook #'vigil-effects--schedule)

(provide 'vigil-effects)
;;; vigil-effects.el ends here
