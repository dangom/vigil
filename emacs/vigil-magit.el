;;; vigil-magit.el --- What is behind a change, in Magit -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; Magit shows what changed.  This adds, from vigil's archive and from the
;; repository's own log (vigil-history.el, vigil-codebase.el), why and how
;; much:
;;
;; - A commit shown by Magit says which prompts are behind it: those whose
;;   edits wrote lines the commit adds, found by the lines' own text; those
;;   whose commands seem to have written its files; and, apart, those only
;;   asked while it was being made.
;; - A file named in a diff, a commit or the status says what kind of
;;   change it has seen lately, how often, for how many prompts, and when a
;;   command last exercised it and whether it has changed since.
;; - `vigil-magit-why', on a hunk, a file or anywhere in a commit, shows
;;   the prompts behind what is at point.
;; - With Embark and vigil-embark.el, a hunk is the call that wrote it,
;;   where that call's session is live: every action on a call applies.
;;
;; Nothing here loads Magit, or needs it to load: what is given to Magit is
;; given once Magit is there.  Nothing here needs the rest of vigil, or
;; cooked.  Magit's buffers are only added to: each refresh draws them
;; anew, and `vigil-magit-mode' off, they are as they were.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)
(require 'vigil-history)
(require 'vigil-codebase)
(require 'vigil-git)

(declare-function magit-current-section "ext:magit-section")
(declare-function magit-toplevel "ext:magit-git")
(declare-function magit-diff-range "ext:magit-diff")
(declare-function magit-diff-arguments "ext:magit-diff")
(declare-function magit-get-mode-buffer "ext:magit-mode")
(declare-function vigil-magit--insert-section "vigil-magit")
(defvar magit-buffer-revision)
(defvar magit-root-section)
(defvar magit-buffer-range)
(defvar magit-buffer-diff-range)
(defvar magit-revision-sections-hook)
(defvar embark-target-finders)

(defgroup vigil-magit nil
  "What is behind a change, in Magit."
  :group 'vigil)

(defcustom vigil-magit-meanwhile 8
  "How many of the prompts asked while a commit was made are listed at most.
Those no line of the commit is known to be from."
  :type 'natnum)

(defcustom vigil-magit-meanwhile-days 3
  "A commit this many days after the one before it lists no such prompts.
What was asked in between is then too much to be about it."
  :type 'number)

;;;; What a section is

(defun vigil-magit--slot (section slot)
  "SECTION's SLOT, or nil if it has none."
  (ignore-errors (eieio-oref section slot)))

(defun vigil-magit--root ()
  "The top of the repository this buffer is of."
  (or (and (fboundp 'magit-toplevel) (ignore-errors (magit-toplevel)))
      (vigil-git-root)))

(defun vigil-magit--sections (section type)
  "The sections of TYPE in SECTION and under it, in order."
  (when section
    (append (and (eq (vigil-magit--slot section 'type) type) (list section))
            (cl-mapcan (lambda (child) (vigil-magit--sections child type))
                       (copy-sequence (vigil-magit--slot section 'children))))))

(defun vigil-magit--enclosing (section type)
  "SECTION, or the nearest section over it, that is of TYPE."
  (while (and section (not (eq (vigil-magit--slot section 'type) type)))
    (setq section (vigil-magit--slot section 'parent)))
  section)

(defun vigil-magit--added (hunk)
  "The lines HUNK, a hunk's section, adds, as text."
  (let ((start (vigil-magit--slot hunk 'content))
        (end (vigil-magit--slot hunk 'end))
        lines)
    (when (and start end)
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (when (eq (char-after) ?+)
            (push (buffer-substring-no-properties (1+ (point)) (line-end-position))
                  lines))
          (forward-line 1))))
    (nreverse lines)))

;;;; The prompts behind a commit

(defun vigil-magit--commit (root revision)
  "What the commit REVISION of the repository at ROOT adds: a plist.
:time, when it was made; :before, when the one before it was; :files, each
\(NAME . LINES), the lines it adds to the file as text."
  (let ((text (vigil-git root "show" "--no-renames" "-U0"
                                   "--format=%x01%at %P" revision))
        time parent files file)
    (dolist (line (split-string (or text "") "\n"))
      (cond ((string-prefix-p "\x01" line)
             (let ((words (split-string (substring line 1) " " t)))
               (setq time (string-to-number (car words))
                     parent (cadr words))))
            ((string-prefix-p "diff --git " line) (setq file nil))
            ((string-prefix-p "+++ b/" line)
             (setq file (list (substring line 6)))
             (push file files))
            ((string-prefix-p "+++ " line))
            ((and file (string-prefix-p "+" line))
             (push (substring line 1) (cdr file)))))
    (list :time time
          :before (and parent
                       (let ((said (vigil-git root "log" "-1" "--format=%at"
                                                        parent)))
                         (and said (string-to-number said))))
          :files (nreverse files))))

(defun vigil-magit-commit-prompts (root revision)
  "The prompts behind the commit REVISION of the repository at ROOT.
A list of (PROMPT HOW LINES FILES), most lines first.  HOW is `wrote': edits
that followed PROMPT wrote LINES of the lines the commit adds, in FILES, a
list of names; or `command': commands that followed it seem to have written
FILES; or `meanwhile': it was asked while the commit was being made, and
nothing more is known.  PROMPT is a prompt of the archive."
  (let* ((commit (vigil-magit--commit root revision))
         (time (or (plist-get commit :time) 0))
         (before (plist-get commit :before))
         (history (vigil-history root))
         (found nil)
         (note (lambda (id how lines file)
                 (when-let* ((prompt (vigil-history-prompt history id)))
                   (let ((entry (or (cl-find prompt found :key #'car)
                                    (car (push (list prompt how 0 nil) found)))))
                     ;; Having written lines says more than having run a command.
                     (when (eq how 'wrote) (setf (nth 1 entry) 'wrote))
                     (cl-incf (nth 2 entry) lines)
                     (cl-pushnew file (nth 3 entry) :test #'equal))))))
    (pcase-dolist (`(,name . ,lines) (plist-get commit :files))
      (pcase-dolist (`(,edit . ,count) (vigil-history-origin history name lines))
        ;; An edit made after the commit did not write what is in it.
        (when (<= (plist-get edit :time) (+ time 60))
          (funcall note (plist-get edit :prompt) 'wrote count name)))
      (dolist (command (vigil-history-writes history name))
        (when (and (<= (plist-get command :time) (+ time 60))
                   (or (null before) (> (plist-get command :time) before)))
          (funcall note (plist-get command :prompt) 'command 0 name))))
    (setq found (sort found (lambda (a b) (> (nth 2 a) (nth 2 b)))))
    (append
     found
     (and before
          (< (- time before) (* 86400 vigil-magit-meanwhile-days))
          (mapcar (lambda (prompt) (list prompt 'meanwhile 0 nil))
                  (take vigil-magit-meanwhile
                        (cl-remove-if
                         (lambda (prompt) (cl-find prompt found :key #'car))
                         (vigil-history-prompts-between history before time))))))))

(defun vigil-magit--insert-prompts (prompts)
  "Insert PROMPTS, as `vigil-magit-commit-prompts' gives them, a line each."
  (let ((meanwhile nil))
    (pcase-dolist (`(,prompt ,how ,lines ,files) prompts)
      (when (and (eq how 'meanwhile) (not meanwhile))
        (setq meanwhile t)
        (insert (propertize "  asked while it was made, with nothing of theirs known to be in it:\n"
                            'face 'shadow)))
      (vigil-codebase-insert-prompt
       prompt
       (pcase how
         ('wrote (format "%d line%s in %s" lines (if (= lines 1) "" "s")
                         (string-join (reverse files) ", ")))
         ('command (format "a command wrote %s" (string-join (reverse files) ", ")))
         (_ nil))))))

(defun vigil-magit-insert-prompts ()
  "Insert the prompts behind the commit this buffer shows, as a section.
For `magit-revision-sections-hook'.  Nothing, where none are known."
  (when-let* (((bound-and-true-p magit-buffer-revision))
              (root (vigil-magit--root))
              (prompts (ignore-errors
                         (vigil-magit-commit-prompts root magit-buffer-revision))))
    (vigil-magit--insert-section
     "Prompts behind this commit"
     (lambda () (vigil-magit--insert-prompts prompts)))))

;;;; What kind of change a file has seen

(defun vigil-magit-annotate-files (property say &optional face)
  "Say beside each file this Magit buffer names what SAY gives for its name.
SAY is called with a file's name, as git gives it, and returns a string or
nil.  What is said is marked with PROPERTY, a symbol: what was said under
it before is taken away first, and all of it is by a SAY of nil.  In FACE,
by default `shadow'."
  (remove-overlays (point-min) (point-max) property t)
  (when say
    (dolist (section (vigil-magit--sections (bound-and-true-p magit-root-section) 'file))
      (when-let* ((name (vigil-magit--slot section 'value))
                  ((stringp name))
                  (said (funcall say name))
                  (start (vigil-magit--slot section 'start)))
        (save-excursion
          (goto-char start)
          (let ((overlay (make-overlay (line-end-position) (line-end-position))))
            (overlay-put overlay property t)
            (overlay-put overlay 'after-string
                         (concat (propertize "   " 'face 'default)
                                 (propertize said 'face (or face 'shadow))))))))))

(defun vigil-magit-badges ()
  "Say, beside each file this Magit buffer names, what change it has seen.
What kind, how often, for how many prompts, and when it was last exercised;
see `vigil-codebase-stats'.  For `magit-refresh-buffer-hook'."
  (let ((stats (and (bound-and-true-p magit-root-section)
                    (when-let* ((root (vigil-magit--root)))
                      (ignore-errors (vigil-codebase-stats root))))))
    (vigil-magit-annotate-files
     'vigil-magit
     (and stats (lambda (name) (vigil-codebase-badge (gethash name stats)))))))

;;;; A range, and what is known of it

(defvar-local vigil-magit--range nil
  "What this Magit buffer was asked to show by `vigil-magit-show-range'.
A plist: :range, the range; :summary, a line; :notes, ((FILE . NOTE)...).")

(defun vigil-magit--shown-range ()
  "The range this Magit diff buffer shows."
  ;; Magit has named it both ways.
  (or (bound-and-true-p magit-buffer-diff-range)
      (bound-and-true-p magit-buffer-range)))

(defun vigil-magit--annotate-range ()
  "Say what this buffer's range is of, and of each file, while it shows it.
Once it shows another range nothing more is said of this one.  For
`magit-refresh-buffer-hook'."
  (when vigil-magit--range
    (if (equal (vigil-magit--shown-range) (plist-get vigil-magit--range :range))
        (let ((notes (plist-get vigil-magit--range :notes)))
          (setq header-line-format (plist-get vigil-magit--range :summary))
          (vigil-magit-annotate-files
           'vigil-magit-range (lambda (name) (cdr (assoc name notes))) 'italic))
      ;; Magit has already put its own line over the other range.
      (vigil-magit-annotate-files 'vigil-magit-range nil)
      (setq vigil-magit--range nil))))

(defun vigil-magit-show-range (root range summary notes)
  "Show, in Magit, the changes of RANGE in the repository at ROOT.
Under SUMMARY, a line saying what they are; and with, beside each file,
what NOTES says of it: ((FILE . NOTE)...).  Gives the buffer."
  (require 'magit-diff)
  (let ((default-directory root))
    (magit-diff-range range (car (magit-diff-arguments)))
    (add-hook 'magit-refresh-buffer-hook #'vigil-magit--annotate-range)
    (when-let* ((buffer (magit-get-mode-buffer 'magit-diff-mode)))
      (with-current-buffer buffer
        (setq vigil-magit--range
              (list :range range :summary (concat " " summary) :notes notes))
        (vigil-magit--annotate-range))
      buffer)))

;;;; What is behind what is at point

(defun vigil-magit--origin ()
  "The edits that wrote the hunk at point: ((EDIT . LINES)...), and its file.
A cons (ORIGIN . FILE); nil off a hunk, or in no repository."
  (when-let* (((fboundp 'magit-current-section))
              (hunk (vigil-magit--enclosing (magit-current-section) 'hunk))
              (file (vigil-magit--enclosing hunk 'file))
              (name (vigil-magit--slot file 'value))
              ((stringp name))
              (root (vigil-magit--root)))
    (cons (vigil-history-origin (vigil-history root) name (vigil-magit--added hunk))
          name)))

(defun vigil-magit-why ()
  "Show the prompts behind what is at point in a Magit buffer.
On a hunk, those whose edits wrote the lines it adds; on a file, those
behind its changes; elsewhere in a commit, those behind the commit."
  (interactive)
  (let* ((root (or (vigil-magit--root) (user-error "Not in a repository")))
         (history (vigil-history root))
         (section (and (fboundp 'magit-current-section) (magit-current-section)))
         (hunk (vigil-magit--enclosing section 'hunk))
         (file (vigil-magit--enclosing section 'file))
         (name (and file (vigil-magit--slot file 'value)))
         (title nil)
         (insert nil))
    (cond
     (hunk
      (let ((origin (car (vigil-magit--origin))))
        (setq title (format "The prompts behind this change of %s" name)
              insert (lambda ()
                       (if (null origin)
                           (insert "  (no edit in the archive wrote these lines)\n")
                         (pcase-dolist (`(,edit . ,count) origin)
                           (let ((prompt (vigil-history-prompt
                                          history (plist-get edit :prompt))))
                             (if prompt
                                 (vigil-codebase-insert-prompt
                                  prompt (format "%d line%s" count (if (= count 1) "" "s")))
                               (insert (format "  (a prompt not kept)  %d lines\n"
                                               count))))))))))
     ((stringp name)
      (let ((prompts (vigil-history-prompts-of history name)))
        (setq title (format "The prompts behind the changes of %s" name)
              insert (lambda ()
                       (if (null prompts)
                           (insert "  (none in the archive)\n")
                         (pcase-dolist (`(,prompt ,edits ,writes) prompts)
                           (when prompt
                             (vigil-codebase-insert-prompt
                              prompt (format "%d edit%s, %d command%s that wrote it"
                                             edits (if (= edits 1) "" "s")
                                             writes (if (= writes 1) "" "s"))))))))))
     ((bound-and-true-p magit-buffer-revision)
      (let ((prompts (vigil-magit-commit-prompts root magit-buffer-revision)))
        (setq title (format "The prompts behind %s" magit-buffer-revision)
              insert (lambda ()
                       (if prompts
                           (vigil-magit--insert-prompts prompts)
                         (insert "  (none in the archive)\n"))))))
     (t (user-error "Nothing here to ask about: not a hunk, a file or a commit")))
    (with-current-buffer (get-buffer-create "*vigil why*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize title 'face 'bold) "\n\n")
        (funcall insert)
        (goto-char (point-min)))
      (vigil-codebase-file-mode)
      (setq default-directory root)
      (display-buffer (current-buffer))
      (current-buffer))))

;;;; A hunk as the call that wrote it

(defun vigil-magit-target-call ()
  "The call that wrote the hunk at point, as an Embark target.
\(vigil-call \"SESSION/CALL-ID\" START . END), as vigil-embark.el's are: the
edit that wrote most of the lines the hunk adds.  Nil off a hunk, or where
no edit of a session with a name wrote it.  For `embark-target-finders'."
  (when (derived-mode-p 'magit-mode)
    (when-let* ((origin (ignore-errors (vigil-magit--origin)))
                (edit (car (car (car origin))))
                (session (plist-get edit :host))
                ((stringp session))
                (call (plist-get edit :call))
                ((stringp call))
                (hunk (vigil-magit--enclosing (magit-current-section) 'hunk))
                (start (vigil-magit--slot hunk 'start)))
      `(vigil-call ,(concat session "/" call) ,start
                   . ,(save-excursion (goto-char start) (line-end-position))))))

;;;; Given to Magit

;;;###autoload
(define-minor-mode vigil-magit-mode
  "Say, in Magit's buffers, what is behind a change and how much of it there is.
The prompts behind a commit, in the buffer showing it; and beside each
file, what kind of change it has seen lately."
  :global t :group 'vigil-magit
  (if vigil-magit-mode
      (progn
        (add-hook 'magit-refresh-buffer-hook #'vigil-magit-badges)
        (with-eval-after-load 'magit-diff
          (when (and vigil-magit-mode
                     (not (memq #'vigil-magit-insert-prompts
                                magit-revision-sections-hook)))
            ;; After the message and before the diff; last, if the diff is
            ;; not there to come before.
            (setq magit-revision-sections-hook
                  (let ((placed nil) (new nil))
                    (dolist (function magit-revision-sections-hook)
                      (when (eq function 'magit-insert-revision-diff)
                        (setq placed t)
                        (push #'vigil-magit-insert-prompts new))
                      (push function new))
                    (unless placed (push #'vigil-magit-insert-prompts new))
                    (nreverse new))))))
    (remove-hook 'magit-refresh-buffer-hook #'vigil-magit-badges)
    (when (boundp 'magit-revision-sections-hook)
      (remove-hook 'magit-revision-sections-hook #'vigil-magit-insert-prompts))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'magit-mode)
          (vigil-magit-annotate-files 'vigil-magit nil))))))

(with-eval-after-load 'magit-section
  ;; `magit-insert-section' is a macro, and Magit is not loaded when this
  ;; file is compiled: so this one function is made when Magit is there.
  (eval '(defun vigil-magit--insert-section (heading insert)
           "Insert a section under HEADING, its body by calling INSERT."
           (magit-insert-section (vigil-prompts)
             (magit-insert-heading heading)
             (funcall insert)
             (insert "\n")))
        t))

(with-eval-after-load 'embark
  ;; After vigil-embark's own, where both are loaded: in a Magit buffer
  ;; that one finds nothing.
  (add-hook 'embark-target-finders #'vigil-magit-target-call))

(provide 'vigil-magit)
;;; vigil-magit.el ends here
