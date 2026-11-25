;;; vigil-ui.el --- How vigil's buffers are laid out -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools

;;; Commentary:

;; The few things vigil's buffers are made of, so that they are made the
;; same way everywhere:
;;
;; - a sheet: labels in one column, what each says in the next;
;; - a heading, over what is under it;
;; - a table: columns as wide as what is in them, numbers to the right, and
;;   one column that takes what room the window has left and is cut to it;
;; - a block: a prompt or a reply, filled, with a rule down its left side;
;; - a fold: what is under a line, hidden or showing, with a mark that
;;   says which;
;; - tabs, in the tab line: the views there are, and which is showing.
;;
;; A buffer laid out with these has `word-wrap' on and lines not truncated:
;; text wraps, and a table never needs to, being fitted to the window.  When
;; the window's width changes the buffer is drawn again (`vigil-ui-fit').
;;
;; Every face here inherits a standard one and sets nothing of its own, so a
;; theme that styles `bold', `shadow', `warning', `error', `success' and the
;; tab line has styled vigil.
;;
;; Needs only Emacs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tab-line)

(defgroup vigil-ui nil
  "How vigil's buffers are laid out."
  :group 'vigil)

(defcustom vigil-ui-max-width 140
  "The widest a buffer is laid out, in columns, however wide its window."
  :type 'integer)

(defcustom vigil-ui-text-width 88
  "The widest a prompt or a reply is laid out, in columns: text is filled to it.
However wide the window; narrower, where the window is."
  :type 'integer)

(defface vigil-ui-heading '((t :inherit bold))
  "A heading, over what is under it.")

(defface vigil-ui-dim '((t :inherit shadow))
  "What is said beside the point: labels, notes, units.")

(defface vigil-ui-strong '((t :inherit bold))
  "What a line is about: the name it goes by.")

(defface vigil-ui-key '((t :inherit help-key-binding))
  "A key.")

(defface vigil-ui-good '((t :inherit success))
  "What was added, or went well.")

(defface vigil-ui-bad '((t :inherit error))
  "What was taken out, or failed.")

(defface vigil-ui-busy '((t :inherit warning))
  "What is still going.")

(defface vigil-ui-code '((t :inherit font-lock-constant-face))
  "Code, in text.")

(defface vigil-ui-prompt '((t :inherit font-lock-keyword-face))
  "A prompt.")

(defface vigil-ui-reply '((t :inherit default))
  "A reply.")

(defface vigil-ui-kind-command '((t :inherit warning))
  "A command, in a timeline.")

(defface vigil-ui-kind-edit '((t :inherit success))
  "An edit, in a timeline.")

(defface vigil-ui-kind-test '((t :inherit font-lock-string-face))
  "A run of tests, or a check, in a timeline.")

(defface vigil-ui-kind-read '((t :inherit shadow))
  "A read or a search, in a timeline.")

(defface vigil-ui-kind-subagent '((t :inherit font-lock-keyword-face))
  "A subagent, in a timeline.")

(defface vigil-ui-kind-other '((t :inherit font-lock-constant-face))
  "Any other call, in a timeline.")

(defface vigil-ui-tab '((t :inherit tab-line-tab-inactive))
  "A view that is not showing, in the tab line.")

(defface vigil-ui-tab-current '((t :inherit (bold tab-line-tab-current)))
  "The view that is showing, in the tab line.")

;;;; Width

(defun vigil-ui-width (&optional buffer)
  "How many columns BUFFER, by default this one, is to be laid out in.
Those of the window it shows in, or of the selected one; at least 60, and no
more than `vigil-ui-max-width'."
  (let ((window (or (get-buffer-window (or buffer (current-buffer)) t)
                    (selected-window))))
    ;; Asking a window its width selects it for a moment, which puts its
    ;; buffer's point where the window's is: in the middle of laying that
    ;; buffer out, that is somewhere else.
    (save-excursion
      (max 60 (min vigil-ui-max-width (1- (window-max-chars-per-line window)))))))

(defvar-local vigil-ui--width nil "The width this buffer was last laid out in.")
(defvar-local vigil-ui--redraw nil "The function that draws this buffer again.")

(defun vigil-ui--refit (&rest _)
  "Draw this buffer again if its window's width is no longer what it was."
  (when (and vigil-ui--redraw vigil-ui--width
             (get-buffer-window (current-buffer) t)
             (/= vigil-ui--width (vigil-ui-width)))
    (funcall vigil-ui--redraw)))

(defun vigil-ui-fit (redraw)
  "Make this buffer one laid out to its window: wrapped at words, and drawn
again by REDRAW, a function of no arguments, when the window's width changes."
  (setq truncate-lines nil
        word-wrap t
        vigil-ui--redraw redraw)
  (add-hook 'window-size-change-functions #'vigil-ui--refit nil t)
  (add-hook 'window-configuration-change-hook #'vigil-ui--refit nil t))

(defun vigil-ui-begin ()
  "Note the width this buffer is about to be laid out in, and give it."
  (setq vigil-ui--width (vigil-ui-width)))

;;;; Text

(defun vigil-ui-cut (text width)
  "TEXT on one line, in no more than WIDTH columns: cut with an ellipsis."
  (let ((line (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))))
    (if (> (string-width line) width)
        (truncate-string-to-width line (max 1 width) nil nil "…")
      line)))

(defun vigil-ui-pad (text width &optional right)
  "TEXT in exactly WIDTH columns: spaces after it, or before it with RIGHT."
  (let ((space (make-string (max 0 (- width (string-width text))) ?\s)))
    (if right (concat space text) (concat text space))))

(defun vigil-ui-lines-changed (added removed)
  "Lines put in and taken out, ADDED and REMOVED, in a few characters."
  (concat (if (and added (> added 0))
              (propertize (format "+%d" added) 'face 'vigil-ui-good)
            "")
          (if (and added removed (> added 0) (> removed 0)) " " "")
          (if (and removed (> removed 0))
              (propertize (format "−%d" removed) 'face 'vigil-ui-bad)
            "")))

(defun vigil-ui-plural (count word &optional plural)
  "COUNT of WORD: \"1 file\", \"3 files\"; PLURAL where adding s is not it."
  (format "%d %s" count (if (= count 1) word (or plural (concat word "s")))))

;;;; A heading

(defun vigil-ui-heading (title &optional note key)
  "Insert the heading TITLE, a blank line above it.
NOTE is said after it, beside the point; KEY is the key that shows more of
what is under it."
  (unless (bobp) (insert "\n"))
  (insert (propertize title 'face 'vigil-ui-heading)
          (if note (propertize (concat "  " note) 'face 'vigil-ui-dim) "")
          (if key
              (concat "  " (propertize key 'face 'vigil-ui-key))
            "")
          "\n"))

;;;; A sheet

(defun vigil-ui-sheet (rows &optional indent)
  "Insert ROWS, each (LABEL . TEXT), as a sheet: labels in one column.
A row whose TEXT is nil is left out.  What a row says wraps under where it
began.  INDENT spaces before each, default none."
  (let* ((rows (seq-filter #'cdr rows))
         (indent (or indent 0))
         (width (+ 2 (apply #'max 0 (mapcar (lambda (row) (string-width (car row)))
                                            rows)))))
    (dolist (row rows)
      (let ((start (point)))
        (insert (make-string indent ?\s)
                (propertize (vigil-ui-pad (car row) width) 'face 'vigil-ui-dim)
                (cdr row) "\n")
        (put-text-property start (point) 'wrap-prefix
                           (make-string (+ indent width) ?\s))))))

;;;; A table

(defun vigil-ui-table (columns rows &optional width indent)
  "Lay ROWS out in COLUMNS, and give the lines: (HEADER . LINES).
COLUMNS are plists: :title; :right, to put what is in it to the right; :flex,
for the one column that takes what room is left and is cut to it.  ROWS are
lists of strings, one a column, which may have faces.  WIDTH is how many
columns there are to lay out in, default the window's; INDENT spaces come
before each line, default 2.  HEADER and each of LINES are strings with no
newline; LINES are in ROWS' order.

No line is wider than WIDTH unless what is not flexible already is."
  (let* ((width (or width (vigil-ui-width)))
         (indent (or indent 2))
         (count (length columns))
         (widths (make-vector count 0))
         (flex (cl-position-if (lambda (column) (plist-get column :flex)) columns))
         ;; What is cut is first put on one line: that is what is measured.
         (rows (if flex
                   (mapcar (lambda (row)
                             (let ((row (copy-sequence row)))
                               (when (nth flex row)
                                 (setf (nth flex row)
                                       (vigil-ui-cut (nth flex row) most-positive-fixnum)))
                               row))
                           rows)
                 rows)))
    (dotimes (i count)
      (let ((column (nth i columns)))
        (aset widths i
              (apply #'max (string-width (or (plist-get column :title) ""))
                     (mapcar (lambda (row) (string-width (or (nth i row) ""))) rows)))))
    (when flex
      (let ((others (+ indent (* 2 (1- count))
                       (apply #'+ (cl-loop for i below count
                                           unless (= i flex) collect (aref widths i))))))
        (aset widths flex (max 12 (min (aref widths flex) (- width others))))))
    (let ((line (lambda (cells)
                  (let ((parts nil))
                    (dotimes (i count)
                      (let* ((column (nth i columns))
                             (cell (or (nth i cells) ""))
                             (cell (if (eql i flex)
                                       (vigil-ui-cut cell (aref widths i))
                                     cell)))
                        (push (if (and (= i (1- count)) (not (plist-get column :right)))
                                  ;; Nothing after the last: no spaces to end on.
                                  cell
                                (vigil-ui-pad cell (aref widths i)
                                              (plist-get column :right)))
                              parts)))
                    ;; Columns with nothing in them at the end leave no spaces.
                    (string-trim-right
                     (concat (make-string indent ?\s)
                             (string-join (nreverse parts) "  ")))))))
      (cons (propertize (funcall line (mapcar (lambda (column)
                                                (or (plist-get column :title) ""))
                                              columns))
                        'face 'vigil-ui-dim)
            (mapcar line rows)))))

(defun vigil-ui-insert-table (columns rows &optional properties width indent)
  "Insert ROWS laid out in COLUMNS, under a line naming the columns.
As `vigil-ui-table' lays them out, in WIDTH and after INDENT.  PROPERTIES,
if given, is a list as long as ROWS of the text properties each line has."
  (pcase-let ((`(,header . ,lines) (vigil-ui-table columns rows width indent)))
    (insert header "\n")
    (dolist (line lines)
      (insert (apply #'propertize (concat line "\n") (pop properties))))))

;;;; A block of text, and Markdown shown

(defun vigil-ui-fill (text width)
  "TEXT with its lines broken at words so that none is wider than WIDTH.
What follows a break hangs under where its line's words began: under an
item's words, not its bullet.  Lines of a fenced block and of a table are
left as they are.  Faces are kept."
  (with-temp-buffer
    (insert (or text ""))
    (goto-char (point-min))
    (let ((fenced nil))
      (while (not (eobp))
        (cond
         ((looking-at "[ \t]*```") (setq fenced (not fenced)))
         ((or fenced (looking-at "[ \t]*|")))
         (t
          (let ((hang (if (looking-at "[ \t]*\\(?:\\(?:[-*•]\\|[0-9]+[.)]\\) +\\)?")
                          (- (match-end 0) (match-beginning 0))
                        0))
                (going t))
            (while (and going (> (- (line-end-position) (line-beginning-position)) width))
              (let ((start (line-beginning-position)))
                (goto-char (+ start width))
                (if (or (re-search-backward " +" (+ start hang 1) t)
                        (re-search-forward " +" (line-end-position) t))
                    (progn
                      (replace-match "")
                      (insert "\n" (make-string hang ?\s))
                      (beginning-of-line))
                  (setq going nil)))))))
        (forward-line 1)))
    (buffer-string)))

(defun vigil-ui-block (text indent face &rest properties)
  "Insert TEXT as a block of its own: filled, with a rule down its left side.
INDENT spaces in, the rule in FACE.  The text is filled to
`vigil-ui-text-width', or to the window where that is narrower.  Neither the
spaces nor the rule are in the buffer.  PROPERTIES are text properties the
whole of it has."
  (let* ((start (point))
         (prefix (concat (make-string indent ?\s) (propertize "│ " 'face face)))
         (width (max 30 (min vigil-ui-text-width
                             (- (or vigil-ui--width (vigil-ui-width)) indent 3)))))
    (insert (string-trim-right (vigil-ui-fill (or text "") width)) "\n")
    (add-text-properties start (point)
                         (append (list 'line-prefix prefix 'wrap-prefix prefix)
                                 properties))))

(defun vigil-ui-markdown (text)
  "TEXT, written as Markdown, with what it marks shown and the marks hidden.
Only what a reply is made of: headings, bold, code in a line and in a
fenced block, and list bullets.  The text is not changed, so it copies as
it was written."
  (with-temp-buffer
    (insert (or text ""))
    (goto-char (point-min))
    (let ((fenced nil))
      (while (not (eobp))
        (let ((start (line-beginning-position)) (end (line-end-position)))
          (cond
           ((looking-at "[ \t]*```")
            (setq fenced (not fenced))
            (put-text-property start end 'face 'vigil-ui-dim))
           (fenced (put-text-property start end 'face 'vigil-ui-code))
           (t
            (when (looking-at "\\(#+ +\\)\\(.*\\)$")
              (put-text-property (match-beginning 1) (match-end 1) 'invisible t)
              (put-text-property (match-beginning 2) (match-end 2)
                                 'face 'vigil-ui-heading))
            (when (looking-at "[ \t]*\\([-*]\\) ")
              (put-text-property (match-beginning 1) (match-end 1) 'display "•"))
            (while (re-search-forward "`\\([^`\n]+\\)`" end t)
              (put-text-property (match-beginning 0) (match-beginning 1) 'invisible t)
              (put-text-property (match-end 1) (match-end 0) 'invisible t)
              (put-text-property (match-beginning 1) (match-end 1)
                                 'face 'vigil-ui-code))
            (goto-char start)
            (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" end t)
              (unless (eq (get-text-property (match-beginning 0) 'face) 'vigil-ui-code)
                (put-text-property (match-beginning 0) (match-beginning 1) 'invisible t)
                (put-text-property (match-end 1) (match-end 0) 'invisible t)
                (add-face-text-property (match-beginning 1) (match-end 1)
                                        'vigil-ui-strong))))))
        (forward-line 1)))
    (buffer-string)))

;;;; Folds: what is under a line, hidden or showing

(defun vigil-ui-fold-make (beginning end lines kind folded)
  "Make BEGINNING to END a fold of LINES lines, of KIND, FOLDED or not.
BEGINNING is the end of the line that stays showing."
  (let ((fold (make-overlay beginning end))
        (tag (make-overlay (max (point-min) (1- beginning)) beginning)))
    (overlay-put fold 'vigil-ui-fold kind)
    (overlay-put fold 'vigil-ui-fold-lines lines)
    (overlay-put fold 'vigil-ui-fold-tag tag)
    (overlay-put fold 'evaporate t)
    (overlay-put tag 'evaporate t)
    (overlay-put fold 'isearch-open-invisible
                 (lambda (overlay) (vigil-ui-fold-set overlay nil)))
    (vigil-ui-fold-set fold folded)
    fold))

(defun vigil-ui-fold-set (fold folded)
  "Hide what is in FOLD if FOLDED, and else show it."
  (overlay-put fold 'invisible (and folded t))
  (if-let* ((marker (overlay-get fold 'vigil-ui-fold-marker)))
      ;; A fold with a marker says which way it is at the line's beginning.
      (overlay-put marker 'display (if folded "▸" "▾"))
    ;; Otherwise how much is hidden is said after the line that stays: as
    ;; part of its last character, since a string of its own beside hidden
    ;; text is hidden with it.
    (let* ((tag (overlay-get fold 'vigil-ui-fold-tag))
           (lines (overlay-get fold 'vigil-ui-fold-lines)))
      (overlay-put tag 'display
                   (and folded
                        (overlay-buffer tag)
                        (concat (with-current-buffer (overlay-buffer tag)
                                  (buffer-substring (overlay-start tag) (overlay-end tag)))
                                (propertize (format "  ⋯ %d line%s"
                                                    lines (if (= 1 lines) "" "s"))
                                            'face 'shadow)))))))

(defun vigil-ui-fold-mark (fold)
  "Have FOLD say whether it is folded at the beginning of its line.
With a mark in place of the line's first character, which is to be a space;
and no longer after the line."
  (let* ((start (save-excursion (goto-char (overlay-start fold))
                                (line-beginning-position)))
         (marker (make-overlay start (1+ start))))
    (overlay-put marker 'evaporate t)
    (overlay-put fold 'vigil-ui-fold-marker marker)
    (overlay-put (overlay-get fold 'vigil-ui-fold-tag) 'display nil)
    (vigil-ui-fold-set fold (vigil-ui-folded-p fold))
    fold))

(defun vigil-ui-folded-p (fold)
  "Whether FOLD is hiding what is in it."
  (and (overlay-get fold 'invisible) t))

(defun vigil-ui-folds (&optional beginning end)
  "The folds between BEGINNING and END, by default all of this buffer's."
  (seq-filter (lambda (overlay) (overlay-get overlay 'vigil-ui-fold))
              (overlays-in (or beginning (point-min)) (or end (point-max)))))

(defun vigil-ui-fold-here ()
  "The fold of this line: the one it is the first line of, or else the
smallest that point is in."
  (let ((end (line-end-position)))
    (or (cl-find end (vigil-ui-folds end (1+ end)) :key #'overlay-start)
        (car (sort (seq-filter (lambda (fold)
                                 (and (< (overlay-start fold) (point))
                                      (<= (point) (overlay-end fold))))
                               (vigil-ui-folds (point) (1+ (point))))
                   (lambda (a b)
                     (< (- (overlay-end a) (overlay-start a))
                        (- (overlay-end b) (overlay-start b)))))))))

(defun vigil-ui-fold-toggle ()
  "Fold or unfold what this line begins, or what point is in."
  (interactive)
  (let ((fold (or (vigil-ui-fold-here) (user-error "Nothing to fold here"))))
    (when (> (point) (overlay-start fold))
      (goto-char (overlay-start fold))
      (beginning-of-line))
    (vigil-ui-fold-set fold (not (vigil-ui-folded-p fold)))))

(defun vigil-ui-fold-toggle-all ()
  "Unfold everything, or fold it all if nothing is folded.
But for what is a whole file's: a fold of the kind `file'."
  (interactive)
  (let* ((folds (seq-remove (lambda (fold)
                              (eq (overlay-get fold 'vigil-ui-fold) 'file))
                            (vigil-ui-folds)))
         (any (cl-some #'vigil-ui-folded-p folds)))
    (dolist (fold folds) (vigil-ui-fold-set fold (not any)))
    (message (if any "Everything showing" "Everything folded"))))

(defun vigil-ui-fold-open-line ()
  "Show what the line point is on begins, if that is folded."
  (dolist (fold (vigil-ui-folds (line-end-position) (1+ (line-end-position))))
    (vigil-ui-fold-set fold nil)))

(define-obsolete-function-alias 'vigil-review-toggle #'vigil-ui-fold-toggle "0.8.0")
(define-obsolete-function-alias 'vigil-review-toggle-all #'vigil-ui-fold-toggle-all "0.8.0")

;;;; The lines above a buffer, and its windows

(defun vigil-ui-header (&rest parts)
  "PARTS, strings or nil, as a header line says them: one after another.
A string for `header-line-format', in which a `%' is only a `%'."
  (replace-regexp-in-string
   "%" "%%"
   (concat " " (string-join (delq nil parts) (propertize "   " 'face 'vigil-ui-dim)))))

(defun vigil-ui-windows-to-point (&optional place)
  "Put every window showing this buffer where its point is.
PLACE says where in the window that is to be: nil leaves it to Emacs, a
number is that line of the window, and anything else is its middle."
  (let ((point (point)))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-point window point)
      (when place
        (with-selected-window window
          (recenter (and (numberp place) place)))))))


(defun vigil-ui-tabs (views current &optional after)
  "A tab line of VIEWS, each (VIEW KEY NAME ...), with CURRENT the one showing.
AFTER is said at its end.  A string for `tab-line-format'."
  (replace-regexp-in-string
   "%" "%%"
   (concat
   (mapconcat (pcase-lambda (`(,view ,key ,name . ,_))
                (let ((face (if (eq view current) 'vigil-ui-tab-current 'vigil-ui-tab)))
                  (concat (propertize " " 'face face)
                          (propertize key 'face (list 'vigil-ui-key face))
                          (propertize (concat " " name " ") 'face face))))
              views
              (propertize " " 'face 'tab-line))
   (propertize (concat "   " (or after "")) 'face 'tab-line))))

(provide 'vigil-ui)
;;; vigil-ui.el ends here
