;;; vigil-status-detail.el --- What is at point in `M-x vigil', beside it -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil' (vigil-status.el) is lists.  What the line at point led to is
;; drawn here, in full, in a buffer of its own shown in a window beside,
;; which follows point: a prompt with its calls and reply, a reply alone, a
;; command, a file's diff, a commit.
;;
;; That buffer has nothing of its own: it is given what the session's buffer
;; knows each time it is drawn (`vigil-status--shared').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-ui)
(require 'vigil-status-session)
(require 'vigil-status-views)

;; The commands of a session's buffer that work here too (vigil-status.el).
(declare-function vigil-status-act "vigil-status")
(declare-function vigil-status-visit "vigil-status")
(declare-function vigil-status-copy "vigil-status")

;;;; What is at point

(defconst vigil-status--shared
  '(vigil-status--session vigil-status--root vigil-status--turns vigil-status--built
    vigil-status--commits vigil-status--live vigil-status--branch vigil-status--known
    vigil-status--view vigil-status--wrote)
  "What a session's buffer knows that the window beside it draws from.")

(defvar-local vigil-status--detail-of nil "The session's buffer this one is beside.")

(defvar-local vigil-status--detail-thing nil "What this buffer shows: (KIND . WHAT).")

(defun vigil-status--thing ()
  "What is at point, to show beside the list: (KIND . WHAT), or nil.
A commit, a file, a call in the list of commands, or a turn: its answer
alone in the answers view."
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (file (get-text-property (point) 'vigil-status-file))
        (call (get-text-property (point) 'vigil-status-call))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond (commit (cons 'commit commit))
          (file (cons 'file file))
          ((and call (eq vigil-status--view 'commands)) (cons 'call call))
          (turn (cons (if (eq vigil-status--view 'answers) 'answer 'turn) turn)))))

;;;; Drawing it

(defun vigil-status--detail-header (&rest parts)
  "Say PARTS, strings or nil, in this buffer's header line."
  (setq header-line-format (apply #'vigil-ui-header parts)))

(defun vigil-status--detail-turn (turn answer)
  "Insert TURN, a turn of the session, in full; its ANSWER alone if non-nil."
  (let* ((reply (plist-get turn :reply))
         (after (nth 2 (vigil-status--built-after turn)))
         (width (vigil-ui-width)))
    (vigil-status--detail-header
      (propertize (format "Prompt %d" (plist-get turn :index)) 'face 'vigil-ui-strong)
     (vigil-status--clock (plist-get turn :start))
     (vigil-status--took-cell turn)
     (and (not answer) (vigil-status--counts (plist-get turn :calls)))
     (and after (not answer)
          (concat (vigil-ui-plural (length after) "file") " "
                  (cadr (vigil-status--turn-after turn)))))
    (if answer
        (progn
          (insert (propertize (concat (vigil-ui-cut (vigil-survey-step-text
                                                     (plist-get turn :prompt))
                                                    (- width 2))
                                      "\n\n")
                              'face 'vigil-ui-dim))
          (when reply
            (vigil-ui-block (vigil-ui-markdown (vigil-survey-step-text reply)) 0
                            'vigil-ui-dim
                            'vigil-status-turn (plist-get turn :index)
                            'vigil-status-text (vigil-survey-step-text reply))))
      ;; The turn as a timeline, as wide as there is room, from its
      ;; beginning to its end.
      (let* ((cells (max 10 (- width 4)))
             (took (vigil-status--took-cell turn)))
        (insert "  " (vigil-status--timeline turn cells) "\n"
                (propertize (concat "  0"
                                    (make-string (max 1 (- cells 1 (string-width took))) ?\s)
                                    took "\n")
                            'face 'vigil-ui-dim)
                (vigil-status--timeline-legend) "\n\n"))
      (when-let* ((commands (seq-filter (lambda (call)
                                          (eq (vigil-survey-step-kind call) 'command))
                                        (plist-get turn :calls))))
        (vigil-ui-sheet `(("Its commands" . ,(vigil-status--tally commands))))
        (insert "\n"))
      (vigil-status--insert-turn turn 0)
      (when after
        (insert (propertize "Changed after it\n" 'face 'vigil-ui-dim))
        (pcase-let ((`(,_ . ,rows)
                     (vigil-ui-table (vigil-status--changes-columns)
                                     (mapcar #'vigil-status--change-cells after)
                                     width)))
          (dolist (change after)
            (insert (propertize (concat (pop rows) "\n")
                                'vigil-status-file (plist-get change :file)))))))))

(defun vigil-status--detail-call (id)
  "Insert the call ID: a command of the session, and how it went."
  (let (found)
    (dolist (turn vigil-status--turns)
      (dolist (call (plist-get turn :calls))
        (when (equal (vigil-survey-step-id call) id)
          (setq found (cons turn call)))))
    (pcase-let ((`(,turn . ,call) found))
      (when call
        (vigil-status--detail-header
          (propertize (or (vigil-survey-step-name call) "Call") 'face 'vigil-ui-strong)
         (vigil-status--clock (vigil-survey-step-time call))
         (vigil-status--duration (vigil-status--took call))
         (let ((state (vigil-status--state-said call)))
           (and (not (string-empty-p state)) state)))
        (let* ((command (vigil-survey-step-command call))
               (said (vigil-survey-step-text call)))
          ;; Why, in its agent's words, where it said: not the command again.
          (when (or (null command)
                    (not (equal said (vigil-survey--line command 120))))
            (vigil-ui-block (or said "") 0 'vigil-ui-kind-command
                            'vigil-status-call id)
            (insert "\n"))
          (when command
            (vigil-status--insert-command command id)
            (vigil-status--insert-purpose call)))
        (vigil-ui-sheet
         `(("Prompt" . ,(format "%d  %s" (plist-get turn :index)
                                (vigil-ui-cut (vigil-survey-step-text (plist-get turn :prompt))
                                              (- (vigil-ui-width) 14))))
           ("Began" . ,(format "%s, %s into the turn"
                               (vigil-status--clock (vigil-survey-step-time call) t)
                               (vigil-status--duration
                                (max 0 (- (vigil-survey-step-time call)
                                          (plist-get turn :start))))))
           ("Took" . ,(let ((took (vigil-status--duration (vigil-status--took call))))
                        (if (string-empty-p took) "not known: it reported no end" took)))
           ))
        (insert "\n" (propertize "RET opens the call, with what it printed, where its agent is open.\n"
                                 'face 'vigil-ui-dim))))))

(defun vigil-status--detail-file (file)
  "Insert FILE: what is changing in it now, as a diff."
  (let* ((live vigil-status--live)
         (change (cl-find file (plist-get live :changes)
                          :key (lambda (change) (plist-get change :file)) :test #'equal))
         (time (vigil-status--file-time file))
         (lines (and live (gethash file (plist-get live :diffs)))))
    (vigil-status--detail-header
      (propertize file 'face 'vigil-ui-strong)
     (and change (vigil-ui-lines-changed (plist-get change :added)
                                         (plist-get change :removed)))
     (and time (vigil-status--ago time))
     (and live (vigil-status--live-since)))
    (cond
     (lines (vigil-status--insert-diff file lines))
     (change
      ;; One whose diff was not kept: asked of git now.
      (vigil-status--insert-diff
       file (split-string
             (or (vigil-git vigil-status--root "diff" "--no-renames"
                            (plist-get (plist-get live :base) :commit)
                            (plist-get (plist-get live :to) :commit) "--" file)
                 "")
             "\n")))
     (t (insert (propertize "It does not differ now from when changes are counted from.\n"
                            'face 'vigil-ui-dim))))))

(defun vigil-status--detail-commit (hash)
  "Insert the commit HASH: what it says, and which files it changed."
  (let* ((commit (cl-find hash vigil-status--commits
                          :key (lambda (commit) (plist-get commit :hash)) :test #'equal))
         (text (vigil-git vigil-status--root "show" "--stat" "--format=%B" hash))
         (parts (split-string (or text "") "\n\n+ " t)))
    (vigil-status--detail-header
      (propertize (concat "Commit " (substring hash 0 7)) 'face 'vigil-ui-strong)
     (and commit (vigil-status--clock (plist-get commit :time)))
     (and commit (vigil-status--refs-said (plist-get commit :refs))))
    (when (plist-get commit :versions)
      (vigil-ui-sheet `(("Changelog" . ,(propertize
                                         (string-join (plist-get commit :versions) " ")
                                         'face 'vigil-ui-good))))
      (insert "\n"))
    (vigil-ui-block (string-trim (car parts)) 0 'vigil-ui-dim
                    'vigil-status-commit hash)
    (when (cdr parts)
      (insert "\n" (propertize "Changed\n" 'face 'vigil-ui-dim))
      (dolist (line (split-string (string-join (cdr parts) "\n") "\n" t))
        (insert "  " (string-trim-left line) "\n")))))

(defun vigil-status--detail-render ()
  "Draw this buffer, the one beside a session's, again."
  (let ((inhibit-read-only t)
        (thing vigil-status--detail-thing))
    (remove-overlays)
    (erase-buffer)
    (vigil-ui-begin)
    (setq header-line-format nil)
    (pcase thing
      (`(,(or 'turn 'answer) . ,index)
       (when-let* ((turn (cl-find index vigil-status--turns
                                  :key (lambda (turn) (plist-get turn :index)))))
         (vigil-status--detail-turn turn (eq (car thing) 'answer))))
      (`(commit . ,hash) (vigil-status--detail-commit hash))
      (`(file . ,file) (vigil-status--detail-file file))
      (`(call . ,id) (vigil-status--detail-call id))
      (_ (insert (propertize "What is at point in the list is shown here.\n"
                             'face 'vigil-ui-dim))))
    (goto-char (point-min))
    ;; From its beginning, in every window it shows in: a window keeps its
    ;; own place, which was in what was here before.
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-start window (point-min)))
    (vigil-ui-windows-to-point)))

;;;; Its buffer and its window

(defun vigil-status--detail-name ()
  "What the buffer beside this session's is called."
  (format "*vigil detail: %s*" vigil-status--session))

(defun vigil-status--detail-buffer ()
  "The buffer that shows what is at point in this session's buffer."
  (let ((status (current-buffer))
        (buffer (get-buffer-create (vigil-status--detail-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vigil-status-detail-mode)
        (vigil-status-detail-mode))
      (setq vigil-status--detail-of status))
    buffer))

(defun vigil-status--detail-draw (thing)
  "Draw THING, what is at point in this session's buffer, in the buffer beside.
Gives that buffer."
  (let ((values (mapcar #'symbol-value vigil-status--shared))
        (buffer (vigil-status--detail-buffer)))
    (with-current-buffer buffer
      (cl-mapc #'set vigil-status--shared values)
      (setq vigil-status--detail-thing thing
            default-directory (or vigil-status--root default-directory))
      (vigil-status--detail-render))
    buffer))

(defun vigil-status--detail-window (buffer)
  "Show BUFFER beside this session's buffer, if that is on screen: its window.
To the right where there is room for two side by side, and else below."
  (or (get-buffer-window buffer)
      (when-let* ((window (get-buffer-window (current-buffer))))
        (ignore-errors
          (display-buffer
           buffer
           `((display-buffer-in-direction)
             (window . ,window)
             (direction . ,(if (>= (window-total-width window) 150) 'right 'below))
             (window-width . 0.55)
             (window-height . 0.6)))))))

(defun vigil-status--detail-sync (&optional again)
  "Show what is at point beside this buffer, if it is not what is shown.
With AGAIN, even if it is: what there is to say of it has changed."
  (when (and vigil-status--detail (derived-mode-p 'vigil-status-mode))
    (when-let* ((thing (vigil-status--thing))
                ((or again (not (equal thing vigil-status--detail-shown)))))
      (setq vigil-status--detail-shown thing)
      (vigil-status--detail-window (vigil-status--detail-draw thing)))))

(defun vigil-status--detail-select ()
  "Go to the window beside, where what is at point is shown."
  (vigil-status--detail-sync)
  (when-let* ((buffer (get-buffer (vigil-status--detail-name)))
              (window (or (get-buffer-window buffer)
                          (vigil-status--detail-window buffer))))
    (select-window window)))

(defun vigil-status--detail-goto-diff (line)
  "In the window beside, go to LINE of the diff shown, counting from 0."
  (when-let* ((line line)
              (buffer (get-buffer (vigil-status--detail-name))))
    (with-current-buffer buffer
      (when-let* ((target (text-property-any (point-min) (point-max)
                                             'vigil-status-diff line)))
        (goto-char target)
        (vigil-ui-windows-to-point t)))))

(defun vigil-status--detail-close ()
  "Close the window beside this session's buffer, and its buffer."
  (when-let* ((buffer (get-buffer (vigil-status--detail-name))))
    (dolist (window (get-buffer-window-list buffer nil t))
      (ignore-errors (delete-window window)))
    (kill-buffer buffer))
  (setq vigil-status--detail-shown nil))

;;;; Its keys

(defvar vigil-status-detail-mode-map (make-sparse-keymap)
  "Keys of the buffer beside a session's.")

(define-key vigil-status-detail-mode-map (kbd "RET") #'vigil-status-act)
(define-key vigil-status-detail-mode-map (kbd "o") #'vigil-status-visit)
(define-key vigil-status-detail-mode-map (kbd "w") #'vigil-status-copy)
(define-key vigil-status-detail-mode-map (kbd "n") #'next-line)
(define-key vigil-status-detail-mode-map (kbd "p") #'previous-line)

(define-derived-mode vigil-status-detail-mode special-mode "Vigil detail"
  "What is at point in a session's buffer, in full, beside it.
\\<vigil-status-detail-mode-map>It follows point there.  \\[vigil-status-act] opens what is at point here: a call, or a
line of a diff in its file.  \\[vigil-status-copy] copies the prompt or reply at point.
\\[quit-window] leaves it."
  (vigil-ui-fit #'vigil-status--detail-render))

(provide 'vigil-status-detail)
;;; vigil-status-detail.el ends here
