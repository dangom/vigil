;;; vigil-review.el --- What a session built, against what was there before -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; `M-x vigil-review', in an agent's buffer or anywhere in a repository:
;; what a session built, against what the files were when its first prompt
;; was given.  It reads the snapshots `vigil snapshot' keeps
;; (vigil-snapshot.el), and has two buffers.
;;
;; The overview is the session in short.  Its prompts, in order, each with
;; how many files changed after it; and the files that are new, changed or
;; gone since the beginning, as a tree.  The tree can be stepped through
;; time, a snapshot at a time, or played: it then shows the files as they
;; were at that moment, with what had just changed marked.
;;
;; The reading buffer is those files, one after another, as the session
;; left them: each in its own colours, the lines the session put in
;; highlighted, and the definitions it did not touch folded to their first
;; line.  A new file is shown as its definitions, all folded.  `F' lays the
;; buffer over as many windows side by side as fit (`follow-mode').
;;
;; A session here is a hosted session, by its name, from one of its
;; beginnings: an agent started again under the same name begins anew, and
;; `s' chooses an earlier beginning.  An agent in no hosted session is its
;; own.
;;
;; A snapshot is of the repository, not of an agent: what is shown is
;; everything that changed in that time, whoever changed it.
;;
;; Needs vigil-snapshot.el and what it needs; not the rest of vigil, nor
;; cooked.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'vigil-snapshot)
(require 'vigil-ui)

(declare-function vigil-magit-show-range "vigil-magit")
(defvar cooked-host-name)
(defvar follow-mode)

(defgroup vigil-review nil
  "What a session built, against what was there before."
  :group 'tools)

(defcustom vigil-review-fold-lines 3
  "The fewest lines a definition, or a run of lines, has to be folded."
  :type 'integer)

(defcustom vigil-review-context 3
  "Lines left showing around a change, in a file with no definitions."
  :type 'integer)

(defcustom vigil-review-max-file-size 400000
  "Bytes of the biggest file laid out to be read; a bigger one is only named."
  :type 'integer)

(defcustom vigil-review-follow-width 90
  "Columns a window has, at least, when `vigil-review-follow' makes several."
  :type 'integer)

