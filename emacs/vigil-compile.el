;;; vigil-compile.el --- The agent's commands, as compilations -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; What a command the agent runs prints, where the agent runs its commands
;; through bin/vigil-shell (`vigil install-shell'), is followed by a buffer
;; of cooked's (cooked-run.el).  This makes that buffer behave as
;; `*compilation*' does:
;;
;; - Its errors and warnings are found as `compile' finds them, and
;;   \\[next-error] and \\[previous-error] go to them, as for a build of your
;;   own: the run shown last is the one `next-error' walks.  RET on one goes
;;   there; in the frame calls are inspected in, the file opens in that frame.
;;
;; - In `vigil-running', the command on the line the cursor is on is shown
;;   as it prints, in a window beside the list (`vigil-run-display-action': a
;;   side window at the bottom), the way `compile' shows a build: moving to
;;   another line shows that one in its place, and it is what `next-error'
;;   walks.  Nothing is shown unasked.
;;
;; - Unless you ask for that too: with `vigil-show-runs-after' set, a command
;;   still running that many seconds after the agent began it is shown the
;;   same way, in the agent's frame, while the agent's buffer is on show --
;;   never one left running in the background, such as a server.
;;
;; The run's buffer keeps its colours as `face', which a copy keeps, and has
;; no font lock to show `font-lock-face' by, which is what compile marks
;; errors with: here, `font-lock-face' shows where the program printed no
;; colour of its own.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'vigil)

(declare-function cooked-run-buffer "cooked-run")
(declare-function cooked-popup-quit "cooked-popup")
(declare-function cooked-popup-showing-p "cooked-popup")
(declare-function vigil-popup-quit "vigil-transcript")
(defvar cooked-popup--frame)
(declare-function cooked-run-live-p "cooked-run")

(defgroup vigil-compile nil
  "The agent's commands, as compilations."
  :group 'vigil)

(defcustom vigil-show-runs-after nil
  "Seconds after which a command the agent is running is shown as it prints.
In a window of the agent's frame, as `compile' shows a build, while the agent
is on show.  Nil, the default, shows one only when asked: from
`vigil-running', or by inspecting its call.  See vigil-compile.el."
  :type '(choice (const :tag "Never" nil) number))

(defcustom vigil-run-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . bottom) (slot . 0) (window-height . 0.25)
    (preserve-size . (nil . t)))
  "How a command the agent is running is shown, as `display-buffer' takes it.
In the agent's frame.  A side window, by default, so the next takes its place.
At the bottom, because the agent's terminal is made shorter for it, which
redraws less than being made narrower."
  :type 'sexp)

;;;; A run's buffer as a compilation

(defvar-local vigil-compile--timer nil
  "The timer that looks for errors in what has just been printed.")

(defun vigil-compile--parse (buffer)
  "Find the errors in what BUFFER has printed so far, as font lock would have."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq vigil-compile--timer nil)
      (when compilation-minor-mode
        (compilation--ensure-parse (point-max))))))

