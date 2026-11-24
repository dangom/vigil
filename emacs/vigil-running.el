;;; vigil-running.el --- What agents' commands are running now -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil-running': every command an agent started that is still going,
;; of every agent on this machine whose commands are kept as runs (cooked's,
;; through bin/vigil-shell; see `vigil install-shell').  For each, the agent,
;; when it started and for how long it has gone, how much of a processor
;; and of memory it and everything under it is using, why (what the agent
;; said the command was for, where its call is known here), the command, and
;; what it is doing now: the processes at the bottom of the tree under it, which are
;; what a command is doing at any moment -- the `sleep 5' of a loop waiting
;; for something, the python under `pixi run'.
;;
;; The command is listed on one line, laid out as an inspected command is
;; (vigil-command.el) and highlighted; `c' shows it whole, its programs
;; taken out and laid out.  The command on the cursor's line is shown as it
;; prints, in a window beside the list, and `next-error' walks its errors
;; (vigil-compile.el; `vigil-running-show-output'); the prompt the agent was
;; given last before it is said in the echo area.  RET follows one in the
;; frame calls are inspected in, as inspecting its call would; `g' looks
;; again at once, and the list looks again by itself while it is on show;
;; `q' leaves it, and closes the window beside it.
;;
;; It only watches.  Nothing here signals, or sends anything to, a command:
;; the processes are only listed, by `ps', and the runs only read.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'vigil)
(require 'vigil-command)
(require 'vigil-compile)

(declare-function cooked-runs "cooked-run")
(declare-function cooked-run-live-p "cooked-run")
(declare-function cooked-run-name "cooked-run")
(declare-function cooked-run-show "cooked-run")
(declare-function cooked-run--directory "cooked-run")
(declare-function cooked-popup-buffer "cooked-popup")
(declare-function cooked-popup-mode "cooked-popup")

(defcustom vigil-running-interval 3
  "Seconds between looks at what is running, while the list is on show."
  :type 'number
  :group 'vigil)

(defcustom vigil-running-show-output t
  "Whether the command on the cursor's line is shown as it prints, beside the list."
  :type 'boolean
  :group 'vigil)

(defvar vigil-running--timer nil "The timer that keeps the list current.")

(defvar-local vigil-running--shown nil "The id of the run shown beside the list.")
(defvar-local vigil-running--output nil
  "The buffer the list itself showed that run in as it prints, if it showed one.")

(defvar-local vigil-running-runs nil
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
  "Every process: a hash table from pid to (PPID ARGS CPU RSS), by one `ps'.
CPU is its share of a processor, in percent, as `ps' reckons it, and RSS
the memory it has in use, in kilobytes."
  (let ((table (make-hash-table)))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (call-process "ps" nil '(t nil) nil
                                  "axo" "pid=,ppid=,pcpu=,rss=,args=")))
        (goto-char (point-min))
        (while (re-search-forward
                "^ *\\([0-9]+\\) +\\([0-9]+\\) +\\([0-9.,]+\\) +\\([0-9]+\\) \\(.*\\)$"
                nil t)
          (puthash (string-to-number (match-string 1))
                   (list (string-to-number (match-string 2))
                         (match-string 5)
                         ;; Some locales print 12,5.
                         (string-to-number (string-replace "," "." (match-string 3)))
                         (string-to-number (match-string 4)))
                   table))))
    table))

(defun vigil-running--children (processes)
  "The processes each of PROCESSES started: a hash table from pid to pids."
  (let ((children (make-hash-table)))
    (maphash (lambda (child entry) (push child (gethash (car entry) children)))
             processes)
    children))

(defun vigil-running--tree (pid children)
  "PID and every process under it, by CHILDREN (`vigil-running--children').
Each after the one it is under."
  (let ((todo (list pid)) pids)
    (while todo
      (let ((p (pop todo)))
        (push p pids)
        (setq todo (append (gethash p children) todo))))
    (nreverse pids)))

