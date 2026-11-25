;;; vigil-snapshot.el --- What changed after a prompt -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; `vigil snapshot' (bin/vigil), as a hook, keeps what a repository's files
;; were when each prompt was given and when the agent stopped: commits in
;; the repository's own .git that nothing else points to, held by one ref's
;; reflog.  Two of them are a diff.  This shows the one that is what changed
;; after a prompt:
;;
;; - from the snapshot kept when the prompt was given;
;; - to the last one kept when its agent stopped, before its next prompt;
;;   or, where it never said it stopped, to that next prompt's; or, where
;;   there is none yet, to one taken now.
;;
;; One is also kept before and after each command the agent ran, where the
;; files had changed: those are read here, and what a command changed is
;; vigil-effects.el's to show.
;;
;; A snapshot is of the repository, not of an agent: what changed between
;; two is everything that changed, whoever changed it.  So each file is
;; said beside, from the archive (vigil-history.el), to be one this prompt's
;; edits or commands changed, one another prompt's did, or one nothing is
;; known to have changed; and other agents at work in the repository
;; meanwhile are named.
;;
;; The diff is Magit's where Magit is there, between two commits like any
;; other; and git's own, in a buffer, where it is not.  A prompt given
;; before snapshots were kept has none: what the archive has of its edits is
;; shown in its place, and said to be less.
;;
;; Needs vigil-history.el, vigil-codebase.el, git and bin/vigil; not the
;; rest of vigil, nor cooked.  What Magit is given is vigil-magit.el's to
;; give.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-history)
(require 'vigil-git)
(require 'vigil-base)
(require 'vigil-codebase)

(declare-function vigil-magit-show-range "vigil-magit")

(defgroup vigil-snapshot nil
  "What changed after a prompt."
  :group 'tools)

(defcustom vigil-snapshot-ref "refs/worktree/vigil/snapshots"
  "The ref snapshots are kept under: bin/vigil's VIGIL_SNAPSHOT_REF."
  :type 'string)

(defcustom vigil-snapshot-program nil
  "The vigil program, to take a snapshot now with.
Nil for the one beside this file (../bin/vigil), or else on the path."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom vigil-snapshot-use-magit t
  "Whether a diff is shown by Magit where Magit is there."
  :type 'boolean)

(defconst vigil-snapshot--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Where this file is.")

;;;; The snapshots of a repository

(defun vigil-snapshot--word (word)
  "WORD of a snapshot's message, or nil where it says it is not known."
  (and word (not (equal word "-")) word))

(defun vigil-snapshot-list (root &optional newest)
  "The snapshots kept of the repository at ROOT, oldest first: plists.
:commit and :tree; :time, when it was taken; :event, the hook's event it
was taken for (\"UserPromptSubmit\", \"Stop\", or \"View\" for one taken to
look); :session and :prompt, the ids of the agent's session and of the
prompt; :host, the hosted session's name; :agent, the program that was
given the prompt, \"claude\" or \"pi\".  Nil for what is not known.

One taken before or after a command the agent ran (\"PreToolUse\",
\"PostToolUse\", \"PostToolUseFailure\") has two more: :call, the call's id,
and :before, the commit of the snapshot kept last before it.  Such a one is
kept only where the files differed from that one: after a call, the two are
what the call changed.

With NEWEST, a number, only that many of the newest."
  (let ((text (apply #'vigil-git root "log" "-g" "--format=%H%x1f%T%x1f%ct%x1f%s"
                     (append (and newest (list "-n" (number-to-string newest)))
                             (list vigil-snapshot-ref "--"))))
        found)
    (dolist (line (split-string (or text "") "\n" t))
      (pcase (split-string line "\x1f")
        (`(,commit ,tree ,time ,subject)
         (pcase (split-string subject " " t)
           (`("vigil" ,event ,session ,prompt ,host . ,more)
            (push (list :commit commit :tree tree
                        :time (string-to-number time)
                        :event (vigil-snapshot--word event)
                        :session (vigil-snapshot--word session)
                        :prompt (vigil-snapshot--word prompt)
                        :host (vigil-snapshot--word host)
                        :agent (vigil-snapshot--word (car more))
                        :call (vigil-snapshot--word (nth 1 more))
                        :before (vigil-snapshot--word (nth 2 more)))
                  found))))))
    ;; The reflog is newest first.
    found))

(defun vigil-snapshot--program ()
  "The vigil program, or nil if there is none to be found."
  (or vigil-snapshot-program
      (let ((beside (expand-file-name "../bin/vigil" vigil-snapshot--directory)))
        (and (file-executable-p beside) beside))
      (executable-find "vigil")))

(defun vigil-snapshot-take (root)
  "Keep a snapshot of the repository at ROOT now, and give it as a plist.
Nil where it could not be taken."
  (when-let* ((program (vigil-snapshot--program))
              (commit (with-temp-buffer
                        (let ((default-directory (file-name-as-directory root)))
                          (and (eq 0 (ignore-errors
                                       (call-process program nil '(t nil) nil
                                                     "snapshot" "--now"
                                                     (expand-file-name root))))
                               (string-trim (buffer-string))))))
              ((not (string-empty-p commit))))
    (cl-find commit (vigil-snapshot-list root)
             :key (lambda (snapshot) (plist-get snapshot :commit)) :test #'equal)))

(defun vigil-snapshot-window (root prompt &optional snapshots)
  "From which snapshot to which is what changed after PROMPT, a prompt's id.
In the repository at ROOT, of whose SNAPSHOTS, by default all that are kept.
A plist, or nil where none was kept when PROMPT was given:
:from, the snapshot kept then;
:to, the one that ends it, and :end, which that is: `stopped', the last
  kept when its agent stopped before being given its next prompt;
  `next-prompt', the one kept at that next prompt, the agent not having said
  it stopped; `now', one taken now, there being neither.  :to is nil where
  one had to be taken now and could not be;
:others, the snapshots other sessions had kept in between: agents at work
  in the same repository meanwhile."
  (let* ((snapshots (or snapshots (vigil-snapshot-list root)))
         (rest (seq-drop-while
                (lambda (snapshot)
                  (not (and (equal (plist-get snapshot :event) "UserPromptSubmit")
                            (equal (plist-get snapshot :prompt) prompt))))
                snapshots)))
    (when rest
      (let* ((from (car rest))
             (session (plist-get from :session))
             (stopped nil) (next nil) (others nil) (pending nil))
        (cl-dolist (snapshot (cdr rest))
          (cond
           ((not (plist-get snapshot :session)))
           ((not (equal (plist-get snapshot :session) session))
            (push snapshot pending))
           ((equal (plist-get snapshot :event) "UserPromptSubmit")
            (setq next snapshot)
            (cl-return))
           ((equal (plist-get snapshot :event) "Stop")
            (setq stopped snapshot
                  ;; What others did up to here is inside the window.
                  others (append pending others)
                  pending nil))))
        (cond
         (stopped (list :from from :to stopped :end 'stopped :others (nreverse others)))
         (next (list :from from :to next :end 'next-prompt
                     :others (nreverse (append pending others))))
         (t (list :from from :to (vigil-snapshot-take root) :end 'now
                  :others (nreverse (append pending others)))))))))

(defun vigil-snapshot-changes (root from to)
  "The files that differ between the commits FROM and TO of ROOT.
Each (STATUS . NAME): STATUS is git's letter, A for one that is new, M
changed, D gone."
  (let ((words (split-string
                (or (vigil-git root "diff" "--name-status" "--no-renames"
                                         "-z" from to "--")
                    "")
                "\0" t))
        found)
    (while (cdr words)
      (push (cons (pop words) (pop words)) found))
    (nreverse found)))

;;;; Who changed what

(defun vigil-snapshot-cause (history file prompt from to)
  "What is known to have changed FILE between the times FROM and TO.
Of HISTORY's repository; PROMPT is the id of the prompt asked about.  A
string: this prompt's edits, a command of it, another prompt's edits, or
that nothing is known."
  (let ((mine 0) (others nil) (wrote nil))
    (dolist (edit (vigil-history-edits history file))
      (cond ((equal (plist-get edit :prompt) prompt) (cl-incf mine))
            ((<= from (plist-get edit :time) (+ to 1))
             (cl-pushnew (or (plist-get edit :host) "another agent") others
                         :test #'equal))))
    (dolist (command (vigil-history-writes history file))
      (when (equal (plist-get command :prompt) prompt) (setq wrote t)))
    (let ((said (delq nil
                      (list (and (> mine 0)
                                 (format "%d edit%s of this prompt"
                                         mine (if (= mine 1) "" "s")))
                            (and wrote "a command of this prompt wrote it")
                            (and others
                                 (format "edited meanwhile by %s"
                                         (string-join (nreverse others) ", ")))))))
      (if said
          (string-join said ", ")
        "nothing known to have changed it"))))

(defun vigil-snapshot--summary (prompt window)
  "One line saying what the diff of WINDOW is: what changed after PROMPT.
PROMPT is a plist of the archive's, or one with only :prompt, its id."
  (let* ((to (plist-get window :to))
         (clock (lambda (snapshot)
                  (format-time-string "%H:%M" (plist-get snapshot :time))))
         (agent (plist-get (plist-get window :from) :agent))
         (others (delete-dups
                  (mapcar (lambda (snapshot)
                            (concat (or (plist-get snapshot :host) "an agent with no name")
                                    (if (plist-get snapshot :agent)
                                        (format " (%s)" (plist-get snapshot :agent))
                                      "")))
                          (plist-get window :others)))))
    (concat
     "Changed after "
     (if (plist-get prompt :text)
         (format "“%s”" (vigil-base-one-line (plist-get prompt :text) 60))
       (format "prompt %s" (plist-get prompt :prompt)))
     (format " (%s%s), " (funcall clock (plist-get window :from))
             (if agent (concat ", to " agent) ""))
     (pcase (plist-get window :end)
       ('stopped (format "until its agent stopped at %s" (funcall clock to)))
       ('next-prompt
        (format "until its next prompt at %s: the agent never said it stopped"
                (funcall clock to)))
       (_ "until now"))
     (if others
         (format ".  At work here meanwhile: %s" (string-join others ", "))
       ""))))

;;;; Showing it

(defun vigil-snapshot--show-diff (root prompt window)
  "Show what changed in ROOT in WINDOW, which is what changed after PROMPT.
Gives the buffer."
  (let* ((from (plist-get window :from))
         (to (plist-get window :to))
         (a (plist-get from :commit))
         (b (plist-get to :commit))
         (history (vigil-history root))
         (causes (mapcar (lambda (change)
                           (cons (cdr change)
                                 (vigil-snapshot-cause history (cdr change)
                                                       (plist-get prompt :prompt)
                                                       (plist-get from :time)
                                                       (plist-get to :time))))
                         (vigil-snapshot-changes root a b)))
         (summary (vigil-snapshot--summary prompt window)))
    (if (and vigil-snapshot-use-magit
             (require 'magit-diff nil t)
             (require 'vigil-magit nil t))
        (vigil-magit-show-range root (concat a ".." b) summary causes)
      (with-current-buffer (get-buffer-create "*vigil changes*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert summary "\n\n")
          (pcase-dolist (`(,name . ,cause) causes)
            (insert (format "  %s   %s\n" name cause)))
          (insert "\n" (or (vigil-git root "diff" "--no-renames" a b "--") ""))
          (goto-char (point-min)))
        (diff-mode)
        (setq buffer-read-only t
              default-directory root)
        (display-buffer (current-buffer))
        (current-buffer)))))

(defun vigil-snapshot--show-archive (root prompt)
  "Show what the archive has of what PROMPT changed in ROOT: its edits.
For a prompt no snapshot was kept of.  Gives the buffer, or nil where the
archive has nothing either."
  (let* ((history (vigil-history root))
         (id (plist-get prompt :prompt))
         (edits (vigil-history-prompt-edits history id))
         (writes (vigil-history-prompt-writes history id)))
    (when (or edits writes)
      (with-current-buffer (get-buffer-create "*vigil changes*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize
                   (if (plist-get prompt :text)
                       (format "After “%s”"
                               (vigil-base-one-line (plist-get prompt :text) 70))
                     (format "After prompt %s" id))
                   'face 'bold)
                  "\n\n"
                  (propertize
                   (concat "No snapshot was kept when this prompt was given, so this is not a diff:\n"
                           "it is the lines the agent's edits added, as the archive has them.  Lines\n"
                           "taken out are not kept there, nor is what its commands changed.\n")
                   'face 'shadow))
          (pcase-dolist (`(,file . ,edit) edits)
            (insert "\n"
                    (propertize file 'face 'bold)
                    (propertize (format "   %s, %s, %d out"
                                        (or (plist-get edit :tool) "edit")
                                        (format-time-string "%Y-%m-%d %H:%M"
                                                            (plist-get edit :time))
                                        (or (plist-get edit :removed) 0))
                                'face 'shadow)
                    "\n")
            (dolist (line (plist-get edit :added))
              (insert (propertize (concat "+" line) 'face 'diff-added) "\n")))
          (when writes
            (insert "\n" (propertize "Commands of it that seem to have written files"
                                     'face 'bold)
                    "\n")
            (pcase-dolist (`(,file . ,command) writes)
              (insert (format "  %s  ←  $ %s\n" file
                              (vigil-base-one-line (plist-get command :command) 90)))))
          (goto-char (point-min)))
        (special-mode)
        (setq default-directory root)
        (display-buffer (current-buffer))
        (current-buffer)))))

(defun vigil-snapshot-show (root prompt)
  "Show what changed in the repository at ROOT after PROMPT.
PROMPT is a prompt of the archive, a plist with :prompt, its id; or the id.
Gives the buffer it is shown in, or nil where there is nothing to show."
  (let* ((prompt (if (stringp prompt) (list :prompt prompt) prompt))
         (window (vigil-snapshot-window root (plist-get prompt :prompt))))
    (cond
     ((null window)
      (or (vigil-snapshot--show-archive root prompt)
          (progn (message "No snapshot was kept of this prompt, and the archive has no edit of it")
                 nil)))
     ((null (plist-get window :to))
      (user-error "No snapshot of how things are now could be taken"))
     ((equal (plist-get (plist-get window :from) :tree)
             (plist-get (plist-get window :to) :tree))
      (message "%s: nothing" (vigil-snapshot--summary prompt window))
      nil)
     (t (vigil-snapshot--show-diff root prompt window)))))

;;;; Commands

(defun vigil-snapshot--prompts (root)
  "The prompts a snapshot of ROOT was kept for, newest first.
Each a prompt of the archive where it is there, and else a plist of its
:prompt, :time and :host as the snapshot says them."
  (let ((history (vigil-history root))
        found)
    (dolist (snapshot (vigil-snapshot-list root))
      (when (and (equal (plist-get snapshot :event) "UserPromptSubmit")
                 (plist-get snapshot :prompt))
        (push (or (vigil-history-prompt history (plist-get snapshot :prompt))
                  (list :prompt (plist-get snapshot :prompt)
                        :time (plist-get snapshot :time)
                        :host (plist-get snapshot :host)
                        :agent (plist-get snapshot :agent)))
              found)))
    found))

;;;###autoload
(defun vigil-snapshot-latest (&optional directory)
  "Show what changed after the last prompt given in DIRECTORY's repository.
By default this buffer's."
  (interactive)
  (let* ((root (or (vigil-git-root directory) (user-error "Not in a repository")))
         (prompt (or (car (vigil-snapshot--prompts root))
                     (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                 (abbreviate-file-name root)))))
    (vigil-snapshot-show root prompt)))

;;;###autoload
(defun vigil-snapshot-changes-after (&optional directory)
  "Choose a prompt given in DIRECTORY's repository, and show what changed after.
Of the prompts a snapshot was kept for, newest first."
  (interactive)
  (let* ((root (or (vigil-git-root directory) (user-error "Not in a repository")))
         (prompts (or (vigil-snapshot--prompts root)
                      (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                  (abbreviate-file-name root))))
         (choices (mapcar (lambda (prompt)
                            (cons (format "%s  %s"
                                          (format-time-string "%m-%d %H:%M"
                                                              (plist-get prompt :time))
                                          (if (plist-get prompt :text)
                                              (vigil-base-one-line (plist-get prompt :text) 90)
                                            (plist-get prompt :prompt)))
                                  prompt))
                          prompts))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      ;; As they are: newest first.
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate))))
         (choice (completing-read "What changed after: " table nil t)))
    (vigil-snapshot-show root (cdr (assoc choice choices)))))

(provide 'vigil-snapshot)
;;; vigil-snapshot.el ends here
