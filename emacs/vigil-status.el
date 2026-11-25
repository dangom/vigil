;;; vigil-status.el --- One place to begin from: a session, and its views -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil': one buffer for a session, and one key to each way of
;; looking at it, as `magit-status' is for a repository.
;;
;; The buffer has five views of the session, and a key for each:
;;
;;   s  Status     what it is, how much it has done, what it built, its
;;                 last prompts and the commits made since it began
;;   P  Prompts    each prompt in order, and under it what it led to: its
;;                 calls, one a line, and the reply
;;   a  Answers    the replies alone, to read and to copy
;;   c  Commands   every command it ran, when, and for how long
;;   b  Build      its prompts and the repository's commits in the order
;;                 they happened, each commit with what it added to the
;;                 changelog
;;
;; `?' shows these and the rest of vigil in a menu: the session's review,
;; context, turns, graph and focus, and what is not of one session, the
;; running commands, the repository's changes and the archive.
;;
;; It reads a session's reports by its name (vigil-survey.el), so it needs
;; no agent's buffer: a session that is not open in this Emacs is shown as
;; well.  What acts on the conversation itself (context, a turn's list,
;; focus, a call inspected) needs that buffer, and says so.
;;
;; Needs vigil-survey.el and vigil-review.el and what they need; vigil.el
;; and cooked only for what acts on an agent's buffer.
;;
;; Where things are: what is read of a session, and every option, in
;; vigil-status-session.el; how it is drawn, in vigil-status-views.el; the
;; window beside, in vigil-status-detail.el.  Here are the buffer itself, its
;; commands, its keys and the menu.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'filenotify)
(require 'vigil-ui)
(require 'vigil-status-session)
(require 'vigil-status-views)
(require 'vigil-status-detail)

(declare-function vigil-context "vigil")
(declare-function vigil-prompts "vigil")
(declare-function vigil-turn "vigil-turn")
(declare-function vigil-focus-mode "vigil-transcript")
(declare-function vigil-graph "vigil-graph")
(declare-function vigil-running "vigil-running")
(declare-function vigil-archive "vigil-archive")
(declare-function vigil-embark-inspect "vigil-embark")
(declare-function vigil-embark-goto "vigil-embark")
(declare-function vigil-codebase--show-commit "vigil-codebase")

;;;; Drawing the buffer

(defun vigil-status--render ()
  "Draw this buffer again, in the view it is in, from what was last read."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (column (current-column)))
    (vigil-status--note-folds)
    (remove-overlays)
    (erase-buffer)
    (vigil-ui-begin)
    (vigil-status--set-lines)
    (funcall (nth 3 (or (assq vigil-status--view vigil-status-views)
                        (car vigil-status-views))))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    ;; What is beside is of what was there before.
    (setq vigil-status--detail-shown nil)))

(defun vigil-status--file-line (file)
  "Where FILE's own line is in this buffer: the one its diff is under or beside."
  (let ((position (point-min)) found)
    (while (and position (not found))
      (if (and (get-text-property position 'vigil-status-heading)
               (equal (get-text-property position 'vigil-status-file) file))
          (setq found position)
        (setq position (next-single-property-change position 'vigil-status-heading))))
    found))

(defun vigil-status--goto-file (file)
  "Go to FILE's own line in the changes view, and show its diff."
  (when-let* ((line (vigil-status--file-line file)))
    (goto-char line)
    (vigil-ui-fold-open-line)
    (vigil-ui-windows-to-point 1)))

(defun vigil-status--follow-latest ()
  "Go to where the file last written last changed, and show it."
  (when-let* ((live vigil-status--live)
              (file (plist-get live :latest))
              (line (vigil-status--file-line file)))
    (goto-char line)
    (if vigil-status--detail
        ;; Its diff is beside: there, the line that is new.
        (progn
          (vigil-ui-windows-to-point)
          (vigil-status--detail-sync t)
          (vigil-status--detail-goto-diff (plist-get live :moved)))
      (vigil-ui-fold-open-line)
      (when-let* ((moved (plist-get live :moved))
                  (target (text-property-any line (point-max) 'vigil-status-diff moved))
                  ((equal (get-text-property target 'vigil-status-file) file)))
        (goto-char target))
      (vigil-ui-windows-to-point t))))

;;;; Reading again as the agent works

(defun vigil-status--start-watching ()
  "Read this session again whenever its agent reports something."
  (vigil-status--stop-watching)
  (when-let* ((directory (vigil-survey--directory vigil-status--session))
              ((file-directory-p directory))
              (buffer (current-buffer)))
    (setq vigil-status--watch
          (ignore-errors
            (file-notify-add-watch
             directory '(change)
             (lambda (_event)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer (vigil-status--soon)))))))))

(defun vigil-status--stop-watching ()
  "Stop reading this session again as its agent reports."
  (when vigil-status--watch
    (ignore-errors (file-notify-rm-watch vigil-status--watch))
    (setq vigil-status--watch nil))
  (when (timerp vigil-status--timer)
    (cancel-timer vigil-status--timer)
    (setq vigil-status--timer nil)))

(defun vigil-status--soon ()
  "Read this session again in a moment, once: reports come several at a time."
  (unless (timerp vigil-status--timer)
    (let ((buffer (current-buffer)))
      (setq vigil-status--timer
            (run-with-timer
             vigil-status-refresh-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq vigil-status--timer nil)
                   ;; Only what is looked at is worth reading again.
                   (if (get-buffer-window buffer t)
                       (ignore-errors (vigil-status--auto))
                     (setq vigil-status--stale t))))))))))

(defun vigil-status--auto ()
  "Read the session again and draw it, leaving the reader where they are.
In the changes view, while following, going to what last changed."
  (setq vigil-status--stale nil)
  (vigil-status--read)
  (let ((starts (mapcar (lambda (window)
                          (cons window (line-number-at-pos (window-start window))))
                        (get-buffer-window-list (current-buffer) nil t))))
    (vigil-status--render)
    (if (and (eq vigil-status--view 'changes) vigil-status--follow)
        (vigil-status--follow-latest)
      (pcase-dolist (`(,window . ,line) starts)
        (set-window-start window (save-excursion (goto-char (point-min))
                                                 (forward-line (1- line))
                                                 (point))
                          t)
        (set-window-point window (point)))
      (vigil-status--detail-sync t))))

(defun vigil-status-refresh ()
  "Read the session again, and draw this buffer."
  (interactive)
  (vigil-status--read)
  (vigil-status--render))

;;;; The views

(defun vigil-status--session-at-hand ()
  "The session this buffer is of, or is the agent of; or nil."
  (or vigil-status--session
      (and (boundp 'cooked-host-name) (stringp cooked-host-name) cooked-host-name)))

(defun vigil-status--session-here ()
  "The session this buffer is of, or is the agent of; or an error."
  (or (vigil-status--session-at-hand)
      (user-error "No session here: M-x vigil chooses one")))

(defun vigil-status--show (view &optional turn)
  "Show VIEW of this session; at the turn of index TURN, where one is named.
With the detail and no turn named, at the first line of the view there is
something to see of: the last prompt, command or commit, the file last
written."
  (unless (derived-mode-p 'vigil-status-mode)
    (vigil (vigil-status--session-here)))
  (setq vigil-status--view view)
  (when vigil-status--stale
    (setq vigil-status--stale nil)
    (vigil-status--read))
  (vigil-status--render)
  (goto-char (point-min))
  (cond
   ((when-let* ((found (and turn (text-property-any (point-min) (point-max)
                                                    'vigil-status-turn turn))))
      (goto-char found)
      (vigil-ui-fold-open-line)
      t))
   ((and vigil-status--detail (not (eq view 'status)))
    (while (and (not (eobp)) (not (vigil-status--thing)))
      (forward-line 1))
    (unless (vigil-status--thing) (goto-char (point-min)))))
  (vigil-ui-windows-to-point)
  (vigil-status--detail-sync))

(defun vigil-status-show-status ()
  "Show the session in short."
  (interactive)
  (vigil-status--show 'status))

(defun vigil-status-show-prompts ()
  "Show each prompt of the session, and under it what it led to."
  (interactive)
  (vigil-status--show 'prompts (get-text-property (point) 'vigil-status-turn)))

(defun vigil-status-show-answers ()
  "Show the session's replies alone."
  (interactive)
  (vigil-status--show 'answers (get-text-property (point) 'vigil-status-turn)))

(defun vigil-status-show-commands ()
  "Show every command the session ran, when, and for how long."
  (interactive)
  (vigil-status--show 'commands))

(defun vigil-status-show-changes ()
  "Show the files changing now, and what is changing in each."
  (interactive)
  (vigil-status--show 'changes)
  (when vigil-status--follow (vigil-status--follow-latest)))

(defun vigil-status-show-build ()
  "Show the session's prompts and the repository's commits, in order."
  (interactive)
  (vigil-status--show 'build (get-text-property (point) 'vigil-status-turn)))

;;;; How a view is looked at

(defun vigil-status-toggle-detail ()
  "Show what is at point in a window beside the list; or under its line."
  (interactive)
  (setq vigil-status--detail (not vigil-status--detail))
  (unless vigil-status--detail (vigil-status--detail-close))
  (vigil-status--show vigil-status--view (get-text-property (point) 'vigil-status-turn))
  (message (if vigil-status--detail
               "What is at point is shown beside the list"
             "What a line led to is under it, folded")))

(defun vigil-status-toggle-follow ()
  "Follow the last change as it is made, in the changes view; or stop."
  (interactive)
  (setq vigil-status--follow (not vigil-status--follow))
  (vigil-status-show-changes)
  (message (if vigil-status--follow
               "Following the last change"
             "Not following: the buffer stays where you leave it")))

(defun vigil-status-toggle-since ()
  "Count what is changing from the last prompt, or from the session's beginning."
  (interactive)
  (setq vigil-status--since (if (eq vigil-status--since 'session) 'prompt 'session))
  (vigil-status--read)
  (vigil-status-show-changes))

(defun vigil-status-toggle-looks ()
  "List the commands that only looked among the others, or leave them out."
  (interactive)
  (setq vigil-status--looks (not vigil-status--looks))
  (vigil-status--show 'commands))

(defun vigil-status-by-duration ()
  "List the commands longest first, or as they ran."
  (interactive)
  (setq vigil-status--by-duration (not vigil-status--by-duration))
  (vigil-status--show 'commands))

;;;; What is at point

(defun vigil-status--visit (file &optional line)
  "Visit FILE of this session's repository, at LINE if one is named."
  (let ((name (expand-file-name file vigil-status--root)))
    (unless (file-exists-p name) (user-error "%s is not there now" file))
    (find-file-other-window name)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun vigil-status--call (action)
  "Do ACTION, a command of vigil-embark.el's, to the call at point."
  (let ((id (or (get-text-property (point) 'vigil-status-call)
                (user-error "No call here"))))
    (vigil-status--agent-or-error)
    (unless (and (require 'vigil nil t) (require 'vigil-embark nil t))
      (user-error "A call is shown by vigil.el, which could not be loaded"))
    (funcall action (concat vigil-status--session "/" id))))

(defun vigil-status-act ()
  "Open what is at point: a call, a commit, or a prompt and what it led to."
  (interactive)
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond
     ((get-text-property (point) 'vigil-status-call)
      (vigil-status--call #'vigil-embark-inspect))
     (commit (vigil-codebase--show-commit vigil-status--root commit))
     ;; A line of a diff is its file at that line; a file's own line is its
     ;; diff, here or in the view that has it.
     ((get-text-property (point) 'vigil-status-line)
      (vigil-status--visit (get-text-property (point) 'vigil-status-file)
                           (get-text-property (point) 'vigil-status-line)))
     ((and (get-text-property (point) 'vigil-status-file) (vigil-ui-fold-here))
      (vigil-ui-fold-toggle))
     ((and (get-text-property (point) 'vigil-status-file) vigil-status--detail
           (derived-mode-p 'vigil-status-mode))
      (vigil-status--detail-select))
     ((get-text-property (point) 'vigil-status-file)
      (let ((file (get-text-property (point) 'vigil-status-file)))
        (if (eq vigil-status--view 'changes)
            (vigil-status--goto-file file)
          (setf (alist-get (list 'changes file) vigil-status--folds nil nil #'equal) nil)
          (vigil-status--show 'changes)
          (vigil-status--goto-file file))))
     ((and turn (vigil-ui-fold-here)) (vigil-ui-fold-toggle))
     ;; What is beside is what there is to open: go there.
     ((and turn vigil-status--detail (derived-mode-p 'vigil-status-mode)
           (memq vigil-status--view '(prompts answers build)))
      (vigil-status--detail-select))
     (turn (vigil-status--show 'prompts turn))
     (t (user-error "Nothing to open here")))))

(defun vigil-status-visit ()
  "Visit the file at point, at the line of it that point is on."
  (interactive)
  (if-let* ((file (get-text-property (point) 'vigil-status-file)))
      (vigil-status--visit file (get-text-property (point) 'vigil-status-line))
    (vigil-status-goto)))

(defun vigil-status-goto ()
  "Go to the line of the conversation where the call at point shows."
  (interactive)
  (vigil-status--call #'vigil-embark-goto))

(defun vigil-status-copy ()
  "Copy the prompt or the reply at point."
  (interactive)
  (let ((text (or (get-text-property (point) 'vigil-status-text)
                  (user-error "Neither a prompt nor a reply here"))))
    (kill-new text)
    (message "Copied %d characters" (length text))))

(defun vigil-status-diff ()
  "Show what changed after the prompt at point, or the commit at point."
  (interactive)
  (let ((commit (get-text-property (point) 'vigil-status-commit))
        (turn (get-text-property (point) 'vigil-status-turn)))
    (cond
     (commit (vigil-codebase--show-commit vigil-status--root commit))
     (turn
      (let ((entry (or (vigil-status--built-after
                        (cl-find turn vigil-status--turns
                                 :key (lambda (turn) (plist-get turn :index))))
                       (user-error "No snapshot was kept of this prompt"))))
        ;; Between this prompt's snapshot and the next prompt's: a message
        ;; sent while the agent worked has its own share of the turn.
        (vigil-review--show-diff vigil-status--root (nth 3 entry) (nth 4 entry) nil
                                 (format "Changed after prompt %d of %s, until the next"
                                         turn vigil-status--session))))
     (t (user-error "Neither a prompt nor a commit here")))))

(defun vigil-status-next-heading (&optional backward)
  "Go to the next prompt's line; the one before, with BACKWARD."
  (interactive)
  (let ((position (point)) found)
    (save-excursion
      (while (and (not found)
                  (eq 0 (forward-line (if backward -1 1)))
                  (not (if backward (bobp) (eobp))))
        (when (get-text-property (point) 'vigil-status-heading)
          (setq found (point))))
      (when (and backward (not found) (bobp)
                 (get-text-property (point) 'vigil-status-heading))
        (setq found (point))))
    (goto-char (or found position))
    (unless found (message "No more prompts"))))

(defun vigil-status-previous-heading ()
  "Go to the prompt's line before this one."
  (interactive)
  (vigil-status-next-heading t))

(defun vigil-status-quit ()
  "Leave this session's buffer, and the window beside it."
  (interactive)
  (vigil-status--detail-close)
  (quit-window))

;;;; The rest of vigil, for this session

(defun vigil-status--agent-or-error ()
  "The buffer this session's agent is in, or an error saying it has none."
  (or (vigil-status--agent vigil-status--session)
      (user-error "%s is not open in this Emacs, and this acts on its buffer"
                  vigil-status--session)))

(defun vigil-status-review ()
  "Show what this session built, against what was there when it began."
  (interactive)
  (let* ((session (vigil-status--session-here))
         (root (or vigil-status--root (vigil-status--find-root session)
                   (user-error "%s works in no repository" session)))
         (beginning (or (cl-find session (vigil-review-sessions root)
                                 :key (lambda (s) (plist-get s :host)) :test #'equal)
                        (user-error "No snapshot is kept of %s: see `vigil snapshots on'"
                                    session))))
    (vigil-review--open root beginning)))

(defun vigil-status--in-agent (command)
  "Call COMMAND, one of vigil.el's, in the buffer this session's agent is in."
  (let ((agent (vigil-status--agent-or-error)))
    (require 'vigil)
    (pop-to-buffer agent)
    (call-interactively command)))

(defun vigil-status-context ()
  "Show everything that has entered this session's agent's context."
  (interactive)
  (vigil-status--in-agent #'vigil-context))

(defun vigil-status-turn ()
  "Show a turn of this session, call by call, where its conversation is."
  (interactive)
  (vigil-status--in-agent #'vigil-turn))

(defun vigil-status-focus ()
  "Show only the prompts and replies in this session's conversation, or all."
  (interactive)
  (require 'vigil-transcript nil t)
  (vigil-status--in-agent #'vigil-focus-mode))

(defun vigil-status-paste-prompt ()
  "Choose an earlier prompt of this session, and paste it at its input."
  (interactive)
  (vigil-status--in-agent #'vigil-prompts))

(defun vigil-status-graph ()
  "Draw this session's turns as a graph, every one there is a record of."
  (interactive)
  (require 'vigil-graph)
  (vigil-graph (vigil-status--session-here) 0))

(defun vigil-status-codebase ()
  "Show where this session's repository is changing."
  (interactive)
  (require 'vigil-codebase)
  (vigil-codebase (or vigil-status--root default-directory)))

(defun vigil-status-running ()
  "List the commands agents started that are still going."
  (interactive)
  (require 'vigil)
  (call-interactively #'vigil-running))

(defun vigil-status-archive ()
  "List every conversation kept."
  (interactive)
  (require 'vigil-archive)
  (call-interactively #'vigil-archive))

(defun vigil-status-switch ()
  "Show another session."
  (interactive)
  (vigil (vigil-status--read-session t)))

;;;; The menu, the keys and the mode

;;;###autoload (autoload 'vigil-menu "vigil-status" nil t)
(transient-define-prefix vigil-menu ()
  "Every way of looking at a session, and the rest of vigil."
  [["This session"
    ("s" "Status" vigil-status-show-status)
    ("P" "Prompts, and what each led to" vigil-status-show-prompts)
    ("a" "Answers alone" vigil-status-show-answers)
    ("c" "Commands, and how long" vigil-status-show-commands)
    ("l" "Changes: what is changing now" vigil-status-show-changes)
    ("b" "Build: prompts and commits" vigil-status-show-build)
    ("v" "Beside the list, or under its lines" vigil-status-toggle-detail)]
   ["Elsewhere"
    ("r" "Review what it built" vigil-status-review)
    ("x" "Context" vigil-status-context)
    ("t" "A turn, call by call" vigil-status-turn)
    ("G" "Graph of its turns" vigil-status-graph)
    ("f" "Focus its conversation" vigil-status-focus)
    ("y" "Paste an earlier prompt" vigil-status-paste-prompt)]
   ["Not of one session"
    ("R" "Running commands" vigil-status-running)
    ("C" "Where the repository is changing" vigil-status-codebase)
    ("A" "Archive" vigil-status-archive)
    ("S" "Another session" vigil-status-switch)]])

(defvar vigil-status-mode-map (make-sparse-keymap)
  "Keys of a session's buffer.")

;; The views.
;; Set each time the file is loaded, so that loading it again gives a
;; buffer that is already open the keys that are new.
(define-key vigil-status-mode-map (kbd "s") #'vigil-status-show-status)
(define-key vigil-status-mode-map (kbd "P") #'vigil-status-show-prompts)
(define-key vigil-status-mode-map (kbd "a") #'vigil-status-show-answers)
(define-key vigil-status-mode-map (kbd "c") #'vigil-status-show-commands)
(define-key vigil-status-mode-map (kbd "l") #'vigil-status-show-changes)
(define-key vigil-status-mode-map (kbd "b") #'vigil-status-show-build)

;; What is at point.
(define-key vigil-status-mode-map (kbd "RET") #'vigil-status-act)
(define-key vigil-status-mode-map (kbd "o") #'vigil-status-visit)
(define-key vigil-status-mode-map (kbd "w") #'vigil-status-copy)
(define-key vigil-status-mode-map (kbd "d") #'vigil-status-diff)
(define-key vigil-status-mode-map (kbd "TAB") #'vigil-ui-fold-toggle)
(define-key vigil-status-mode-map (kbd "<backtab>") #'vigil-ui-fold-toggle-all)
(define-key vigil-status-mode-map (kbd "n") #'next-line)
(define-key vigil-status-mode-map (kbd "p") #'previous-line)
(define-key vigil-status-mode-map (kbd "M-n") #'vigil-status-next-heading)
(define-key vigil-status-mode-map (kbd "M-p") #'vigil-status-previous-heading)

;; How a view is looked at.
(define-key vigil-status-mode-map (kbd "v") #'vigil-status-toggle-detail)
(define-key vigil-status-mode-map (kbd "F") #'vigil-status-toggle-follow)
(define-key vigil-status-mode-map (kbd "T") #'vigil-status-toggle-since)
(define-key vigil-status-mode-map (kbd "L") #'vigil-status-toggle-looks)
(define-key vigil-status-mode-map (kbd "D") #'vigil-status-by-duration)
(define-key vigil-status-mode-map (kbd "g") #'vigil-status-refresh)
(define-key vigil-status-mode-map (kbd "q") #'vigil-status-quit)

;; The rest of vigil.
(define-key vigil-status-mode-map (kbd "r") #'vigil-status-review)
(define-key vigil-status-mode-map (kbd "x") #'vigil-status-context)
(define-key vigil-status-mode-map (kbd "t") #'vigil-status-turn)
(define-key vigil-status-mode-map (kbd "G") #'vigil-status-graph)
(define-key vigil-status-mode-map (kbd "f") #'vigil-status-focus)
(define-key vigil-status-mode-map (kbd "y") #'vigil-status-paste-prompt)
(define-key vigil-status-mode-map (kbd "R") #'vigil-status-running)
(define-key vigil-status-mode-map (kbd "C") #'vigil-status-codebase)
(define-key vigil-status-mode-map (kbd "A") #'vigil-status-archive)
(define-key vigil-status-mode-map (kbd "S") #'vigil-status-switch)
(define-key vigil-status-mode-map (kbd "?") #'vigil-menu)
(define-key vigil-status-mode-map (kbd "h") #'vigil-menu)

(define-derived-mode vigil-status-mode special-mode "Vigil"
  "A session, and every way of looking at it.
\\<vigil-status-mode-map>Five views: \\[vigil-status-show-status] its status, \\[vigil-status-show-prompts] its prompts and what each led to,
\\[vigil-status-show-answers] its replies alone, \\[vigil-status-show-commands] its commands and how long they took, \\[vigil-status-show-build] its
prompts among the repository's commits.  \\[vigil-menu] shows these and the rest of
vigil in a menu.

\\[vigil-status-act] opens what is at point: a call, a commit, a prompt.  \\[vigil-ui-fold-toggle] folds and
unfolds, \\[vigil-status-copy] copies the prompt or reply at point, \\[vigil-status-diff] shows what changed
after a prompt, and \\[vigil-status-refresh] reads the session again."
  (vigil-ui-fit #'vigil-status--render)
  (setq vigil-status--detail vigil-status-detail)
  (add-hook 'post-command-hook #'vigil-status--detail-sync nil t)
  (add-hook 'kill-buffer-hook #'vigil-status--stop-watching nil t)
  (add-hook 'kill-buffer-hook #'vigil-status--detail-close nil t))

;;;; Beginning

(defun vigil-status--read-session (&optional ask)
  "The session to show: this buffer's, or one asked for.
Asked for with ASK, or where this buffer is of none."
  (or (and (not ask) (vigil-status--session-at-hand))
      (let* ((directory (vigil-survey--root))
             ;; The one last heard of first.
             (sessions (sort (copy-sequence (vigil-survey-sessions))
                             (lambda (a b)
                               (time-less-p
                                (file-attribute-modification-time
                                 (file-attributes (expand-file-name b directory)))
                                (file-attribute-modification-time
                                 (file-attributes (expand-file-name a directory)))))))
             (table (lambda (string predicate action)
                      (if (eq action 'metadata)
                          '(metadata (display-sort-function . identity)
                                     (cycle-sort-function . identity))
                        (complete-with-action action sessions string predicate)))))
        (unless sessions (user-error "No session has reported anything yet"))
        (completing-read "Session: " table nil t))))

;;;###autoload
(defun vigil (session)
  "Show SESSION, and every way of looking at it.
In an agent's buffer, that agent's session; elsewhere, or with a prefix
argument, one asked for.  \\<vigil-status-mode-map>\\[vigil-menu] there shows what there is."
  (interactive (list (vigil-status--read-session current-prefix-arg)))
  (let ((buffer (get-buffer-create (format "*vigil: %s*" session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vigil-status-mode)
        (vigil-status-mode))
      (setq vigil-status--session session)
      (vigil-status--read)
      (vigil-status--start-watching))
    (pop-to-buffer buffer)
    ;; Drawn once it shows, so that it is laid out to its window.
    (with-current-buffer buffer
      (vigil-status--render)
      (vigil-status--detail-sync))
    buffer))

;;;###autoload
(defun vigil-live (session)
  "Show the files SESSION is changing now, and what is changing in each.
Read again as its agent works, and following the last change.  In an
agent's buffer, that agent's session; elsewhere, or with a prefix argument,
one asked for."
  (interactive (list (vigil-status--read-session current-prefix-arg)))
  (with-current-buffer (vigil session)
    (vigil-status-show-changes)))

(provide 'vigil-status)
;;; vigil-status.el ends here
