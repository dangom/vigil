;;; vigil-embark.el --- A call as one Embark target, wherever it shows -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; A tool call shows in six places: marked in its agent's conversation, as
;; a heading of the context buffer, as a row of a turn, in the frame it is
;; inspected in, in the fringe of a file it edited, and as a row of the
;; commands still running.  Each has keys of its own, and they stay.  This
;; makes the call one target for Embark in all six, with one map of
;; actions: `embark-act' on a call, wherever it is, offers the same.
;;
;; The target is a string that names the call by itself:
;;
;;   SESSION/CALL-ID
;;
;; SESSION is its agent's session (`cooked-host-name', which has no "/" in
;; it) and CALL-ID the call's id.  A string, and nothing carried on it as
;; text properties: Embark hands an action its target by typing it at the
;; action's minibuffer prompt, without properties, and collects and exports
;; plain strings.  So every action here is a command that reads that one
;; string, and `vigil-embark--resolve' finds the call and its agent's
;; buffer from it.  A session with no live buffer has no calls to act on.
;;
;; A second target, `vigil-session', is a session by its name alone: a row
;; of the archive's list, and whatever else lists sessions and says so.
;;
;; Nothing here needs Embark to load.  The finders and the commands are
;; plain functions; they are given to Embark once it is loaded:
;;
;;   vigil-embark-target-call     the finder of calls, type `vigil-call'
;;   vigil-embark-target-session  the finder of sessions, `vigil-session'
;;   vigil-embark-call-map        the actions on a call
;;   vigil-embark-session-map     the actions on a session

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil)
(require 'vigil-transcript)
(require 'vigil-turn)
(require 'vigil-edits)

(declare-function cooked-annotation-at "cooked-annotate")
(declare-function cooked-annotation-data "cooked-annotate")
(declare-function cooked-annotation-beg "cooked-annotate")
(declare-function cooked-annotation-end "cooked-annotate")
(declare-function cooked-paste-string "cooked-keys")
(declare-function vigil-running-call "vigil-running")
(declare-function vigil-archive-sessions "vigil-archive")
(declare-function vigil-archive-open "vigil-archive")
(declare-function vigil-archive-export "vigil-archive")
(declare-function vigil-graph "vigil-graph")
(defvar vigil-running-runs)
(defvar embark-general-map)
(defvar embark-keymap-alist)
(defvar embark-target-finders)

;;;; A call and its name

(defun vigil-embark--name (item agent)
  "The target naming ITEM of the agent buffer AGENT: \"SESSION/CALL-ID\".
Nil where ITEM stands for no call, or AGENT is not a session's live buffer:
an archived session's calls are not acted on."
  (when-let* ((call (vigil--item-call item))
              ((buffer-live-p agent))
              (session (vigil--session-name agent))
              (id (vigil-call-id call))
              ((stringp id)))
    (concat session "/" id)))

(defun vigil-embark--resolve (target)
  "The call TARGET names, and its agent's buffer: (CALL . AGENT).
TARGET is \"SESSION/CALL-ID\".  An error saying so where the session has no
live buffer, or has no such call."
  (unless (and (stringp target) (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" target))
    (user-error "Not a call: %s" target))
  (let* ((session (match-string 1 target))
         (id (match-string 2 target))
         (agent (or (vigil--session-buffer session)
                    (user-error "No live buffer for the session %s" session)))
         (calls (buffer-local-value 'vigil--calls agent)))
    (cons (or (and calls (gethash id calls))
              (user-error "The session %s has no call %s" session id))
          agent)))

;;;; Finding the call at point

(defun vigil-embark--line ()
  "The bounds of this line: (START . END)."
  (cons (line-beginning-position) (line-end-position)))

(defun vigil-embark--at-point ()
  "The call at point, its agent's buffer and where it shows: (ITEM AGENT BOUNDS).
In whichever of the six places this buffer is; nil in none, or off a call."
  (cond
   ((derived-mode-p 'vigil-turn-mode)
    (list (tabulated-list-get-id) vigil-turn-agent (vigil-embark--line)))
   ((derived-mode-p 'vigil-running-mode)
    (pcase-let ((`(,run . ,agent)
                 (and (tabulated-list-get-id) (bound-and-true-p vigil-running-runs)
                      (gethash (tabulated-list-get-id) vigil-running-runs))))
      (and run (list (vigil-running-call run agent) agent (vigil-embark--line)))))
   ((derived-mode-p 'vigil-context-mode)
    (list (vigil--context-item) vigil--context-agent
          (save-excursion
            (end-of-line)
            (and (re-search-backward "^\\*+ " nil t) (vigil-embark--line)))))
   (vigil--popup-call
    (list vigil--popup-call vigil--popup-agent (vigil-embark--line)))
   ((and vigil-mode (fboundp 'cooked-annotation-at))
    (when-let* ((annotation (cooked-annotation-at)))
      (list (cooked-annotation-data annotation) (current-buffer)
            (cons (marker-position (cooked-annotation-beg annotation))
                  (save-excursion
                    (goto-char (cooked-annotation-end annotation))
                    (line-end-position))))))
   ((bound-and-true-p vigil-edits-mode)
    (when-let* ((owner (vigil-edits-owner-at)))
      (list (car owner) (cdr owner) (vigil-embark--line))))))

(defun vigil-embark-target-call ()
  "The call at point as an Embark target: (vigil-call TARGET START . END).
TARGET is \"SESSION/CALL-ID\"; START and END bound its line or heading.
Where a call shows: in a conversation, the context, a turn, the frame it is
inspected in, a file it edited, the commands running.  For
`embark-target-finders'."
  (pcase-let ((`(,item ,agent ,bounds) (vigil-embark--at-point)))
    (when-let* ((target (and item bounds (vigil-embark--name item agent))))
      `(vigil-call ,target ,(car bounds) . ,(cdr bounds)))))

;;;; What is done to a call

(defun vigil-embark--read ()
  "Read a call's name, for a command that acts on one."
  (list (read-string "Call: ")))

(defun vigil-embark--command (call)
  "The command CALL ran, or an error saying it ran none."
  (let ((command (alist-get 'command (vigil-call-input call))))
    (if (stringp command)
        command
      (user-error "%s ran no command" (vigil-call-name call)))))

(defun vigil-embark-inspect (target)
  "Inspect the call TARGET names, as RET on it does."
  (interactive (vigil-embark--read))
  (pcase-let ((`(,call . ,agent) (vigil-embark--resolve target)))
    (vigil-inspect call agent)))

(defun vigil-embark-goto (target)
  "Go to the line of the conversation where the call TARGET names shows."
  (interactive (vigil-embark--read))
  (pcase-let ((`(,call . ,agent) (vigil-embark--resolve target)))
    (vigil-goto-call call agent)))

(defun vigil-embark-turn (target)
  "Show the turn of the call TARGET names, call by call, and that call in it."
  (interactive (vigil-embark--read))
  (pcase-let ((`(,call . ,agent) (vigil-embark--resolve target)))
    (vigil-turn-show agent (vigil-turn-of call agent) call)))

(defun vigil-embark-turn-diff (target)
  "Show what the turn of the call TARGET names changed, as one diff."
  (interactive (vigil-embark--read))
  (pcase-let ((`(,call . ,agent) (vigil-embark--resolve target)))
    (vigil-edits-show-diff agent (vigil-turn-of call agent))))

(defun vigil-embark-visit (target)
  "Visit the file the call TARGET names edited, at its first change."
  (interactive (vigil-embark--read))
  (pcase-let* ((`(,call . ,_agent) (vigil-embark--resolve target))
               (place (and (member (vigil-call-name call)
                                   '("Edit" "MultiEdit" "Write" "NotebookEdit"))
                           (vigil--call-place call))))
    (unless place
      (user-error "%s edited no file" (vigil-call-name call)))
    (unless (file-exists-p (car place))
      (user-error "%s is no longer there" (abbreviate-file-name (car place))))
    (vigil--visit-place place)))

(defun vigil-embark--input (call)
  "What CALL was given, as text: its command, or its input as JSON."
  (let ((input (vigil-call-input call)))
    (cond ((stringp (alist-get 'command input)) (alist-get 'command input))
          (input (vigil--json input))
          (t (user-error "%s was given nothing" (vigil-call-name call))))))

(defun vigil-embark--result (call)
  "What CALL gave back, as text, or an error saying it has given nothing."
  (let* ((response (vigil-call-response call))
         (subagent (vigil-call-subagent call))
         (printed (and (consp response)
                       (cl-remove-if-not
                        (lambda (text) (and (stringp text) (not (string-empty-p text))))
                        (list (alist-get 'stdout response)
                              (alist-get 'stderr response)))))
         (read (and (consp response) (consp (alist-get 'file response))
                    (alist-get 'content (alist-get 'file response)))))
    (cond ((stringp response) response)
          (printed (string-join printed "\n"))
          ((stringp read) read)
          ((and (consp response) (vigil--response-text response)))
          ((and subagent (stringp (vigil-subagent-result subagent)))
           (vigil-subagent-result subagent))
          ((consp response) (vigil--json response))
          (t (user-error "%s has no result yet" (vigil-call-name call))))))

(defun vigil-embark-copy-command (target)
  "Copy the command the call TARGET names ran, as it was given.
For a call that ran none, what it was given, as JSON."
  (interactive (vigil-embark--read))
  (let ((text (vigil-embark--input (car (vigil-embark--resolve target)))))
    (kill-new text)
    (message "Copied: %s" (vigil--clip text 60))
    text))

(defun vigil-embark-copy-result (target)
  "Copy what the call TARGET names gave back: what a command printed, a
file as it was read, what a subagent reported; else its result as JSON."
  (interactive (vigil-embark--read))
  (let ((text (vigil-embark--result (car (vigil-embark--resolve target)))))
    (kill-new text)
    (message "Copied %d characters of its result" (length text))
    text))

(defun vigil-embark-explain (target)
  "Say what the programs and options of the command TARGET names are.
From the manuals on this machine; see `vigil-command-explain'."
  (interactive (vigil-embark--read))
  (let ((command (vigil-embark--command (car (vigil-embark--resolve target))))
        (buffer (get-buffer-create "*vigil explain*")))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (vigil-command-fontify command #'sh-mode) "\n\n")
        (vigil-command-insert-explanation command)
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(defun vigil-embark-paste (target)
  "Paste the command the call TARGET names ran at its agent's prompt.
Pasted, not submitted."
  (interactive (vigil-embark--read))
  (pcase-let* ((`(,call . ,agent) (vigil-embark--resolve target))
               (command (vigil-embark--command call)))
    (pop-to-buffer agent)
    (cooked-paste-string command)))

(defvar vigil-embark-call-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-embark-inspect)
    (define-key map (kbd "o") #'vigil-embark-goto)
    (define-key map (kbd "t") #'vigil-embark-turn)
    (define-key map (kbd "d") #'vigil-embark-turn-diff)
    (define-key map (kbd "v") #'vigil-embark-visit)
    ;; Over `embark-copy-as-kill': a call's name is of no use copied, and
    ;; what it ran is what copying a call means.
    (define-key map (kbd "w") #'vigil-embark-copy-command)
    (define-key map (kbd "W") #'vigil-embark-copy-result)
    (define-key map (kbd "e") #'vigil-embark-explain)
    (define-key map (kbd "y") #'vigil-embark-paste)
    map)
  "What Embark offers on a call, a target of type `vigil-call'.
Its parent is `embark-general-map', once Embark is loaded.")

;;;; A session

(defun vigil-embark--session-name (session)
  "The name an archived SESSION, a plist, goes by: its agent's session's.
Its own id where it was not in one."
  (let ((name (or (plist-get session :host) (plist-get session :id))))
    (and (stringp name) name)))

(defun vigil-embark-target-session ()
  "The session at point as an Embark target: (vigil-session NAME START . END).
NAME is the session's name alone.  On a row of the archive's list.  For
`embark-target-finders'."
  (when (derived-mode-p 'vigil-archive-mode)
    (when-let* ((name (vigil-embark--session-name (tabulated-list-get-id))))
      `(vigil-session ,name ,(line-beginning-position) . ,(line-end-position)))))

(defun vigil-embark--archived (name)
  "The archived sessions that go by NAME, newest first.
One name is many archived sessions, an agent's session being started over:
on the row of one of them in the archive's list, that one alone."
  (require 'vigil-archive)
  (let ((row (and (derived-mode-p 'vigil-archive-mode) (tabulated-list-get-id))))
    (if (and row (equal (vigil-embark--session-name row) name))
        (list row)
      (cl-remove-if-not (lambda (session)
                          (equal (vigil-embark--session-name session) name))
                        (vigil-archive-sessions)))))

(defun vigil-embark--read-session ()
  "Read a session's name, for a command that acts on one."
  (list (read-string "Session: ")))

(defun vigil-embark-session-open (name)
  "Open the session NAME: the archived one on this row, else its agent's
buffer if it is live, else the newest archived one of that name."
  (interactive (vigil-embark--read-session))
  (let ((agent (vigil--session-buffer name)))
    (cond ((derived-mode-p 'vigil-archive-mode)
           (vigil-archive-open (or (car (vigil-embark--archived name))
                                   (user-error "No archived session %s" name))))
          (agent (pop-to-buffer agent))
          (t (vigil-archive-open (or (car (vigil-embark--archived name))
                                     (user-error "No session %s, live or archived"
                                                 name)))))))

(defun vigil-embark-session-context (name)
  "Show everything that entered the context of the session NAME.
Of its live agent, as `vigil-context' does; else of the archived one."
  (interactive (vigil-embark--read-session))
  (if-let* ((agent (vigil--session-buffer name)))
      (vigil-context agent)
    (vigil-archive-open (or (car (vigil-embark--archived name))
                            (user-error "No session %s, live or archived" name)))))

(defun vigil-embark-session-graph (name)
  "Show the last turns of the session NAME as a graph; see `vigil-graph'."
  (interactive (vigil-embark--read-session))
  (vigil-graph name))

(defun vigil-embark-session-export (name file)
  "Export the archived sessions that go by NAME to FILE, for evals.
On a row of the archive's list, that one session."
  (interactive (append (vigil-embark--read-session)
                       (list (read-file-name "Export to: " nil nil nil
                                             "vigil-session.jsonl"))))
  (vigil-archive-export file (or (vigil-embark--archived name)
                                 (user-error "No archived session %s" name))))

(defvar vigil-embark-session-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-embark-session-open)
    (define-key map (kbd "c") #'vigil-embark-session-context)
    (define-key map (kbd "g") #'vigil-embark-session-graph)
    (define-key map (kbd "e") #'vigil-embark-session-export)
    map)
  "What Embark offers on a session, a target of type `vigil-session'.
Its parent is `embark-general-map', once Embark is loaded.")

;;;; Given to Embark

(with-eval-after-load 'embark
  (set-keymap-parent vigil-embark-call-map embark-general-map)
  (set-keymap-parent vigil-embark-session-map embark-general-map)
  (add-to-list 'embark-keymap-alist '(vigil-call vigil-embark-call-map))
  (add-to-list 'embark-keymap-alist '(vigil-session vigil-embark-session-map))
  ;; In front: on a line that names a file too, the call is offered first,
  ;; and the file by cycling.
  (add-hook 'embark-target-finders #'vigil-embark-target-session)
  (add-hook 'embark-target-finders #'vigil-embark-target-call))

(provide 'vigil-embark)
;;; vigil-embark.el ends here
