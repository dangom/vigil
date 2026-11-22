;;; vigil-edits.el --- Which call wrote each line of a file -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; The agent's edits, in the buffers of the files it edited, and all at once.
;;
;; - A file the agent edited has a bar in the fringe beside each line one of
;;   its calls wrote and nothing has changed since: bright for the turn going
;;   on now (`vigil-edit-latest'), dim for earlier ones (`vigil-edit').
;;   Clicking a bar inspects the call, in the frame calls are inspected in;
;;   `vigil-blame' does the same for the line at point, and with C-u goes to
;;   the call's line in the conversation instead.  Beside diff-hl,
;;   whose bars mark what is not committed, these mark which of that was the
;;   agent's: they are drawn over its bars, on the same side.
;;
;; - `vigil-turn-diff' (`d' in a turn's list or on a call being inspected)
;;   shows what one turn changed, file by file, as one diff: from each file
;;   as it was before the turn's first edit of it to as its last edit left
;;   it.  In `diff-mode', so C-u C-c C-a undoes one of its hunks in the file.
;;   With C-u, everything the conversation changed.
;;
;; Who wrote a line is worked out from the reports alone.  Each edit's
;; report has the file as it was before the edit and the patch it made;
;; the lines are followed from edit to edit, through each patch.  Whatever
;; changed a file between two edits -- you, a formatter, a `git checkout', a
;; command the agent ran, such as `sed -i' -- is told by comparing the file as
;; one edit left it with the file the next one found, and is no call's; so
;; is whatever the buffer shows that differs from the file as the last edit
;; left it, saved or not.  A line the agent wrote and you then rewrote is
;; yours.  Only `diff' is run, on texts already in Emacs; nothing in a file
;; is ever evaluated.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'vigil)
(require 'vigil-turn)


(defgroup vigil-edits nil
  "Which of an agent's calls wrote each line of a file."
  :group 'vigil)

(defcustom vigil-mark-edits t
  "Whether to mark the lines an agent's calls wrote in the files' buffers."
  :type 'boolean)

(defcustom vigil-edits-fringe 'left-fringe
  "The fringe the lines an agent wrote are marked in."
  :type '(choice (const left-fringe) (const right-fringe)))

(defface vigil-edit-latest
  '((t :inherit warning))
  "The mark of a line the agent wrote in the turn going on now.")

(defface vigil-edit
  '((t :inherit shadow))
  "The mark of a line the agent wrote in an earlier turn.")

(when (fboundp 'define-fringe-bitmap)
  ;; A bar down the line's full height, narrower than diff-hl's.
  (define-fringe-bitmap 'vigil-edit-bar [#b11100000] nil nil '(top t)))

;;;; Who wrote each line

(defun vigil-edits--name (file)
  "The name the agents' edits of FILE are kept by, or nil if none edited it."
  (let ((true (file-truename file)))
    (and (cl-some (lambda (agent)
                    (when-let* ((edits (vigil-edits-of agent)))
                      (gethash true edits)))
                  (vigil--agent-buffers))
         true)))

(defun vigil-edits--of-file (name)
  "Every agent's edits of the file NAME, in the order they were made.
Each as (EDIT . AGENT)."
  (let (all)
    (dolist (agent (vigil--agent-buffers))
      (when-let* ((edits (vigil-edits-of agent)))
        (dolist (edit (gethash name edits))
          (push (cons edit agent) all))))
    (sort (nreverse all)
          (lambda (a b)
            (< (or (vigil-call-end (vigil-edit-call (car a))) 0)
               (or (vigil-call-end (vigil-edit-call (car b))) 0))))))

(defun vigil-edits--carry (old owners new owner)
  "The owners of the lines NEW, carried over from the lines OLD and their OWNERS.
A line NEW has that OLD has not is OWNER's."
  (if (equal old new)
      owners
    (cdr (vigil--apply-hunks old owners (vigil--line-hunks old new) owner))))

(defun vigil-edits--step (lines owners edit)
  "LINES and OWNERS, the file before EDIT as known so far, after EDIT.
\(NEW-LINES . NEW-OWNERS).  The lines the edit wrote are owned by its call."
  (let ((call (vigil-edit-call edit))
        (before (vigil-edit-before edit))
        (after (vigil-edit-after edit)))
    ;; Whatever changed the file since, as the edit found it: no call's.
    (when before
      (let ((found (vigil--text-lines before)))
        (setq owners (vigil-edits--carry lines owners found nil)
              lines found)))
    (if (null after)
        (cons lines owners)
      (let ((made (vigil--text-lines after))
            ;; The patch reported says best which lines the edit wrote.
            (patched (vigil--apply-hunks lines owners
                                         (vigil--patch-hunks (vigil-call-response call))
                                         call)))
        (if (and patched (equal (car patched) made))
            patched
          (cons made (vigil-edits--carry lines owners made call)))))))

(defvar vigil-edits--folds (make-hash-table :test #'equal)
  "For each file: its edits, and the lines and owners the last left it with.
\(EDITS LINES . OWNERS), so the edits are followed again only when there are
new ones.")

(defun vigil-edits--fold (name)
  "The lines of the file NAME as the agents' last edit of it left them, and
who wrote each: (LINES . OWNERS), with (CALL . AGENT) or nil for each line."
  (let* ((edits (vigil-edits--of-file name))
         (cached (gethash name vigil-edits--folds)))
    (if (and cached (= (length (car cached)) (length edits))
             (cl-every (lambda (a b) (eq (car a) (car b))) (car cached) edits))
        (cdr cached)
      (let ((lines nil) (owners nil))
        (dolist (pair edits)
          (let ((step (vigil-edits--step lines owners (car pair))))
            (setq lines (car step)
                  owners (cdr step))))
        ;; Followed as calls; given with their agents, as (CALL . AGENT).
        (let* ((agents (mapcar (lambda (pair) (cons (vigil-edit-call (car pair)) (cdr pair)))
                               edits))
               (result (cons lines (mapcar (lambda (call) (and call (assq call agents)))
                                           owners))))
          (puthash name (cons edits result) vigil-edits--folds)
          result)))))

(defun vigil-edits-owners (&optional buffer)
  "Who wrote each line of BUFFER, default the current one, as it is now.
A list with one element per line: (CALL . AGENT) for a line one of the
agents' calls wrote, nil for the rest.  Nil if no agent edited its file."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* ((file buffer-file-name)
                (name (vigil-edits--name file)))
      (pcase-let ((`(,lines . ,owners) (vigil-edits--fold name)))
        (vigil-edits--carry lines owners
                            (vigil--text-lines
                             (save-restriction
                               (widen)
                               (buffer-substring-no-properties (point-min) (point-max))))
                            nil)))))

;;;; Marks in a file's buffer

(defvar vigil-edits-mode)                ; defined with the mode, below

(defvar-local vigil-edits--overlays nil "This buffer's marks.")

(defun vigil-edits--latest-p (owner)
  "Whether OWNER, (CALL . AGENT), wrote in the turn going on now."
  (let* ((agent (cdr owner))
         (prompts (buffer-local-value 'vigil--prompts agent)))
    (= (vigil--turn (or (vigil-call-start (car owner)) 0) prompts)
       (length (vigil--user-prompts prompts)))))

(defun vigil-edits--help (_window object position)
  "What the line at POSITION in OBJECT says when pointed at: who wrote it.
A `help-echo' function, so it is worked out only when it is asked for."
  (when-let* ((owner (and (bufferp object)
                          (with-current-buffer object (vigil-edits--owner-at position))))
              (agent (cdr owner)))
    (format "Written by %s in %s: %s\nmouse-1 in the fringe, or M-x vigil-blame: the call"
            (vigil-call-name (car owner))
            (if (buffer-live-p agent) (buffer-name agent) "an agent gone")
            (string-join (vigil--whereabouts (list (car owner)) agent) "  "))))

(defun vigil-edits--clear ()
  "Take this buffer's marks away."
  (mapc #'delete-overlay vigil-edits--overlays)
  (setq vigil-edits--overlays nil))

(defun vigil-edits--draw ()
  "Mark the lines of this buffer the agents' calls wrote."
  (vigil-edits--clear)
  (let ((owners (vigil-edits-owners)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (owner owners)
          (when owner
            (let* ((face (if (vigil-edits--latest-p owner) 'vigil-edit-latest 'vigil-edit))
                   (overlay (make-overlay (line-beginning-position) (line-end-position)
                                          nil t nil)))
              (overlay-put overlay 'vigil-edit owner)
              (overlay-put overlay 'help-echo #'vigil-edits--help)
              (overlay-put overlay 'priority 100)
              (overlay-put overlay 'before-string
                           (propertize "!" 'display
                                       (list vigil-edits-fringe 'vigil-edit-bar face)))
              (push overlay vigil-edits--overlays)))
          (forward-line 1))))))

(defun vigil-edits--refresh ()
  "Mark this buffer's lines afresh: it was saved, or reverted to its file."
  (when vigil-edits-mode
    (vigil-edits--draw)))

(defun vigil-edits--owner-at (&optional position)
  "Who wrote the line at POSITION, default point: (CALL . AGENT), or nil."
  (save-excursion
    (goto-char (or position (point)))
    (cl-some (lambda (overlay) (overlay-get overlay 'vigil-edit))
             (overlays-in (line-beginning-position) (1+ (line-beginning-position))))))

(defun vigil-edits-click (event)
  "Inspect the call that wrote the line clicked in the fringe, as EVENT says.
A click beside a line no call wrote does what it would have done."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (position (posn-point start))
         (owner (and (window-live-p window) position
                     (with-current-buffer (window-buffer window)
                       (vigil-edits--owner-at position)))))
    (if owner
        (progn
          (select-window window)
          (vigil-inspect (car owner) (cdr owner)))
      (let ((other (let ((vigil-edits-mode nil))
                     (key-binding (vector (posn-area start) (car event)) nil nil start))))
        (when (and other (commandp other) (not (eq other #'vigil-edits-click)))
          (call-interactively other nil (vector event)))))))

(defvar vigil-edits-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-fringe mouse-1] #'vigil-edits-click)
    (define-key map [right-fringe mouse-1] #'vigil-edits-click)
    map)
  "Keys of a buffer whose lines an agent wrote: only a click on a mark.")

(define-minor-mode vigil-edits-mode
  "Mark the lines of this file that an agent's calls wrote.
Turned on by itself in the buffer of every file an agent edited; see
vigil-edits.el."
  :lighter nil
  :keymap vigil-edits-mode-map
  (if vigil-edits-mode
      (progn
        (add-hook 'after-save-hook #'vigil-edits--refresh nil t)
        (add-hook 'after-revert-hook #'vigil-edits--refresh nil t)
        (vigil-edits--draw))
    (remove-hook 'after-save-hook #'vigil-edits--refresh t)
    (remove-hook 'after-revert-hook #'vigil-edits--refresh t)
    (vigil-edits--clear)))

(defun vigil-edits--maybe-enable ()
  "Mark the lines an agent wrote, if one edited this buffer's file.
On `find-file-hook'."
  (when (and vigil-mark-edits buffer-file-name (not vigil-edits-mode)
             (vigil-edits--name buffer-file-name))
    (vigil-edits-mode 1)))

(defvar vigil-edits--made -1
  "`vigil-edits-made' when the files' buffers were last marked.")

(defun vigil-edits--update ()
  "Mark the lines of every file's buffer afresh, if any agent's edits changed.
On `vigil-changed-hook', which most reports that are not edits run too."
  (when (and vigil-mark-edits (/= vigil-edits--made vigil-edits-made))
    (setq vigil-edits--made vigil-edits-made)
    (let ((edited (make-hash-table :test #'equal)))
      (dolist (agent (vigil--agent-buffers))
        (when-let* ((edits (vigil-edits-of agent)))
          (maphash (lambda (name _) (puthash name t edited)) edits)))
      ;; Forget what was followed of files no agent's edits are kept of now.
      (maphash (lambda (name _)
                 (unless (gethash name edited) (remhash name vigil-edits--folds)))
               vigil-edits--folds)
      (dolist (buffer (buffer-list))
        (when-let* ((file (buffer-local-value 'buffer-file-name buffer)))
          (with-current-buffer buffer
            (cond ((gethash (file-truename file) edited)
                   (if vigil-edits-mode (vigil-edits--draw) (vigil-edits-mode 1)))
                  (vigil-edits-mode (vigil-edits-mode -1)))))))))

;;;###autoload
(defun vigil-blame (&optional conversation)
  "Inspect the call that wrote the line at point.
With CONVERSATION (\\[universal-argument]), go to its line in the agent's conversation."
  (interactive "P")
  (let ((owner (or (vigil-edits--owner-at)
                   (and (not vigil-edits-mode)
                        (let ((owners (vigil-edits-owners)))
                          (nth (1- (line-number-at-pos nil t)) owners)))
                   (user-error "No agent's call wrote this line, as far as vigil knows"))))
    (if conversation
        (vigil-goto-call (car owner) (cdr owner))
      (vigil-inspect (car owner) (cdr owner)))))

;;;; A turn's changes, as one diff

(defun vigil-edits--file-diff (file edits directory)
  "The diff of FILE from before the first of EDITS to after the last.
Names relative to DIRECTORY.  Nil if they left it as they found it; a line
saying why, where there is none to show."
  (let ((before (vigil-edit-before (car edits)))
        (after (cl-some #'vigil-edit-after (reverse edits)))
        (name (vigil--relative file (file-truename directory))))
    (cond
     ((or (null before) (null after))
      (format "# %s: not shown; its edits' reports were cut short.\n" name))
     ((equal before after) nil)
     (t
      (let ((relative (not (file-name-absolute-p name))))
        (or (vigil--diff-output before after "-u"
                                "--label" (if relative (concat "a/" name) name)
                                "--label" (if relative (concat "b/" name) name))
            (format "# %s: not shown; `%s' could not compare it.\n"
                    name vigil-diff-program)))))))

(defun vigil-edits--diff (agent calls)
  "The diff of what AGENT's CALLS changed, file by file, as text."
  (let ((directory (or (cl-some #'vigil-call-cwd (reverse calls))
                       (buffer-local-value 'default-directory agent)))
        (diffs nil))
    (maphash (lambda (file edits)
               (when-let* ((mine (cl-remove-if-not
                                  (lambda (edit) (memq (vigil-edit-call edit) calls))
                                  edits))
                           (diff (vigil-edits--file-diff file mine directory)))
                 (push (cons (vigil-call-start (vigil-edit-call (car mine))) diff) diffs)))
             (or (vigil-edits-of agent) (make-hash-table)))
    (cons directory
          (mapconcat #'cdr (sort diffs (lambda (a b) (< (or (car a) 0) (or (car b) 0))))
                     ""))))

(defun vigil-edits--diff-target (all)
  "The agent and its turn that `vigil-turn-diff' shows: (AGENT . TURN).
TURN is nil for ALL of them."
  (if (derived-mode-p 'vigil-turn-mode)
      (cons vigil-turn--agent (and (not all) vigil-turn--turn))
    (pcase-let ((`(,call . ,agent) (vigil-turn--start)))
      (unless (buffer-live-p agent)
        (user-error "Not an agent's buffer"))
      (cons agent
            (and (not all)
                 (if (vigil-call-p call)
                     (vigil-turn--of call agent)
                   (length (vigil-turn--prompts agent))))))))

;;;###autoload
(defun vigil-turn-diff (&optional all)
  "Show what one turn of the agent's conversation changed, as one diff.
The turn of the call nearest point, or being inspected, or listed; with ALL
\(\\[universal-argument]), the whole conversation.  Each file from before the first edit of
it to after the last: what was changed back is not there.  See vigil-edits.el."
  (interactive "P")
  (pcase-let ((`(,agent . ,turn) (vigil-edits--diff-target all)))
    (vigil-edits--show-diff agent turn)))

(defun vigil-edits--show-diff (agent turn)
  "Show what TURN of AGENT's conversation changed, as one diff; nil, all of it.
What `vigil-turn-diff' does, once it knows of which.  Returns the buffer."
  (pcase-let* ((calls (if turn
                          (vigil-turn--calls agent turn)
                        (buffer-local-value 'vigil--order agent)))
               (`(,directory . ,diff) (vigil-edits--diff agent calls))
               (prompt (and turn (vigil-turn--prompt agent turn)))
               (buffer (get-buffer-create
                        (format "*vigil diff: %s%s*" (buffer-name agent)
                                (if turn (format " turn %d" turn) "")))))
    (when (string-empty-p diff)
      (user-error "%s changed no file" (if turn (format "Turn %d" turn) "The conversation")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory (file-name-as-directory directory))
        (insert (format "# %s, %s\n" (buffer-name agent)
                        (if turn
                            (format "turn %d of %d" turn
                                    (length (vigil-turn--prompts agent)))
                          "the whole conversation")))
        (when prompt
          (insert "# > " (car (split-string (vigil--prompt-text prompt) "\n")) "\n"))
        (insert "# Each file from before its first edit to after its last.  "
                "C-u C-c C-a undoes a hunk.\n\n"
                diff)
        (diff-mode)
        (goto-char (point-min))
        (diff-hunk-next)))
    (when (vigil--popup-up-p)
      (vigil-popup-quit))
    (pop-to-buffer buffer)))

(define-key vigil-turn-mode-map (kbd "d") #'vigil-turn-diff)
(define-key vigil-popup-mode-map (kbd "d") #'vigil-turn-diff)
(define-key vigil-context-mode-map (kbd "d") #'vigil-turn-diff)

(add-hook 'vigil-changed-hook #'vigil-edits--update)
(add-hook 'find-file-hook #'vigil-edits--maybe-enable)

(provide 'vigil-edits)
;;; vigil-edits.el ends here