(defcustom vigil-review-play-seconds 1.0
  "Seconds each moment is shown for when the overview is played."
  :type 'number)

(defface vigil-review-added '((t :inherit diff-added :extend t))
  "Lines the session put in.")

(defface vigil-review-removed '((t :inherit diff-removed))
  "Where the session took lines out.")

(defface vigil-review-heading '((t :inherit diff-file-header :extend t))
  "The line a file is under.")

(defface vigil-review-new '((t :inherit success))
  "A file that is new.")

(defface vigil-review-changed '((t :inherit warning))
  "A file that changed.")

(defface vigil-review-gone '((t :inherit error))
  "A file that is gone.")

(defface vigil-review-touched '((t :inherit bold))
  "A file that had just changed, at the moment shown.")

;;;; A session's snapshots

(defun vigil-review--of-p (snapshot host session)
  "Whether SNAPSHOT was kept for the hosted session HOST.
Or, HOST being nil, for the agent's session SESSION in no hosted one."
  (if host
      (equal (plist-get snapshot :host) host)
    (and (null (plist-get snapshot :host))
         (equal (plist-get snapshot :session) session))))

(defun vigil-review-sessions (root &optional snapshots)
  "The beginnings a session's review can run from, in ROOT, newest first.
Of SNAPSHOTS, by default all that are kept.  Each a plist: :host, the
hosted session's name; :session, the agent's own id; :agent; :from, the
first snapshot kept for it; :time, when; :prompts, how many it was given."
  (let ((table (make-hash-table :test #'equal))
        found)
    (dolist (snapshot (or snapshots (vigil-snapshot-list root)))
      (when-let* ((session (plist-get snapshot :session)))
        (let* ((key (cons (plist-get snapshot :host) session))
               (known (gethash key table)))
          (unless known
            (setq known (list :host (plist-get snapshot :host) :session session
                              :agent (plist-get snapshot :agent)
                              :from snapshot :time (plist-get snapshot :time)
                              :prompts nil))
            (puthash key known table)
            (push known found))
          (when (and (equal (plist-get snapshot :event) "UserPromptSubmit")
                     (plist-get snapshot :prompt))
            (cl-pushnew (plist-get snapshot :prompt) (plist-get known :prompts)
                        :test #'equal)))))
    (dolist (known found)
      (plist-put known :prompts (length (plist-get known :prompts))))
    ;; As they were first heard of, the last first.
    found))

(defun vigil-review-span (root from &optional snapshots)
  "What there is to review of the session that begins at the snapshot FROM.
In ROOT, of whose SNAPSHOTS, by default all that are kept.  A plist:
:host, :session and :agent, whose it is; :from, FROM;
:to, the snapshot that ends it, and :end, which that is: `stopped', the
  last kept for it, its agent having stopped; or `now', one taken now;
:prompts, the snapshots kept when each of its prompts was given, in order;
:frames, every snapshot of it at which the files differed from the one
  before, in order, :to last: the moments it can be shown at;
:order, all of its snapshots, in order: which of two came first."
  (let* ((host (plist-get from :host))
         (session (plist-get from :session))
         (rest (seq-drop-while
                (lambda (snapshot)
                  (not (equal (plist-get snapshot :commit) (plist-get from :commit))))
                (or snapshots (vigil-snapshot-list root))))
         (own (seq-filter (lambda (snapshot)
                            (vigil-review--of-p snapshot host session))
                          rest))
         (last (car (last own)))
         (stopped (equal (plist-get last :event) "Stop"))
         (to (or (and stopped last) (vigil-snapshot-take root) last))
         (tree (plist-get from :tree))
         (order (append own (and (not (memq to own)) (list to))))
         prompts frames)
    (dolist (snapshot order)
      (when (and (equal (plist-get snapshot :event) "UserPromptSubmit")
                 (plist-get snapshot :prompt)
                 (not (cl-find (plist-get snapshot :prompt) prompts
                               :key (lambda (s) (plist-get s :prompt)) :test #'equal)))
        (push snapshot prompts))
      (unless (equal (plist-get snapshot :tree) tree)
        (setq tree (plist-get snapshot :tree))
        (push snapshot frames)))
    (list :host host :session session :agent (plist-get from :agent)
          :from from :to to :end (if (and stopped (eq to last)) 'stopped 'now)
          :prompts (nreverse prompts) :frames (nreverse frames) :order order)))

;;;; What changed between two snapshots

(defun vigil-review-changes (root a b)
  "The files that differ between the commits A and B of ROOT, by name.
Each a plist: :file; :status, git's letter, A for new, M changed, D gone;
:added and :removed, lines put in and taken out, nil for what is not text."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (entry (split-string
                    (or (vigil-git root "diff" "--numstat" "--no-renames" "-z" a b "--")
                        "")
                    "\0" t))
      (pcase (split-string entry "\t")
        (`(,added ,removed . ,name)
         (puthash (string-join name "\t")
                  (and (not (equal added "-"))
                       (cons (string-to-number added) (string-to-number removed)))
                  counts))))
    (sort (mapcar (lambda (change)
                    (let ((count (gethash (cdr change) counts)))
                      (list :file (cdr change) :status (car change)
                            :added (car count) :removed (cdr count))))
                  (vigil-snapshot-changes root a b))
          (lambda (x y) (string< (plist-get x :file) (plist-get y :file))))))

(defun vigil-review--totals (changes)
  "Of CHANGES: how many files are new, changed and gone, and lines in and out.
A list of the five numbers."
  (let ((new 0) (changed 0) (gone 0) (added 0) (removed 0))
    (dolist (change changes)
      (pcase (plist-get change :status)
        ("A" (cl-incf new)) ("D" (cl-incf gone)) (_ (cl-incf changed)))
      (cl-incf added (or (plist-get change :added) 0))
      (cl-incf removed (or (plist-get change :removed) 0)))
    (list new changed gone added removed)))

(defun vigil-review--count (changes)
  "CHANGES in a few words: how many files, and lines in and out."
  (pcase-let ((`(,new ,changed ,gone ,added ,removed) (vigil-review--totals changes)))
    (if (null changes)
        "nothing changed"
      (concat
       (string-join
        (delq nil (list (and (> new 0) (format "%d new" new))
                        (and (> changed 0) (format "%d changed" changed))
                        (and (> gone 0) (format "%d gone" gone))))
        ", ")
       (format "   +%d −%d" added removed)))))

(defun vigil-review--hunks (root a b file)
  "Where FILE differs between the commits A and B of ROOT, in B's lines.
Each (LINE COUNT REMOVED): COUNT lines from LINE on were put in, in place
of REMOVED that were taken out.  COUNT is 0 where lines were only taken
out: after LINE."
  (let ((text (vigil-git root "diff" "-U0" "--no-renames" a b "--" file))
        (start 0) found)
    (while (and text
                (string-match
                 "^@@ -[0-9]+\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                 text start))
      (setq start (match-end 0))
      (push (list (string-to-number (match-string 2 text))
                  (if (match-string 3 text) (string-to-number (match-string 3 text)) 1)
                  (if (match-string 1 text) (string-to-number (match-string 1 text)) 1))
            found))
    (nreverse found)))

;;;; Laying a file out

(defun vigil-review--defuns ()
  "The definitions of this buffer, first to last: ((BEGINNING . END)...).
As its mode finds them, one inside another counted apart: a class's
methods are each one, and the class is what is above its first."
  (let ((limit (point-max)) (guard 0) found)
    (save-excursion
      (goto-char (point-max))
      (while (and (< (cl-incf guard) 5000)
                  (ignore-errors (beginning-of-defun))
                  (< (point) limit))
        (let* ((beginning (point))
               (end (min limit
                         (or (ignore-errors
                               (save-excursion (end-of-defun) (point)))
                             limit))))
          (setq end (save-excursion
                      (goto-char end)
                      (skip-chars-backward " \t\n" beginning)
                      (point)))
          (when (> end beginning) (push (cons beginning end) found))
          (setq limit beginning))))
    found))

(defun vigil-review--position (line)
  "Where LINE of this buffer begins."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun vigil-review--touched-p (ranges first last)
  "Whether any of RANGES, ((FIRST . LAST)...) lines, has a line in FIRST to LAST."
  (cl-some (lambda (range) (and (<= (car range) last) (>= (cdr range) first)))
           ranges))

(defun vigil-review--fold-at (line last)
  "A fold that leaves LINE showing and hides the lines after it up to LAST.
\(BEGINNING END LINES), or nil where that is fewer than are worth folding."
  (let ((beginning (save-excursion (goto-char (vigil-review--position line))
                                   (line-end-position)))
        (end (save-excursion (goto-char (vigil-review--position last))
                             (line-end-position))))
    (and (>= (- last line) vigil-review-fold-lines)
         (> end beginning)
         (list beginning end (- last line)))))

(defun vigil-review--runs (ranges lines)
  "The folds of a buffer of LINES lines with no definitions: what is far from
any of RANGES, the lines that changed."
  (let ((line 1) found)
    (dolist (range (append ranges (list (cons (+ lines 1 vigil-review-context)
                                              (+ lines 1 vigil-review-context)))))
      (let ((last (min lines (- (car range) vigil-review-context 1))))
        (when-let* (((> last line))
                    (fold (vigil-review--fold-at line last)))
          (push fold found))
        (setq line (max line (+ (cdr range) vigil-review-context)))))
    (nreverse found)))

(defun vigil-review--layout (root a b change)
  "CHANGE, a file that differs between the commits A and B of ROOT, to read.
A plist: :text, the file as it is in B, in its mode's colours, or nil where
there is none to show, :note then saying why; :added, the places lines were
put in, ((BEGINNING . END)...); :removed, the places lines were only taken
out, ((POSITION . LINES)...); :folds, what is hidden to begin with,
\((BEGINNING END LINES)...).  Places count from 1 at the text's beginning."
  (let* ((file (plist-get change :file))
         (status (plist-get change :status))
         (size (and (not (equal status "D"))
                    (string-to-number
                     (or (vigil-git root "cat-file" "-s" (concat b ":" file)) "0")))))
    (cond
     ((equal status "D") (list :note "gone"))
     ((null (plist-get change :added)) (list :note "not text"))
     ((> size vigil-review-max-file-size)
      (list :note (format "%s, too big to lay out" (file-size-human-readable size))))
     (t
      (with-temp-buffer
        (insert (or (vigil-git root "show" (concat b ":" file)) ""))
        (unless (bolp) (insert "\n"))
        (let ((buffer-file-name (expand-file-name file root)))
          (ignore-errors (delay-mode-hooks (set-auto-mode))))
        (ignore-errors (font-lock-ensure))
        (let* ((new (equal status "A"))
               (hunks (and (not new) (vigil-review--hunks root a b file)))
               (lines (count-lines (point-min) (point-max)))
               ;; A place lines were only taken out touches the lines either
               ;; side of it.
               (ranges (mapcar (pcase-lambda (`(,line ,count ,_))
                                 (if (> count 0)
                                     (cons line (+ line count -1))
                                   (cons (max 1 line) (1+ line))))
                               hunks))
               (defuns (and (derived-mode-p 'prog-mode) (vigil-review--defuns)))
               added removed folds)
          (pcase-dolist (`(,line ,count ,taken) hunks)
            (if (> count 0)
                (push (cons (vigil-review--position line)
                            (vigil-review--position (+ line count)))
                      added)
              (push (cons (vigil-review--position (1+ line)) taken) removed)))
          (if defuns
              (pcase-dolist (`(,beginning . ,end) defuns)
                (let ((first (line-number-at-pos beginning))
                      (last (line-number-at-pos end)))
                  (unless (vigil-review--touched-p ranges first last)
                    (when-let* ((fold (vigil-review--fold-at first last)))
                      (push fold folds)))))
            (unless new
              (setq folds (reverse (vigil-review--runs ranges lines)))))
          (list :text (buffer-string) :lines lines
                :added (nreverse added) :removed (nreverse removed)
                :folds (nreverse folds))))))))

;;;; Folds

(defun vigil-review--make-fold (beginning end lines kind folded)
  "Make BEGINNING to END a fold of LINES lines, of KIND, FOLDED or not.
BEGINNING is the end of the line that stays showing."
  (let ((fold (make-overlay beginning end))
        (tag (make-overlay (max (point-min) (1- beginning)) beginning)))
    (overlay-put fold 'vigil-review-fold kind)
    (overlay-put fold 'vigil-review-lines lines)
    (overlay-put fold 'vigil-review-tag tag)
    (overlay-put fold 'evaporate t)
    (overlay-put tag 'evaporate t)
    (overlay-put fold 'isearch-open-invisible
                 (lambda (overlay) (vigil-review--fold overlay nil)))
    (vigil-review--fold fold folded)
    fold))

(defun vigil-review--fold (fold folded)
  "Hide what is in FOLD if FOLDED, and else show it."
  (overlay-put fold 'invisible (and folded t))
  (if-let* ((marker (overlay-get fold 'vigil-review-marker)))
      ;; A fold with a marker says which way it is at the line's beginning.
      (overlay-put marker 'display (if folded "▸" "▾"))
    ;; Otherwise how much is hidden is said after the line that stays: as
    ;; part of its last character, since a string of its own beside hidden
    ;; text is hidden with it.
    (let* ((tag (overlay-get fold 'vigil-review-tag))
           (lines (overlay-get fold 'vigil-review-lines)))
      (overlay-put tag 'display
                   (and folded
                        (overlay-buffer tag)
                        (concat (with-current-buffer (overlay-buffer tag)
                                  (buffer-substring (overlay-start tag) (overlay-end tag)))
                                (propertize (format "  ⋯ %d line%s"
                                                    lines (if (= 1 lines) "" "s"))
                                            'face 'shadow)))))))

(defun vigil-review-mark-fold (fold)
  "Have FOLD say whether it is folded at the beginning of its line.
With a mark in place of the line's first character, which is to be a space;
and no longer after the line."
  (let* ((start (save-excursion (goto-char (overlay-start fold))
                                (line-beginning-position)))
         (marker (make-overlay start (1+ start))))
    (overlay-put marker 'evaporate t)
    (overlay-put fold 'vigil-review-marker marker)
    (overlay-put (overlay-get fold 'vigil-review-tag) 'display nil)
    (vigil-review--fold fold (vigil-review--folded-p fold))
    fold))

(defun vigil-review--folded-p (fold)
  "Whether FOLD is hiding what is in it."
  (and (overlay-get fold 'invisible) t))

(defun vigil-review--folds (&optional beginning end)
  "The folds between BEGINNING and END, by default all of this buffer's."
  (seq-filter (lambda (overlay) (overlay-get overlay 'vigil-review-fold))
              (overlays-in (or beginning (point-min)) (or end (point-max)))))

(defun vigil-review--fold-here ()
  "The fold of this line: the one it is the first line of, or else the
smallest that point is in."
  (let ((end (line-end-position)))
    (or (cl-find end (vigil-review--folds end (1+ end)) :key #'overlay-start)
        (car (sort (seq-filter (lambda (fold)
                                 (and (< (overlay-start fold) (point))
                                      (<= (point) (overlay-end fold))))
                               (vigil-review--folds (point) (1+ (point))))
                   (lambda (a b)
                     (< (- (overlay-end a) (overlay-start a))
                        (- (overlay-end b) (overlay-start b)))))))))

(defun vigil-review-toggle ()
  "Fold or unfold what this line begins, or what point is in."
  (interactive)
  (let ((fold (or (vigil-review--fold-here) (user-error "Nothing to fold here"))))
    (when (> (point) (overlay-start fold))
      (goto-char (overlay-start fold))
      (beginning-of-line))
    (vigil-review--fold fold (not (vigil-review--folded-p fold)))))

(defun vigil-review-toggle-all ()
  "Unfold every definition, or fold them all if none is folded."
  (interactive)
  (let* ((folds (seq-remove (lambda (fold)
                              (eq (overlay-get fold 'vigil-review-fold) 'file))
                            (vigil-review--folds)))
         (any (cl-some #'vigil-review--folded-p folds)))
    (dolist (fold folds) (vigil-review--fold fold (not any)))
    (message (if any "Everything showing" "Every definition folded"))))

;;;; The reading buffer

(defvar-local vigil-review--root nil "The repository this buffer is of.")
(defvar-local vigil-review--range nil "The commits this buffer is between: (A . B).")
(defvar-local vigil-review--files nil
  "The files of this reading buffer: plists of :file, :heading and :body, markers.")
(defvar-local vigil-review--windows nil
  "How the windows were before `vigil-review-follow' made its own.")

(defun vigil-review--mark (status)
  "The mark and face of a file of STATUS: (MARK . FACE)."
  (pcase status
    ("A" '("+" . vigil-review-new))
    ("D" '("-" . vigil-review-gone))
    (_ '("~" . vigil-review-changed))))

(defun vigil-review--lines-said (change)
  "What CHANGE put in and took out, in a few characters."
  (if (plist-get change :added)
      (concat (if (> (plist-get change :added) 0)
                  (format "+%d" (plist-get change :added)) "")
              (if (> (plist-get change :removed) 0)
                  (format " −%d" (plist-get change :removed)) ""))
    ""))

(defun vigil-review--insert-file (root a b change)
  "Insert CHANGE, a file that differs between A and B of ROOT, to be read."
  (let* ((layout (vigil-review--layout root a b change))
         (file (plist-get change :file))
         (mark (vigil-review--mark (plist-get change :status)))
         (heading (point)))
    (insert (propertize
             (concat (propertize (car mark) 'face (cdr mark)) " " file "   "
                     (string-trim
                      (concat (pcase (plist-get change :status)
                                ("A" "new") ("D" "") (_ "changed"))
                              "  " (vigil-review--lines-said change)
                              (if (plist-get layout :note)
                                  (concat "  " (plist-get layout :note)) "")))
                     "\n")
             'vigil-review-heading file))
    (add-face-text-property heading (point) 'vigil-review-heading t)
    (let ((body (point))
          (text (plist-get layout :text)))
      (when text
        (insert text)
        (let ((place (lambda (position) (+ body position -1))))
          (pcase-dolist (`(,beginning . ,end) (plist-get layout :added))
            (let ((overlay (make-overlay (funcall place beginning) (funcall place end))))
              (overlay-put overlay 'face 'vigil-review-added)
              (overlay-put overlay 'vigil-review-change t)
              (overlay-put overlay 'evaporate t)))
          (pcase-dolist (`(,position . ,lines) (plist-get layout :removed))
            (let ((overlay (make-overlay (funcall place position) (funcall place position))))
              (overlay-put overlay 'vigil-review-change t)
              (overlay-put overlay 'before-string
                           (propertize (format "    ⌫ %d line%s taken out here\n"
                                               lines (if (= lines 1) "" "s"))
                                       'face 'vigil-review-removed))))
          (pcase-dolist (`(,beginning ,end ,lines) (plist-get layout :folds))
            (vigil-review--make-fold (funcall place beginning) (funcall place end)
                                     lines 'lines t)))
        ;; The file itself folds, under its heading.
        (when (> (point) body)
          (vigil-review--make-fold (1- body) (1- (point))
                                   (plist-get layout :lines) 'file nil)))
      (insert "\n")
      (push (list :file file :heading (copy-marker heading) :body (copy-marker body))
            vigil-review--files))))

(defun vigil-review--file-here ()
  "The file point is in, of this reading buffer: a plist, or nil."
  (cl-find-if (lambda (file) (<= (plist-get file :heading) (point)))
              vigil-review--files))

(defun vigil-review-next-file (&optional count)
  "Go to the next file's heading, or the COUNTth."
  (interactive "p")
  (let* ((headings (sort (mapcar (lambda (file) (marker-position (plist-get file :heading)))
                                 vigil-review--files)
                         #'<))
         (count (or count 1))
         (target (if (> count 0)
                     (nth (1- count) (seq-filter (lambda (h) (> h (point))) headings))
                   (nth (1- (- count))
                        (reverse (seq-filter (lambda (h) (< h (line-beginning-position)))
                                             headings))))))
    (if target
        (progn (goto-char target) (recenter 0))
      (message "No more files"))))

(defun vigil-review-previous-file (&optional count)
  "Go to the previous file's heading, or the COUNTth."
  (interactive "p")
  (vigil-review-next-file (- (or count 1))))

(defun vigil-review--changes-here ()
  "Where this buffer's changes begin, in order."
  (sort (delete-dups
         (mapcar #'overlay-start
                 (seq-filter (lambda (overlay) (overlay-get overlay 'vigil-review-change))
                             (overlays-in (point-min) (point-max)))))
        #'<))

(defun vigil-review--reveal ()
  "Unfold whatever is hiding point."
  (dolist (fold (vigil-review--folds (point) (1+ (point))))
    (when (and (vigil-review--folded-p fold)
               (< (overlay-start fold) (point)))
      (vigil-review--fold fold nil))))

(defun vigil-review-next-change (&optional backward)
  "Go to the next place the session changed; the one before, with BACKWARD."
  (interactive)
  (let* ((places (vigil-review--changes-here))
         (target (if backward
                     (car (last (seq-filter (lambda (p) (< p (point))) places)))
                   (seq-find (lambda (p) (> p (point))) places))))
    (if target
        (progn (goto-char target) (vigil-review--reveal))
      (message "No more changes"))))

(defun vigil-review-previous-change ()
  "Go to the place the session changed before this one."
  (interactive)
  (vigil-review-next-change t))

(defun vigil-review-visit ()
  "Visit the file point is in, at this line, as it is now."
  (interactive)
  (let* ((file (or (vigil-review--file-here) (user-error "No file here")))
         (name (expand-file-name (plist-get file :file) vigil-review--root))
         (line (max 1 (count-lines (plist-get file :body)
                                   (max (plist-get file :body)
                                        (min (point-max) (1+ (line-beginning-position))))))))
    (unless (file-exists-p name)
      (user-error "%s is not there now" (plist-get file :file)))
    (find-file-other-window name)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun vigil-review-follow ()
  "Lay this buffer over as many windows side by side as fit; or stop.
The windows scroll as one (`follow-mode'), each `vigil-review-follow-width'
columns or more."
  (interactive)
  (require 'follow)
  (if follow-mode
      (let ((windows vigil-review--windows))
        (follow-mode -1)
        (setq vigil-review--windows nil)
        (if windows
            (set-window-configuration windows)
          (delete-other-windows)))
    (let ((windows (current-window-configuration))
          (buffer (current-buffer)))
      (delete-other-windows)
      (dotimes (_ (1- (max 2 (/ (frame-width) vigil-review-follow-width))))
        (ignore-errors (split-window-right)))
      (balance-windows)
      (with-current-buffer buffer
        (setq vigil-review--windows windows)
        (follow-mode 1)))))

(defun vigil-review-diff-file ()
  "Show what changed in the file at point, as a diff."
  (interactive)
  (let ((file (or (get-text-property (point) 'vigil-review-file)
                  (plist-get (vigil-review--file-here) :file)
                  (user-error "No file here"))))
    (vigil-review--show-diff vigil-review--root
                             (car vigil-review--range) (cdr vigil-review--range)
                             file)))

(defun vigil-review--show-diff (root a b &optional file summary)
  "Show what differs between the commits A and B of ROOT: in FILE, or all.
Under SUMMARY.  In Magit where it is there and all is asked for."
  (if (and (null file)
           vigil-snapshot-use-magit
           (require 'magit-diff nil t)
           (require 'vigil-magit nil t))
      (vigil-magit-show-range root (concat a ".." b) (or summary "") nil)
    (let ((text (apply #'vigil-git root "diff" "--no-renames" a b "--"
                       (and file (list file)))))
      (with-current-buffer (get-buffer-create "*vigil changes*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (when summary (insert summary "\n\n"))
          (insert (or text ""))
          (goto-char (point-min)))
        (diff-mode)
        (setq buffer-read-only t
              default-directory root)
        (pop-to-buffer (current-buffer))))))

(defvar vigil-review-read-mode-map (make-sparse-keymap)
  "Keys of the buffer a session's files are read in.")

;; Set each time the file is loaded, so that loading it again gives a
;; buffer that is already open the keys that are new.
(define-key vigil-review-read-mode-map (kbd "TAB") #'vigil-review-toggle)
(define-key vigil-review-read-mode-map (kbd "<backtab>") #'vigil-review-toggle-all)
(define-key vigil-review-read-mode-map (kbd "n") #'vigil-review-next-file)
(define-key vigil-review-read-mode-map (kbd "p") #'vigil-review-previous-file)
(define-key vigil-review-read-mode-map (kbd "]") #'vigil-review-next-change)
(define-key vigil-review-read-mode-map (kbd "[") #'vigil-review-previous-change)
(define-key vigil-review-read-mode-map (kbd "RET") #'vigil-review-visit)
(define-key vigil-review-read-mode-map (kbd "o") #'vigil-review-visit)
(define-key vigil-review-read-mode-map (kbd "d") #'vigil-review-diff-file)
(define-key vigil-review-read-mode-map (kbd "F") #'vigil-review-follow)

(define-derived-mode vigil-review-read-mode special-mode "Review"
  "What a session built, to be read: its files, one after another.
\\<vigil-review-read-mode-map>The lines it put in are highlighted, and the
definitions it did not touch are folded: \\[vigil-review-toggle] folds and unfolds one,
\\[vigil-review-toggle-all] all.  \\[vigil-review-next-file] and \\[vigil-review-previous-file] go by file, \\[vigil-review-next-change] and \\[vigil-review-previous-change] by change.
\\[vigil-review-visit] visits the file, \\[vigil-review-diff-file] shows its diff, and \\[vigil-review-follow] lays the buffer
over several windows."
  (setq truncate-lines t))

(defun vigil-review-read (root a b &optional title file)
  "Lay out, to be read, the files that differ between the commits A and B.
Of the repository at ROOT; under TITLE; at FILE, where one is named.  The
new ones first, then those that changed, then the names of those gone.
Gives the buffer."
  (let ((changes (vigil-review-changes root a b))
        (buffer (get-buffer-create (format "*vigil read: %s*"
                                           (or title (abbreviate-file-name root))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (when (bound-and-true-p follow-mode) (follow-mode -1))
        (remove-overlays)
        (erase-buffer)
        (vigil-review-read-mode)
        (setq vigil-review--root root
              vigil-review--range (cons a b)
              vigil-review--files nil
              default-directory root)
        (insert (propertize (format "%s: %s" (or title (abbreviate-file-name root))
                                    (vigil-review--count changes))
                            'face 'bold)
                "\n\n")
        (dolist (kind '(new changed gone))
          (dolist (change changes)
            (when (eq kind (pcase (plist-get change :status)
                             ("A" 'new) ("D" 'gone) (_ 'changed)))
              (vigil-review--insert-file root a b change))))
        (goto-char (or (and file
                            (plist-get (cl-find file vigil-review--files
                                                :key (lambda (f) (plist-get f :file))
                                                :test #'equal)
                                       :heading))
                       (point-min)))))
    (pop-to-buffer-same-window buffer)
    (when (> (point) (point-min)) (recenter 0))
    buffer))

;;;; The overview

(defvar-local vigil-review--from nil "The snapshot this overview's session begins at.")
(defvar-local vigil-review--span nil "What `vigil-review-span' says of this overview's session.")
(defvar-local vigil-review--frame nil
  "Which of the session's moments is shown, counting from 0; nil for its end.")
(defvar-local vigil-review--known nil "The changes already asked of git, by their two commits.")
(defvar-local vigil-review--timer nil "The timer playing this overview, if one is.")

(defun vigil-review--between (a b)
  "The changes between the snapshots A and B, asked of git once."
  (let* ((key (concat (plist-get a :commit) (plist-get b :commit)))
         (known (or (gethash key vigil-review--known)
                    (puthash key
                             ;; Nothing is something known, too.
                             (or (vigil-review-changes vigil-review--root
                                                       (plist-get a :commit)
                                                       (plist-get b :commit))
                                 'none)
                             vigil-review--known))))
    (and (listp known) known)))

(defun vigil-review--clock (time &optional seconds)
  "TIME as the overview says it: with the day, where the session has several."
  (let* ((span vigil-review--span)
         (day (lambda (snapshot)
                (format-time-string "%F" (plist-get snapshot :time)))))
    (format-time-string
     (concat (if (and span (not (equal (funcall day (plist-get span :from))
                                       (funcall day (plist-get span :to)))))
                 "%b %d " "")
             (if seconds "%H:%M:%S" "%H:%M"))
     time)))

(defun vigil-review--place (snapshot)
  "Where SNAPSHOT comes among the session's: a number, greater for later."
  (or (cl-position snapshot (plist-get vigil-review--span :order)) 0))

(defun vigil-review--shown ()
  "The snapshot the overview shows the files as of."
  (let ((span vigil-review--span))
    (or (and vigil-review--frame (nth vigil-review--frame (plist-get span :frames)))
        (plist-get span :to))))

(defun vigil-review--prompt-end (index)
  "The snapshot that ends the INDEXth prompt of the session: the next one's,
or the session's end."
  (let ((span vigil-review--span))
    (or (nth (1+ index) (plist-get span :prompts)) (plist-get span :to))))

(defun vigil-review--insert-tree (changes touched)
  "Insert CHANGES as a tree of directories and files; those in TOUCHED marked."
  (let ((width (apply #'max 20 (mapcar (lambda (change)
                                         (+ 4 (* 2 (length (split-string
                                                            (plist-get change :file) "/")))
                                            (length (file-name-nondirectory
                                                     (plist-get change :file)))))
                                       changes)))
        (open nil))
    (dolist (change changes)
      (let* ((parts (split-string (plist-get change :file) "/"))
             (directories (butlast parts))
             (depth 0))
        ;; Name each directory once, where it is first gone into.
        (while (and directories open (equal (car directories) (car open)))
          (setq directories (cdr directories) open (cdr open) depth (1+ depth)))
        (dolist (directory directories)
          (insert (make-string (+ 2 (* 2 depth)) ?\s)
                  (propertize (concat directory "/") 'face 'shadow)
                  "\n")
          (setq depth (1+ depth)))
        (setq open (butlast parts))
        (let* ((mark (vigil-review--mark (plist-get change :status)))
               (just (member (plist-get change :file) touched))
               (line (concat (make-string (+ 2 (* 2 depth)) ?\s)
                             (propertize (car mark) 'face (cdr mark)) " "
                             (propertize (car (last parts))
                                         'face (and just 'vigil-review-touched)))))
          (insert (propertize
                   (concat line
                           (make-string (max 2 (- width (string-width line))) ?\s)
                           (vigil-ui-lines-changed (plist-get change :added)
                                                   (plist-get change :removed))
                           (if just (propertize "  ●" 'face 'vigil-review-touched) "")
                           "\n")
                   'vigil-review-file (plist-get change :file))))))))

(defun vigil-review--render ()
  "Draw the overview again, from what it knows."
  (let* ((inhibit-read-only t)
         (span vigil-review--span)
         (root vigil-review--root)
         (from (plist-get span :from))
         (frames (plist-get span :frames))
         (shown (vigil-review--shown))
         (changes (vigil-review--between from shown))
         (before (and vigil-review--frame
                      (if (> vigil-review--frame 0)
                          (nth (1- vigil-review--frame) frames)
                        from)))
         (touched (and before
                       (mapcar (lambda (change) (plist-get change :file))
                               (vigil-review--between before shown))))
         (history (ignore-errors (vigil-history root)))
         (prompts (plist-get span :prompts))
         ;; The prompt the moment shown is in: the last given before it.
         (current (and vigil-review--frame
                       (max 0 (1- (cl-count-if
                                   (lambda (prompt)
                                     (< (vigil-review--place prompt)
                                        (vigil-review--place shown)))
                                   prompts)))))
         (line (line-number-at-pos))
         (width (vigil-ui-begin))
         (index 0))
    (erase-buffer)
    (setq header-line-format
          (replace-regexp-in-string
           "%" "%%"
           (concat " "
                   (propertize (or (plist-get span :host) (plist-get span :session)
                                   "A session")
                               'face 'vigil-ui-strong)
                   (propertize (concat (if (plist-get span :agent)
                                           (format "   %s" (plist-get span :agent))
                                         "")
                                       "   "
                                       (abbreviate-file-name (directory-file-name root))
                                       "   what it built")
                               'face 'vigil-ui-dim))))
    (vigil-ui-sheet
     `(("From" . ,(vigil-review--clock (plist-get from :time)))
       ("To" . ,(format "%s, %s"
                        (vigil-review--clock (plist-get (plist-get span :to) :time))
                        (if (eq (plist-get span :end) 'stopped)
                            "when its agent stopped" "which is now")))
       ("Prompts" . ,(number-to-string (length prompts)))
       ("Showing" . ,(if vigil-review--frame
                         (propertize
                          (format "moment %d of %d, as it was at %s"
                                  (1+ vigil-review--frame) (length frames)
                                  (vigil-review--clock (plist-get shown :time) t))
                          'face 'vigil-ui-busy)
                       "its end"))
       ("Changed" . ,(vigil-review--count changes))))
    (vigil-ui-heading "Prompts")
    (pcase-let ((`(,header . ,lines)
                 (vigil-ui-table
                  '((:title "#" :right t) (:title "When") (:title "Prompt" :flex t)
                    (:title "Files" :right t) (:title "Lines"))
                  (mapcar
                   (lambda (prompt)
                     (let* ((id (plist-get prompt :prompt))
                            (text (plist-get (and history (vigil-history-prompt history id))
                                             :text))
                            (after (vigil-review--between
                                    prompt (vigil-review--prompt-end index))))
                       (setq index (1+ index))
                       (list (propertize (number-to-string index) 'face 'vigil-ui-strong)
                             (vigil-review--clock (plist-get prompt :time))
                             (or text (format "prompt %s" id))
                             (if after (number-to-string (length after)) "")
                             (if after
                                 (pcase-let ((`(,_ ,_ ,_ ,added ,removed)
                                              (vigil-review--totals after)))
                                   (vigil-ui-lines-changed added removed))
                               ""))))
                   prompts)
                  width)))
      (insert header "\n")
      (setq index 0)
      (dolist (row lines)
        (insert (propertize (concat (if (eql index current)
                                        (concat (propertize "▸" 'face 'vigil-ui-busy)
                                                (substring row 1))
                                      row)
                                    "\n")
                            'vigil-review-prompt index))
        (setq index (1+ index))))
    (vigil-ui-heading "Files")
    (if changes
        (vigil-review--insert-tree changes touched)
      (insert (propertize "  None differs from when the session began.\n"
                          'face 'vigil-ui-dim)))
    (insert "\n"
            (propertize
             (substitute-command-keys
              (concat "\\<vigil-review-mode-map>\\[vigil-review-act] read a file, or go to a prompt's end   "
                      "\\[vigil-review-read-all] read them all   \\[vigil-review-diff] diff\n"
                      "\\[vigil-review-forward] \\[vigil-review-backward] step through time   "
                      "\\[vigil-review-play] play   \\[vigil-review-end] its end   "
                      "\\[vigil-review-choose] another beginning\n"))
             'face 'vigil-ui-dim))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun vigil-review--load ()
  "Read the session's snapshots again, and draw the overview."
  (setq vigil-review--span (vigil-review-span vigil-review--root vigil-review--from)
        vigil-review--known (make-hash-table :test #'equal))
  (when (and vigil-review--frame
             (>= vigil-review--frame (length (plist-get vigil-review--span :frames))))
    (setq vigil-review--frame nil))
  (vigil-review--render))

(defun vigil-review-refresh ()
  "Read the session's snapshots again."
  (interactive)
  (vigil-review--stop)
  (vigil-review--load))

(defun vigil-review--stop ()
  "Stop playing."
  (when vigil-review--timer
    (cancel-timer vigil-review--timer)
    (setq vigil-review--timer nil)))

(defun vigil-review-forward (&optional count)
  "Show the files as they were a moment later, or COUNT moments.
From the session's end, begin again at its first."
  (interactive "p")
  (let* ((frames (length (plist-get vigil-review--span :frames)))
         (next (+ (or count 1) (or vigil-review--frame (if (> (or count 1) 0) -1 frames)))))
    (cond ((= frames 0) (message "Nothing changed in this session"))
          ((< next 0) (message "This is its first moment"))
          ((>= next frames)
           (setq vigil-review--frame nil)
           (vigil-review--render)
           (message "This is its end"))
          (t (setq vigil-review--frame next)
             (vigil-review--render)))))

(defun vigil-review-backward (&optional count)
  "Show the files as they were a moment earlier, or COUNT moments."
  (interactive "p")
  (vigil-review-forward (- (or count 1))))

(defun vigil-review-end ()
  "Show the files as the session left them."
  (interactive)
  (vigil-review--stop)
  (setq vigil-review--frame nil)
  (vigil-review--render))

(defun vigil-review-play ()
  "Play the session from the moment shown, or from its first; or stop."
  (interactive)
  (if vigil-review--timer
      (progn (vigil-review--stop) (message "Stopped"))
    (let ((buffer (current-buffer)))
      (unless vigil-review--frame (vigil-review-forward))
      (setq vigil-review--timer
            (run-with-timer
             vigil-review-play-seconds vigil-review-play-seconds
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer (vigil-review--tick)))))))))

(defun vigil-review--tick ()
  "Play one moment more, and stop at the end."
  (if (and vigil-review--frame
           (< (1+ vigil-review--frame) (length (plist-get vigil-review--span :frames))))
      (let ((window (get-buffer-window (current-buffer))))
        (if window
            (with-selected-window window (vigil-review-forward))
          (vigil-review-forward)))
    (vigil-review--stop)))

(defun vigil-review--title ()
  "What the session is called, and as of when if not its end."
  (concat (or (plist-get vigil-review--span :host)
              (plist-get vigil-review--span :session) "session")
          (if vigil-review--frame
              (format " at %s"
                      (vigil-review--clock (plist-get (vigil-review--shown) :time) t))
            "")))

(defun vigil-review-read-all (&optional file)
  "Lay out, to be read, the files shown; at FILE, where one is named."
  (interactive)
  (vigil-review--stop)
  (vigil-review-read vigil-review--root
                     (plist-get (plist-get vigil-review--span :from) :commit)
                     (plist-get (vigil-review--shown) :commit)
                     (vigil-review--title) file))

(defun vigil-review-act ()
  "On a file, read it; on a prompt, show the files as that prompt left them."
  (interactive)
  (let ((file (get-text-property (point) 'vigil-review-file))
        (prompt (get-text-property (point) 'vigil-review-prompt)))
    (cond
     (file (vigil-review-read-all file))
     (prompt
      (vigil-review--stop)
      (let* ((frames (plist-get vigil-review--span :frames))
             (end (vigil-review--prompt-end prompt))
             ;; The last moment up to where the prompt ends.
             (index (1- (cl-count-if (lambda (frame)
                                       (<= (vigil-review--place frame)
                                           (vigil-review--place end)))
                                     frames))))
        (setq vigil-review--frame
              (and (>= index 0) (< (1+ index) (length frames)) index))
        (vigil-review--render)))
     (t (user-error "Neither a file nor a prompt here")))))

(defun vigil-review-diff ()
  "Show a diff: of the file at point, of what changed after the prompt at
point, or else of everything shown."
  (interactive)
  (let ((file (get-text-property (point) 'vigil-review-file))
        (prompt (get-text-property (point) 'vigil-review-prompt))
        (a (plist-get (plist-get vigil-review--span :from) :commit))
        (b (plist-get (vigil-review--shown) :commit)))
    (cond
     (file (vigil-review--show-diff vigil-review--root a b file))
     (prompt
      (vigil-review--show-diff
       vigil-review--root
       (plist-get (nth prompt (plist-get vigil-review--span :prompts)) :commit)
       (plist-get (vigil-review--prompt-end prompt) :commit)
       nil (format "Changed after prompt %d of %s" (1+ prompt) (vigil-review--title))))
     (t (vigil-review--show-diff vigil-review--root a b nil
                                 (format "Changed in %s" (vigil-review--title)))))))

(defun vigil-review-visit-file ()
  "Visit the file at point, as it is now."
  (interactive)
  (let ((file (or (get-text-property (point) 'vigil-review-file)
                  (user-error "No file here"))))
    (find-file-other-window (expand-file-name file vigil-review--root))))

(defun vigil-review--choose (root)
  "Ask which of ROOT's sessions to review, and from which beginning."
  (let* ((history (ignore-errors (vigil-history root)))
         (sessions (or (vigil-review-sessions root)
                       (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                   (abbreviate-file-name root))))
         (choices
          (mapcar (lambda (session)
                    (let* ((from (plist-get session :from))
                           (text (plist-get (and history
                                                 (vigil-history-prompt
                                                  history (plist-get from :prompt)))
                                            :text)))
                      (cons (format "%s  %-20s %2d prompt%s  %s"
                                    (format-time-string "%m-%d %H:%M" (plist-get session :time))
                                    (or (plist-get session :host) (plist-get session :session))
                                    (plist-get session :prompts)
                                    (if (= 1 (plist-get session :prompts)) " " "s")
                                    (if text (vigil-base-one-line text 60) ""))
                            session)))
                  sessions))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate)))))
    (cdr (assoc (completing-read "Review from: " table nil t) choices))))

(defun vigil-review-choose ()
  "Review from another beginning: an earlier one of this session, or another's."
  (interactive)
  (let ((session (vigil-review--choose vigil-review--root)))
    (vigil-review--stop)
    (vigil-review--open vigil-review--root session)))

(defvar vigil-review-mode-map (make-sparse-keymap)
  "Keys of a session's overview.")

;; Set each time the file is loaded, so that loading it again gives a
;; buffer that is already open the keys that are new.
(define-key vigil-review-mode-map (kbd "RET") #'vigil-review-act)
(define-key vigil-review-mode-map (kbd "r") #'vigil-review-read-all)
(define-key vigil-review-mode-map (kbd "d") #'vigil-review-diff)
(define-key vigil-review-mode-map (kbd "o") #'vigil-review-visit-file)
(define-key vigil-review-mode-map (kbd ">") #'vigil-review-forward)
(define-key vigil-review-mode-map (kbd ".") #'vigil-review-forward)
(define-key vigil-review-mode-map (kbd "<") #'vigil-review-backward)
(define-key vigil-review-mode-map (kbd ",") #'vigil-review-backward)
(define-key vigil-review-mode-map (kbd "SPC") #'vigil-review-play)
(define-key vigil-review-mode-map (kbd "e") #'vigil-review-end)
(define-key vigil-review-mode-map (kbd "s") #'vigil-review-choose)
(define-key vigil-review-mode-map (kbd "g") #'vigil-review-refresh)
(define-key vigil-review-mode-map (kbd "n") #'next-line)
(define-key vigil-review-mode-map (kbd "p") #'previous-line)

(define-derived-mode vigil-review-mode special-mode "Review"
  "What a session built, in short: its prompts, and the files it left
new, changed or gone, against what was there when it began.
\\<vigil-review-mode-map>\\[vigil-review-act] on a file lays the files out to be read, at that one; on a prompt it
shows the files as that prompt left them.  \\[vigil-review-forward] and \\[vigil-review-backward] step through
the session a snapshot at a time, \\[vigil-review-play] plays it, and \\[vigil-review-end] goes back to its
end.  \\[vigil-review-diff] shows a diff of what is at point, \\[vigil-review-read-all] lays every file out, and
\\[vigil-review-choose] reviews from another beginning."
  (vigil-ui-fit #'vigil-review--render)
  (add-hook 'kill-buffer-hook #'vigil-review--stop nil t))

(defun vigil-review--open (root session)
  "Show the overview of SESSION, one of `vigil-review-sessions', in ROOT."
  (let ((buffer (get-buffer-create
                 (format "*vigil review: %s*"
                         (or (plist-get session :host) (plist-get session :session))))))
    (with-current-buffer buffer
      (vigil-review-mode)
      (setq vigil-review--root root
            vigil-review--from (plist-get session :from)
            vigil-review--frame nil
            default-directory root)
      (vigil-review--load)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun vigil-review (&optional choose)
  "Show what a session built, against what was there when it began.
In an agent's buffer, that agent's session, from its latest beginning; and
elsewhere in a repository, the session last at work in it.  With a prefix
argument, CHOOSE the session and the beginning."
  (interactive "P")
  (let* ((root (or (vigil-git-root) (user-error "Not in a repository")))
         (host (and (boundp 'cooked-host-name) (stringp cooked-host-name)
                    cooked-host-name))
         (sessions (or (vigil-review-sessions root)
                       (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                   (abbreviate-file-name root))))
         (session (cond
                   (choose (vigil-review--choose root))
                   (host (or (cl-find host sessions
                                      :key (lambda (s) (plist-get s :host)) :test #'equal)
                             (user-error "No snapshot is kept of %s in %s"
                                         host (abbreviate-file-name root))))
                   (t (car sessions)))))
    (vigil-review--open root session)))

(provide 'vigil-review)
;;; vigil-review.el ends here