(defun vigil-compile--changed (_beg _end _length)
  "Look for errors in what was printed, shortly: more may be coming."
  (unless vigil-compile--timer
    (setq vigil-compile--timer
          (run-with-timer 0.2 nil #'vigil-compile--parse (current-buffer)))))

(defvar vigil-compile-run-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'compile-goto-error)
    (define-key map [follow-link] 'mouse-face)
    (define-key map (kbd "RET") #'compile-goto-error)
    (define-key map (kbd "C-c C-c") #'compile-goto-error)
    (define-key map (kbd "C-o") #'compilation-display-error)
    (define-key map (kbd "M-n") #'compilation-next-error)
    (define-key map (kbd "M-p") #'compilation-previous-error)
    (define-key map (kbd "M-{") #'compilation-previous-file)
    (define-key map (kbd "M-}") #'compilation-next-file)
    (define-key map (kbd "q") #'vigil-compile-quit)
    map)
  "The keys `compilation-minor-mode' has in a buffer following a run.
Its own map's, less the single letters -- `g' to compile again and `l'
among them -- which are the run buffer's and the pop-up's here; and `q',
which closes whichever of a window and the pop-up the run is shown in.")

(defun vigil-compile-quit ()
  "Close what shows this run: the pop-up, or else this window.
A run that was once inspected in the pop-up keeps the pop-up's keys, and
its `q' closes the pop-up: nothing, when the run is in a window beside the
list of what is running, or under the agent."
  (interactive)
  (if (and (fboundp 'cooked-popup-showing-p)
           (cooked-popup-showing-p (current-buffer))
           (or (not (display-graphic-p))
               (and (boundp 'cooked-popup--frame)
                    (eq (selected-frame) cooked-popup--frame))))
      (if (and (bound-and-true-p vigil-popup-mode) (fboundp 'vigil-popup-quit))
          (vigil-popup-quit)
        (cooked-popup-quit))
    (quit-window)))

(defun vigil-compile--setup ()
  "Make a buffer following a run work as a compilation's does.
On `cooked-run-mode-hook'."
  (compilation-minor-mode 1)
  (setq-local minor-mode-overriding-map-alist
              (cons (cons 'compilation-minor-mode vigil-compile-run-map)
                    minor-mode-overriding-map-alist))
  ;; What font lock does for `font-lock-face', with no font lock: where text
  ;; has no `face' of its own, its `font-lock-face' shows.
  (setq-local char-property-alias-alist (copy-tree char-property-alias-alist))
  (let ((faces (assq 'face char-property-alias-alist)))
    (if faces
        (unless (memq 'font-lock-face (cdr faces))
          (setcdr faces (append (cdr faces) (list 'font-lock-face))))
      (push (list 'face 'font-lock-face) char-property-alias-alist)))
  (add-hook 'after-change-functions #'vigil-compile--changed nil t))

(defun vigil-compile-goto-error ()
  "Go to the place the error at point names.
In the frame calls are inspected in, show it there; elsewhere, as
`compile-goto-error' does."
  (interactive)
  (if (not (vigil--popup-up-p))
      (call-interactively #'compile-goto-error)
    (compilation--ensure-parse (line-end-position))
    (let* ((at (or (and (get-text-property (point) 'compilation-message) (point))
                   (text-property-not-all (line-beginning-position) (line-end-position)
                                          'compilation-message nil)
                   (user-error "No error here")))
           (message (get-text-property at 'compilation-message))
           (loc (compilation--message->loc message))
           (spec (car (compilation--loc->file-struct loc)))
           (file (car spec)))
      (unless (stringp file)
        (user-error "The error names no file"))
      (vigil-preview-file (expand-file-name file (or (cadr spec) default-directory))
                          (compilation--loc->line loc)
                          (compilation--loc->col loc)))))

(define-key vigil-popup-mode-map [remap compile-goto-error] #'vigil-compile-goto-error)

;;;; Showing a long command as it runs

(defvar-local vigil-compile--timed nil
  "In an agent's buffer: the calls already given a time to be shown at.")

(defvar vigil-compile--shown nil
  "The buffer of the run `vigil-compile-display' showed last.")

(defun vigil-compile-display (run)
  "Show RUN as it prints, in another window, as `vigil-run-display-action' says.
Without selecting it.  It is what `next-error' walks now, as a compilation
shown last is.  The run shown this way before it is let go if it is on show
nowhere else: its buffer can be made again from what cooked keeps.  Returns
the window."
  (let* ((buffer (cooked-run-buffer run))
         (old vigil-compile--shown)
         (window (display-buffer buffer (append vigil-run-display-action
                                                '((inhibit-same-window . t))))))
    (when window
      (set-window-point window (with-current-buffer buffer (point-max))))
    (setq next-error-last-buffer buffer
          vigil-compile--shown buffer)
    (unless (eq old buffer)
      (vigil-compile-release old))
    window))

(defun vigil-compile-release (buffer)
  "Let go of BUFFER, a run `vigil-compile-display' showed.
Killed if it is on show nowhere: it can be made again from what cooked
keeps.  Left alone while a window still shows it."
  (when (and (buffer-live-p buffer) (not (get-buffer-window buffer t)))
    (when (eq vigil-compile--shown buffer)
      (setq vigil-compile--shown nil))
    (kill-buffer buffer)))

(defun vigil-compile--due (call agent)
  "Show CALL's command as it prints, in AGENT's frame, if it is still running
and AGENT is on show."
  (when-let* (((buffer-live-p agent))
              ((null (vigil-call-response call)))
              (window (get-buffer-window agent 'visible))
              (run (vigil--run-for call agent))
              ((cooked-run-live-p run)))
    (with-selected-window window
      (vigil-compile-display run))))

(defun vigil-compile--watch ()
  "Give each command this agent has begun a time to be shown at, if still running.
On `vigil-changed-hook'."
  (when (and vigil-show-runs-after (require 'cooked-run nil t))
    (unless vigil-compile--timed
      (setq vigil-compile--timed (make-hash-table :test #'eq :weakness 'key)))
    (let ((agent (current-buffer)))
      (dolist (call vigil--order)
        (when (and (not (gethash call vigil-compile--timed))
                   (equal (vigil-call-name call) "Bash")
                   (null (vigil-call-response call))
                   (not (alist-get 'run_in_background (vigil-call-input call))))
          (puthash call t vigil-compile--timed)
          (run-with-timer (max 0 (- (+ (or (vigil-call-start call) 0) vigil-show-runs-after)
                                    (float-time)))
                          nil #'vigil-compile--due call agent))))))

(add-hook 'cooked-run-mode-hook #'vigil-compile--setup)
(add-hook 'vigil-changed-hook #'vigil-compile--watch)

(provide 'vigil-compile)
;;; vigil-compile.el ends here
