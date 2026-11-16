;;; vigil-running.el --- What agents' commands are running now -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil-running': every command an agent started that is still going,
;; of every agent on this machine whose commands are kept as runs (cooked's,
;; through bin/vigil-shell; see `vigil install-shell').  For each, the agent,
;; when it started and for how long it has gone, the command, and what it is
;; doing now: the processes at the bottom of the tree under it, which are
;; what a command is doing at any moment -- the `sleep 5' of a loop waiting
;; for something, the python under `pixi run'.
;;
;; The command is listed on one line, laid out as an inspected command is
;; (vigil-command.el) and highlighted; `c' shows it whole, its programs
;; taken out and laid out.  RET follows one as it prints, as inspecting its
;; call would; `g' looks again at once, and the list looks again by itself while it is on show.
;;
;; It only watches.  Nothing here signals, or sends anything to, a command:
;; the processes are only listed, by `ps', and the runs only read.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'vigil)
(require 'vigil-command)

(declare-function cooked-runs "cooked-run")
(declare-function cooked-run-live-p "cooked-run")
(declare-function cooked-run-name "cooked-run")
(declare-function cooked-run-show "cooked-run")
(declare-function cooked-run--directory "cooked-run")

(defcustom vigil-running-interval 3
  "Seconds between looks at what is running, while the list is on show."
  :type 'number
  :group 'vigil)

(defvar vigil-running--timer nil "The timer that keeps the list current.")

(defvar-local vigil-running--runs nil
  "The runs listed, by id: (RUN . AGENT), AGENT nil if not open here.")

(defun vigil-running--sessions ()
  "The sessions runs are kept for."
  (when (require 'cooked-run nil t)
    (let ((directory (cooked-run--directory)))
      (and (file-directory-p directory)
           (cl-remove-if-not
            (lambda (name) (file-directory-p (expand-file-name name directory)))
            (directory-files directory nil "\\`[^.]"))))))

(defun vigil-running--processes ()
  "Every process: a hash table from pid to (PPID . ARGS), by one `ps'."
  (let ((table (make-hash-table)))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (call-process "ps" nil '(t nil) nil "axo" "pid=,ppid=,args=")))
        (goto-char (point-min))
        (while (re-search-forward "^ *\\([0-9]+\\) +\\([0-9]+\\) \\(.*\\)$" nil t)
          (puthash (string-to-number (match-string 1))
                   (cons (string-to-number (match-string 2)) (match-string 3))
                   table))))
    table))

(defun vigil-running--now (pid processes)
  "What the process PID is doing now: the commands of the processes under it
that have none under them, in PROCESSES (see `vigil-running--processes')."
  (let ((children (make-hash-table)))
    (maphash (lambda (child entry) (push child (gethash (car entry) children)))
             processes)
    (let ((leaves nil) (todo (gethash pid children)))
      (while todo
        (let ((p (pop todo)))
          (if-let* ((under (gethash p children)))
              (setq todo (append under todo))
            (push (cdr (gethash p processes)) leaves))))
      (string-join (delete-dups (nreverse leaves)) "  ·  "))))

(defun vigil-running--agent (session)
  "The agent buffer of SESSION, if there is one."
  (cl-find-if (lambda (buffer)
                (equal (with-current-buffer buffer (bound-and-true-p cooked-host-name))
                       session))
              (vigil--agent-buffers)))

(defun vigil-running--call (run agent)
  "The call of AGENT whose command RUN is, if it is known."
  (when (buffer-live-p agent)
    (let ((label (plist-get run :label))
          (started (or (plist-get run :started) 0)))
      (cl-find-if (lambda (call)
                    (and (equal (alist-get 'command (vigil-call-input call)) label)
                         (< (abs (- (or (vigil-call-start call) 0) started)) 5)))
                  (reverse (buffer-local-value 'vigil--order agent))))))

(defvar vigil-running--highlighted (make-hash-table :test #'equal)
  "Text highlighted as shell, by the text: the list is drawn every few seconds.")

(defun vigil-running--shell (text)
  "TEXT highlighted as shell."
  (or (gethash text vigil-running--highlighted)
      (progn
        (when (> (hash-table-count vigil-running--highlighted) 512)
          (clrhash vigil-running--highlighted))
        (puthash text (vigil--fontify text #'sh-mode) vigil-running--highlighted))))

(defun vigil-running--command (command)
  "COMMAND, on one line, laid out and highlighted; its first line, without shfmt."
  (or (vigil-command-line command)
      (vigil-running--shell (car (split-string (string-trim command) "\n")))))

(defun vigil-running--entries ()
  "The rows of the list: every run still going, oldest first."
  (let ((processes (vigil-running--processes))
        (now (float-time))
        (runs nil))
    (setq vigil-running--runs (make-hash-table :test #'equal))
    (dolist (session (vigil-running--sessions))
      (let ((agent (vigil-running--agent session)))
        (dolist (run (cooked-runs session))
          (when (and (cooked-run-live-p run) (numberp (plist-get run :started)))
            (puthash (plist-get run :id) (cons run agent) vigil-running--runs)
            (push (list run agent session) runs)))))
    (mapcar
     (pcase-lambda (`(,run ,agent ,session))
       (list (plist-get run :id)
             (vector (if agent (buffer-name agent) session)
                     (format-time-string "%H:%M:%S" (plist-get run :started))
                     (vigil--for (- now (plist-get run :started)))
                     (vigil-running--shell
                      (vigil-running--now (plist-get run :pid) processes))
                     (vigil-running--command (cooked-run-name run)))))
     (sort runs (lambda (a b) (< (plist-get (car a) :started)
                                 (plist-get (car b) :started)))))))