(defun vigil-running--now (pid processes &optional children)
  "What the process PID is doing now: the commands of the processes under it
that have none under them, in PROCESSES (see `vigil-running--processes').
CHILDREN is PROCESSES' `vigil-running--children', if already reckoned."
  (let* ((children (or children (vigil-running--children processes)))
         (leaves (cl-remove-if (lambda (p) (gethash p children))
                               (cdr (vigil-running--tree pid children)))))
    (string-join (delete-dups (mapcar (lambda (p) (nth 1 (gethash p processes)))
                                      leaves))
                 "  ·  ")))

(defun vigil-running--usage (pid processes &optional children)
  "What the process PID and every process under it use, in PROCESSES: (CPU . RSS).
CPU in percent of one processor, so over 100 on several; RSS in kilobytes,
memory processes share counted once for each.  Nil if PID is not there.
CHILDREN as for `vigil-running--now'."
  (when (gethash pid processes)
    (let ((cpu 0) (rss 0))
      (dolist (p (vigil-running--tree
                  pid (or children (vigil-running--children processes))))
        (let ((entry (gethash p processes)))
          (cl-incf cpu (or (nth 2 entry) 0))
          (cl-incf rss (or (nth 3 entry) 0))))
      (cons cpu rss))))

(defun vigil-running-call (run agent)
  "The call of AGENT whose command RUN is, if it is known."
  (when (buffer-live-p agent)
    (let ((label (plist-get run :label))
          (started (or (plist-get run :started) 0)))
      (cl-find-if (lambda (call)
                    (and (equal (alist-get 'command (vigil-call-input call)) label)
                         (< (abs (- (or (vigil-call-start call) 0) started)) 5)))
                  (reverse (buffer-local-value 'vigil--order agent))))))

(defconst vigil-running-reason-length 200
  "How much of why a command is running is kept, in characters.")

(defun vigil-running--description (run agent)
  "What AGENT said RUN's command was for: the description it gave with it.
Nil where it gave none, or the call is not known in AGENT's buffer."
  (when-let* (((buffer-live-p agent))
              (call (vigil-running-call run agent)))
    (vigil--clip (alist-get 'description (vigil-call-input call))
                 vigil-running-reason-length)))

(defun vigil-running--prompt-before (run agent)
  "The prompt AGENT was given last before RUN began: a `vigil--prompt', or nil."
  (when (buffer-live-p agent)
    (let ((started (or (plist-get run :started) 0)))
      (car (last (cl-remove-if
                  (lambda (prompt)
                    (> (or (vigil--prompt-time prompt) 0) started))
                  (vigil--user-prompts
                   (buffer-local-value 'vigil--prompts agent))))))))

(defun vigil-running--reason (run agent)
  "Why RUN is running, in a line: what AGENT said its command was for.
Where it said nothing, or its call is not known here, what the last script
the command names says it is; see `vigil-command-summary'."
  (or (vigil-running--description run agent)
      (ignore-errors
        (vigil--clip (vigil-command-summary (plist-get run :label)
                                            (plist-get run :cwd))
                     vigil-running-reason-length))
      ""))

;;;; The files a command has open

(defcustom vigil-running-lsof "lsof"
  "The lsof program, which lists the files processes have open.
Without it the files of a command are not known."
  :type 'string
  :group 'vigil)

(defcustom vigil-running-files-ignore
  '("\\`/dev/" "\\`/System/" "\\`/Library/" "\\`/usr/\\(?:lib\\|share\\|libexec\\)/"
    "\\`/private/var/db/" "\\`/proc/" "\\`/sys/"
    "\\.\\(?:dylib\\|so\\)\\(?:\\.[0-9.]+\\)?\\'")
  "Files a command has open that are not listed: regexps matching their names.
The system's own, which every program opens.  What a run prints, as cooked
keeps it, is left out as well."
  :type '(repeat regexp)
  :group 'vigil)

(defvar vigil-running--files (make-hash-table :test #'equal)
  "The files each run has been seen to have open, by the run's id.
Each a hash table from a file's name to a plist: :mode, `read' or `write';
:first and :last, when it was first and last seen open; :by, the program
that had it open last.")

(defvar vigil-running--looks (make-hash-table :test #'equal)
  "How many times each run's files have been looked at, by the run's id.")

(defun vigil-running--parse-lsof (text)
  "The files TEXT, what `lsof -F pfatn' printed, says are open: (PID MODE NAME).
Regular files open on a descriptor: not a program's own text or its
libraries, a directory, a pipe or a terminal.  MODE is `write' for one open
for writing, or for both, and `read' otherwise."
  (let (pid fd access type files)
    (dolist (line (split-string text "\n" t))
      (let ((value (substring line 1)))
        (pcase (aref line 0)
          (?p (setq pid (string-to-number value)))
          (?f (setq fd value access nil type nil))
          (?a (setq access value))
          (?t (setq type value))
          (?n (when (and pid (equal type "REG") fd
                         (string-match-p "\\`[0-9]+\\'" fd))
                (push (list pid
                            (if (member access '("w" "u")) 'write 'read)
                            value)
                      files))))))
    (nreverse files)))

(defun vigil-running--lsof (pids)
  "The files the processes PIDS have open now: (PID MODE NAME), by one `lsof'.
Nil without lsof."
  (when (and pids (executable-find vigil-running-lsof))
    (with-temp-buffer
      ;; It exits with an error if any of the processes has gone since.
      (ignore-errors
        (call-process vigil-running-lsof nil '(t nil) nil
                      "-nP" "-F" "pfatn" "-p" (mapconcat #'number-to-string pids ",")))
      (vigil-running--parse-lsof (buffer-string)))))

(defun vigil-running--ignored-p (name)
  "Whether the file NAME is one not to list as a command's."
  (or (cl-some (lambda (regexp) (string-match-p regexp name))
               vigil-running-files-ignore)
      (and (fboundp 'cooked-run--directory)
           (string-prefix-p (file-truename (cooked-run--directory))
                            (file-truename name)))))

(defun vigil-running--look (runs processes children)
  "Note the files RUNS have open now, with those seen open before.
RUNS are runs as cooked reads them; PROCESSES and CHILDREN as for
`vigil-running--usage'.  One `lsof' for all of them.  What is known of a
run not among RUNS is let go: it is no longer running."
  (let ((owner (make-hash-table))
        (now (float-time))
        (live (make-hash-table :test #'equal)))
    (dolist (run runs)
      (puthash (plist-get run :id) t live)
      (when (gethash (plist-get run :pid) processes)
        (dolist (pid (vigil-running--tree (plist-get run :pid) children))
          (puthash pid (plist-get run :id) owner))))
    (dolist (table (list vigil-running--files vigil-running--looks))
      (maphash (lambda (id _) (unless (gethash id live) (remhash id table))) table))
    (let ((open (vigil-running--lsof (hash-table-keys owner))))
      (when (executable-find vigil-running-lsof)
        (dolist (run runs)
          (when (gethash (plist-get run :pid) processes)
            (cl-incf (gethash (plist-get run :id) vigil-running--looks 0)))))
      (pcase-dolist (`(,pid ,mode ,name) open)
        (when-let* ((id (gethash pid owner))
                    ((not (vigil-running--ignored-p name))))
          (let* ((files (or (gethash id vigil-running--files)
                            (puthash id (make-hash-table :test #'equal)
                                     vigil-running--files)))
                 (seen (gethash name files)))
            (puthash name
                     (list :mode (if (eq (plist-get seen :mode) 'write) 'write mode)
                           :first (or (plist-get seen :first) now)
                           :last now
                           :by (let ((args (nth 1 (gethash pid processes))))
                                 (and (stringp args)
                                      (file-name-nondirectory
                                       (car (split-string args " " t))))))
                     files)))))
    now))

(defun vigil-running--files-of (id)
  "The files the run ID has been seen to have open: (NAME . PLIST), by name."
  (let (files)
    (when-let* ((table (gethash id vigil-running--files)))
      (maphash (lambda (name seen) (push (cons name seen) files)) table))
    (sort files (lambda (a b) (string< (car a) (car b))))))

(defvar vigil-running--highlighted (make-hash-table :test #'equal)
  "Text highlighted as shell, by the text: the list is drawn every few seconds.")

(defun vigil-running--shell (text)
  "TEXT highlighted as shell."
  (vigil-command-remember vigil-running--highlighted text
                          (lambda () (vigil-command-fontify text #'sh-mode))))

(defun vigil-running--command (command)
  "COMMAND, on one line, laid out and highlighted; its first line, without shfmt."
  (or (vigil-command-line command)
      (vigil-running--shell (car (split-string (string-trim command) "\n")))))

(defun vigil-running--live ()
  "Every run still going, of every session: each (RUN AGENT SESSION).
AGENT is the session's agent buffer, where it is open here."
  (let (runs)
    (dolist (session (vigil-running--sessions))
      (let ((agent (vigil--session-buffer session)))
        (dolist (run (cooked-runs session))
          (when (and (cooked-run-live-p run) (numberp (plist-get run :started)))
            (push (list run agent session) runs)))))
    runs))

(defun vigil-running--entries ()
  "The rows of the list: every run still going, oldest first."
  (let* ((processes (vigil-running--processes))
         (children (vigil-running--children processes))
         (now (float-time))
         (runs (vigil-running--live)))
    (setq vigil-running-runs (make-hash-table :test #'equal))
    (pcase-dolist (`(,run ,agent ,_session) runs)
      (puthash (plist-get run :id) (cons run agent) vigil-running-runs))
    (ignore-errors
      (vigil-running--look (mapcar #'car runs) processes children))
    (mapcar
     (pcase-lambda (`(,run ,agent ,session))
       (let ((usage (vigil-running--usage (plist-get run :pid) processes children)))
         (list (plist-get run :id)
               (vector (if agent (buffer-name agent) session)
                       (format-time-string "%H:%M:%S" (plist-get run :started))
                       (vigil--for (- now (plist-get run :started)))
                       (if usage
                           (vigil-base-number (format "%.0f%%" (car usage))
                                                  (car usage))
                         "")
                       (if usage
                           (vigil-base-number
                            (file-size-human-readable (* 1024 (cdr usage)))
                            (cdr usage))
                         "")
                       (propertize (vigil-running--reason run agent)
                                   'face 'font-lock-comment-face)
                       (vigil-running--shell
                        (vigil-running--now (plist-get run :pid) processes children))
                       (vigil-running--command (cooked-run-name run))))))
     (sort runs (lambda (a b) (< (plist-get (car a) :started)
                                 (plist-get (car b) :started)))))))

(defvar vigil-running-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vigil-running-follow)
    (define-key map (kbd "c") #'vigil-running-command)
    (define-key map (kbd "f") #'vigil-running-files)
    (define-key map (kbd "q") #'vigil-running-quit)
    map)
  "Keys of `vigil-running-mode'.")

(define-derived-mode vigil-running-mode tabulated-list-mode "Running"
  "The commands agents started that are still going.
\\{vigil-running-mode-map}"
  (setq tabulated-list-format
        `[("Agent" 26 t) ("Started" 8 nil) ("For" 7 nil :right-align t)
          ("CPU" 5 ,(vigil-base-by-number 3) :right-align t)
          ("Mem" 6 ,(vigil-base-by-number 4) :right-align t)
          ("Why" 32 nil) ("Now" 32 nil) ("Command" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'vigil-running--entries)
  (setq-local mode-line-format " RET follow  c command  f files  g look again  q quit")
  (add-hook 'post-command-hook #'vigil-running--show-at-point nil t)
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

(defun vigil-running--show-at-point ()
  "Show the command on the cursor's line, if the cursor has come to another.
As it prints, beside the list, with `vigil-running-show-output'; and the
prompt it was run for, in the echo area.  On `post-command-hook' in the list."
  (let ((id (tabulated-list-get-id)))
    (unless (equal id vigil-running--shown)
      (setq vigil-running--shown id)
      (when-let* ((entry (and id (gethash id vigil-running-runs))))
        (setq vigil-running--output
              (and vigil-running-show-output
                   (when-let* ((window (vigil-compile-display (car entry))))
                     (window-buffer window))))
        (when-let* ((prompt (vigil-running--prompt-before (car entry) (cdr entry)))
                    (text (vigil--clip (vigil--prompt-text prompt)
                                       (max 20 (- (frame-width) 20)))))
          (let ((message-log-max nil))
            (message "%s  %s"
                     (propertize (format-time-string
                                  "Asked %H:%M" (vigil--prompt-time prompt))
                                 'face 'shadow)
                     text)))))))

(defun vigil-running-quit ()
  "Leave the list, and the command it shows as it prints beside it.
That window goes too, in this frame, and its buffer if it is on show
nowhere else: it can be made again from what cooked keeps.  The command
itself goes on."
  (interactive)
  ;; Only what the list showed itself: a run shown some other way is not its
  ;; to close.
  (let ((shown vigil-running--output))
    (setq vigil-running--shown nil
          vigil-running--output nil)
    (when (buffer-live-p shown)
      (dolist (window (get-buffer-window-list shown nil (selected-frame)))
        (unless (eq window (selected-window))
          (quit-window nil window)))
      (vigil-compile-release shown)))
  (quit-window))

(defun vigil-running-follow ()
  "Follow the command on this line as it prints.
As inspecting its call would, where its call is known; else as a run."
  (interactive)
  (pcase-let ((`(,run . ,agent) (and (tabulated-list-get-id)
                                    (gethash (tabulated-list-get-id) vigil-running-runs))))
    (unless run (user-error "No command on this line"))
    (if-let* ((call (vigil-running-call run agent)))
        (vigil-inspect call agent)
      (cooked-run-show run))))

(defun vigil-running-command ()
  "Show the command on this line laid out, its programs taken out, highlighted.
As its call's report shows it, where its call is known; else from the run.
Only the command's text is read: what is running is not touched."
  (interactive)
  (pcase-let ((`(,run . ,agent) (and (tabulated-list-get-id)
                                    (gethash (tabulated-list-get-id) vigil-running-runs))))
    (unless run (user-error "No command on this line"))
    (vigil--inspect-report
     (or (vigil-running-call run agent)
         (vigil-call--make :id (plist-get run :id) :name "Bash"
                           :cwd (plist-get run :cwd)
                           :start (plist-get run :started)
                           :input `((command . ,(plist-get run :label)))))
     agent)))

(defun vigil-running--insert-files (run)
  "Insert the files RUN has been seen to have open: those written, those read."
  (let* ((id (plist-get run :id))
         (files (vigil-running--files-of id))
         (looks (gethash id vigil-running--looks 0))
         (now (float-time))
         (section
          (lambda (title mode)
            (when-let* ((mine (cl-remove-if-not
                               (lambda (file) (eq (plist-get (cdr file) :mode) mode))
                               files)))
              (insert "\n")
              (vigil--section (format "%s (%d)" title (length mine)))
              (pcase-dolist (`(,name . ,seen) mine)
                (let* ((ago (- now (plist-get seen :last)))
                       (open (< ago (* 2 vigil-running-interval)))
                       (size (file-attribute-size (file-attributes name))))
                  (insert (if open "● " (propertize "○ " 'face 'shadow))
                          (abbreviate-file-name name)
                          (propertize
                           (concat (if size
                                       (format "  %s" (file-size-human-readable size))
                                     "  gone")
                                   (if (plist-get seen :by)
                                       (format "  %s" (plist-get seen :by))
                                     "")
                                   (if open "" (format "  closed %s ago" (vigil--for ago))))
                           'face 'shadow)
                          "\n")))))))
    (insert (propertize "$ " 'face 'shadow)
            (or (vigil-command-line (plist-get run :label)) (plist-get run :label) "")
            "\n"
            (propertize
             (format "# The files it and the processes under it had open, looked at %d time%s.\n# ● open now  ○ open earlier.  One opened and closed between two looks is not here.\n"
                     looks (if (= looks 1) "" "s"))
             'face 'shadow))
    (funcall section "Writing" 'write)
    (funcall section "Reading" 'read)
    (unless files
      (insert "\n" (propertize
                    (if (executable-find vigil-running-lsof)
                        "(no file of its own open so far)\n"
                      "(lsof is not installed: the files are not known)\n")
                    'face 'shadow)))))

(defun vigil-running-files ()
  "Show the files the command on this line reads and writes, as far as seen.
What it and every process under it had open each time the list looked:
found by looking, not by reading the command, so it is what it does and
not what it says.  \\`g' there looks again.  Only `lsof' is run: the
command is not touched."
  (interactive)
  (pcase-let ((`(,run . ,_agent) (and (tabulated-list-get-id)
                                     (gethash (tabulated-list-get-id) vigil-running-runs))))
    (unless run (user-error "No command on this line"))
    (let ((buffer (get-buffer-create "*vigil files*"))
          (draw (lambda (&rest _)
                  (let ((inhibit-read-only t)
                        (processes (vigil-running--processes)))
                    (ignore-errors
                      (vigil-running--look
                       ;; With the others, so that what is known of them stays.
                       (let ((runs (mapcar #'car (vigil-running--live))))
                         (if (cl-find (plist-get run :id) runs
                                      :key (lambda (r) (plist-get r :id)) :test #'equal)
                             runs
                           (cons run runs)))
                       processes (vigil-running--children processes)))
                    (erase-buffer)
                    (vigil-running--insert-files run)
                    (vigil--link-files (point-min) (point-max) default-directory)
                    (goto-char (point-min))))))
      (with-current-buffer buffer
        (vigil-view-mode)
        (when (stringp (plist-get run :cwd))
          (setq default-directory (file-name-as-directory (plist-get run :cwd))))
        (setq-local revert-buffer-function draw)
        (setq-local mode-line-format " q close  g look again  RET on a file previews it")
        (funcall draw)
        (cooked-popup-mode 1))
      (cooked-popup-buffer buffer))))

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
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (vigil-running--show-at-point))))

(provide 'vigil-running)
;;; vigil-running.el ends here