(defvar vigil-running-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-running-follow)
    (define-key map (kbd "c") #'vigil-running-command)
    map)
  "Keys of `vigil-running-mode'.")

(define-derived-mode vigil-running-mode tabulated-list-mode "Running"
  "The commands agents started that are still going.
\\{vigil-running-mode-map}"
  (setq tabulated-list-format
        [("Agent" 26 t) ("Started" 8 nil) ("For" 7 nil :right-align t)
         ("Now" 40 nil) ("Command" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'vigil-running--entries)
  (setq-local mode-line-format " RET follow  c command  g look again  q quit")
  (tabulated-list-init-header))

(defun vigil-running--refresh ()
  "Look again at what is running, if the list is on show; stop once it is gone."
  (let ((buffer (get-buffer "*vigil running*")))
    (cond ((not (buffer-live-p buffer))
           (when vigil-running--timer (cancel-timer vigil-running--timer))
           (setq vigil-running--timer nil))
          ((get-buffer-window buffer 'visible)
           (with-current-buffer buffer
             (tabulated-list-print t t))))))

(defun vigil-running-follow ()
  "Follow the command on this line as it prints.
As inspecting its call would, where its call is known; else as a run."
  (interactive)
  (pcase-let ((`(,run . ,agent) (and (tabulated-list-get-id)
                                    (gethash (tabulated-list-get-id) vigil-running--runs))))
    (unless run (user-error "No command on this line"))
    (if-let* ((call (vigil-running--call run agent)))
        (vigil-inspect call agent)
      (cooked-run-show run))))

(defun vigil-running-command ()
  "Show the command on this line laid out, its programs taken out, highlighted.
As its call's report shows it, where its call is known; else from the run.
Only the command's text is read: what is running is not touched."
  (interactive)
  (pcase-let ((`(,run . ,agent) (and (tabulated-list-get-id)
                                    (gethash (tabulated-list-get-id) vigil-running--runs))))
    (unless run (user-error "No command on this line"))
    (vigil--inspect-report
     (or (vigil-running--call run agent)
         (vigil-call--make :id (plist-get run :id) :name "Bash"
                           :cwd (plist-get run :cwd)
                           :start (plist-get run :started)
                           :input `((command . ,(plist-get run :label)))))
     agent)))

;;;###autoload
(defun vigil-running ()
  "List the commands agents started that are still going, and what they are doing.
See vigil-running.el."
  (interactive)
  (unless (require 'cooked-run nil t)
    (user-error "Runs are cooked's: cooked-run.el is not on the load path"))
  (let ((buffer (get-buffer-create "*vigil running*")))
    (with-current-buffer buffer
      (vigil-running-mode)
      (tabulated-list-print))
    (unless vigil-running--timer
      (setq vigil-running--timer
            (run-with-timer vigil-running-interval vigil-running-interval
                            #'vigil-running--refresh)))
    (pop-to-buffer buffer)))

(provide 'vigil-running)
;;; vigil-running.el ends here
