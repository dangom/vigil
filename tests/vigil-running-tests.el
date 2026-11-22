;;; vigil-running-tests.el --- What agents' commands are running now -*- lexical-binding: t; -*-

;; Runs written the way `cooked-host run' writes them, into a directory of
;; the test's own; the processes are a made-up table, not this machine's.
;;
;;   emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-running-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vigil)
(require 'vigil-running)
(require 'cooked-run)

(defun vigil-running-tests--table (&rest rows)
  "A process table, as `vigil-running--processes' gives one.
Of ROWS (PID PPID ARGS [CPU RSS])."
  (let ((table (make-hash-table)))
    (dolist (row rows) (puthash (car row) (cdr row) table))
    table))

(ert-deftest vigil-running-says-what-a-command-is-doing-now ()
  "The processes at the bottom of the tree under a run are what it is doing."
  (let ((table (vigil-running-tests--table
                '(100 1 "bash -c source x && eval 'until ...; do sleep 60; done'")
                '(101 100 "sleep 60")
                '(200 1 "bash -c pixi run wu probs")
                '(201 200 "pixi run wu probs")
                '(202 201 "python -m wu probs --n 40")
                '(203 201 "python -m wu probs --n 40")
                '(300 1 "bash -c true"))))
    (should (equal (vigil-running--now 100 table) "sleep 60"))
    ;; The same command twice is said once.
    (should (equal (vigil-running--now 200 table) "python -m wu probs --n 40"))
    ;; Nothing under it: nothing to say beyond the command itself.
    (should (equal (vigil-running--now 300 table) ""))))

(ert-deftest vigil-running-says-what-a-command-uses ()
  "A run uses what it and every process under it use."
  (let ((table (vigil-running-tests--table
                '(200 1 "bash -c pixi run wu probs" 0.0 2048)
                '(201 200 "pixi run wu probs" 1.5 10240)
                '(202 201 "python -m wu probs --n 40" 99.0 512000)
                '(203 201 "python -m wu probs --n 40" 98.5 512000)
                '(300 1 "unrelated" 50.0 999999))))
    (should (equal (vigil-running--usage 200 table) '(199.0 . 1036288)))
    (should (equal (vigil-running--usage 202 table) '(99.0 . 512000)))
    ;; Gone since it was listed.
    (should-not (vigil-running--usage 999 table))
    ;; The columns sort by the numbers, not by how they are written.
    (let ((row (lambda (cpu) (list cpu (vector "" "" ""
                                               (vigil-running--number
                                                (format "%.0f%%" cpu) cpu))))))
      (should (funcall (vigil-running--by 3) (funcall row 100.0) (funcall row 9.0)))
      (should-not (funcall (vigil-running--by 3) (funcall row 9.0) (funcall row 100.0))))))

(ert-deftest vigil-running-reads-ps ()
  "This machine's `ps' is read: Emacs itself is there, using some memory."
  (skip-unless (eq 0 (ignore-errors (call-process "ps" nil nil nil "-p" "1"))))
  (let ((self (gethash (emacs-pid) (vigil-running--processes))))
    (should (stringp (nth 1 self)))
    (should (numberp (nth 2 self)))
    (should (> (nth 3 self) 0))))

(ert-deftest vigil-running-says-why ()
  "What the agent said a command was for, and the prompt before it."
  (with-temp-buffer
    (let ((run '(:id "1.0-1" :label "make test" :started 1000.0))
          (agent (current-buffer)))
      (setq vigil--order
            (list (vigil-call--make :id "a" :name "Bash" :start 1001.0
                                    :input '((command . "make test")
                                             (description . "Run the tests")))
                  ;; The same command, another time: not this run's call.
                  (vigil-call--make :id "b" :name "Bash" :start 2000.0
                                    :input '((command . "make test")
                                             (description . "Run them again"))))
            vigil--prompts
            (list (vigil--prompt-make :text "fix the build" :time 900.0)
                  (vigil--prompt-make :text "<task-notification>done" :time 950.0)
                  (vigil--prompt-make :text "now the docs" :time 1500.0)))
      (pcase-let ((`(,reason . ,prompt) (vigil-running--why run agent)))
        (should (equal reason "Run the tests"))
        (should (equal (vigil--prompt-text prompt) "fix the build")))
      ;; No call known: the prompt still is, from when the run began.
      (pcase-let ((`(,reason . ,prompt)
                   (vigil-running--why '(:label "ls" :started 1600.0) agent)))
        (should-not reason)
        (should (equal (vigil--prompt-text prompt) "now the docs"))))
    ;; An agent not open here: nothing to say.
    (should-not (vigil-running--why '(:label "ls" :started 1.0) nil))))

(ert-deftest vigil-running-quit-closes-what-it-showed ()
  "`q' closes the window the list showed a command in, with the list."
  (let ((list (get-buffer-create "*vigil running*"))
        (output (generate-new-buffer "output"))
        (vigil-compile--shown nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (pop-to-buffer-same-window list)
          (vigil-running-mode)
          (display-buffer output '(display-buffer-below-selected))
          (should (get-buffer-window output))
          (setq vigil-compile--shown output
                vigil-running--shown "1.0-1")
          (vigil-running-quit)
          (should-not (get-buffer-window output))
          (should-not (buffer-live-p output))
          (should-not (get-buffer-window list))
          ;; Nothing shown by the list: nothing else is closed.
          (let ((other (generate-new-buffer "other")))
            (pop-to-buffer-same-window list)
            (display-buffer other '(display-buffer-below-selected))
            (setq vigil-compile--shown other)
            (vigil-running-quit)
            (should (buffer-live-p other))
            (kill-buffer other)))
      (when (buffer-live-p output) (kill-buffer output))
      (kill-buffer list))))

(ert-deftest vigil-running-says-for-how-long ()
  (should (equal (vigil--for 42.7) "42s"))
  (should (equal (vigil--for 185) "3m05s"))
  (should (equal (vigil--for 7830) "2h10m")))

(ert-deftest vigil-running-lists-only-what-is-still-going ()
  "Every session's runs that are still going, oldest first; and only listed."
  (let* ((cooked-run-directory (make-temp-file "vigil-runs" t))
         (write (lambda (session id label started &optional ended)
                  (let ((dir (expand-file-name session cooked-run-directory)))
                    (make-directory dir t)
                    (write-region
                     (json-serialize `((id . ,id) (session . ,session)
                                       (pid . ,(emacs-pid)) (cwd . "/tmp")
                                       (argv . ["sh" "-c" "x"]) (label . ,label)
                                       (started . ,started)
                                       ,@(and ended `((ended . ,ended) (exit . 0)))))
                     nil (expand-file-name (concat id ".json") dir) nil 'silent)))))
    (unwind-protect
        (progn
          (funcall write "a.1" "2.0-2" "make test\nand more" (- (float-time) 60))
          (funcall write "a.1" "1.0-1" "ls" 1000.0 1001.0)        ; done
          (funcall write "b.1" "3.0-3" "sleep 100" (- (float-time) 600))
          (cl-letf (((symbol-function 'vigil-running--processes)
                     (lambda () (vigil-running-tests--table
                                 (list (emacs-pid) 1 "emacs" 12.4 2048)
                                 '(99999 1 "unrelated"))))
                    ;; The files Emacs itself has open are not the test's.
                    ((symbol-function 'vigil-running--lsof) #'ignore))
            (with-temp-buffer
              (vigil-running-mode)
              (let ((rows (vigil-running--entries)))
                (should (equal (mapcar #'car rows) '("3.0-3" "2.0-2")))
                (should (equal (aref (cadr (car rows)) 0) "b.1"))
                (should (equal (aref (cadr (car rows)) 2) "10m00s"))
                (should (equal (substring-no-properties (aref (cadr (car rows)) 3))
                               "12%"))
                (should (equal (substring-no-properties (aref (cadr (car rows)) 4))
                               "2M"))
                ;; A command on one line, laid out; without shfmt, its first.
                (should (equal (substring-no-properties (aref (cadr (cadr rows)) 7))
                               (if (executable-find vigil-command-shfmt)
                                   "make test; and more"
                                 "make test")))
                (should (equal (car (gethash "2.0-2" vigil-running--runs))
                               (cl-find "2.0-2" (cooked-runs "a.1")
                                        :key (lambda (run) (plist-get run :id))
                                        :test #'equal)))))
            ;; `c': the command whole, from the run where no call is known.
            (with-temp-buffer
              (vigil-running-mode)
              (tabulated-list-print)
              (goto-char (point-min))
              (search-forward "make test")
              (cl-letf (((symbol-function 'cooked-popup-buffer) #'identity))
                (with-current-buffer (vigil-running-command)
                  (should (derived-mode-p 'vigil-view-mode))
                  (should (string-prefix-p "$ make test\n" (buffer-string))))))
            ;; `f': the files it has been seen to have open; none, here.
            (with-temp-buffer
              (vigil-running-mode)
              (tabulated-list-print)
              (goto-char (point-min))
              (search-forward "make test")
              (cl-letf (((symbol-function 'cooked-popup-buffer) #'identity))
                (with-current-buffer (vigil-running-files)
                  (should (derived-mode-p 'vigil-view-mode))
                  (should (string-match-p "\\`\\$ make test.*\n# The files it" (buffer-string)))
                  (should (string-match-p "no file of its own open\\|lsof is not installed"
                                          (buffer-string)))
                  ;; `g' looks again.
                  (revert-buffer)
                  (should (string-match-p "\\`\\$ make test" (buffer-string))))))
            ;; Watching only: no key in the list signals anything.
            (with-temp-buffer
              (vigil-running-mode)
              (should-not (where-is-internal #'cooked-run-interrupt (current-local-map))))))
      (delete-directory cooked-run-directory t))))

(ert-deftest vigil-running-reads-what-lsof-says-is-open ()
  "Regular files open on a descriptor, for reading or for writing: not a
program's own text, its directory, a pipe or a terminal."
  (should (equal (vigil-running--parse-lsof
                  (concat "p100\nfcwd\na \ntDIR\nn/tmp/proj\n"
                          "ftxt\na \ntREG\nn/usr/bin/fsr\n"
                          "f0\nau\ntCHR\nn/dev/ttys001\n"
                          "f3\nar\ntREG\nn/data/001.mgz\n"
                          "f4\naw\ntREG\nn/tmp/out/a.log\n"
                          "f5\na \ntPIPE\nn->0xabc\n"
                          "p101\nf6\nau\ntREG\nn/tmp/out/b.db\n"))
                 '((100 read "/data/001.mgz")
                   (100 write "/tmp/out/a.log")
                   (101 write "/tmp/out/b.db")))))

(ert-deftest vigil-running-keeps-the-files-a-command-had-open ()
  "Each look adds what the command and the processes under it have open to
what was seen before: a file since closed stays, one once written stays
written, the system's own are left out, and a run that is gone is let go."
  (let* ((vigil-running--files (make-hash-table :test #'equal))
         (vigil-running--looks (make-hash-table :test #'equal))
         (processes (vigil-running-tests--table
                     '(100 1 "bash -c run.sh") '(101 100 "/usr/bin/fsr recon")
                     '(200 1 "bash -c other") '(300 1 "unrelated")))
         (children (vigil-running--children processes))
         (run (list :id "r1" :pid 100 :label "run.sh"))
         (other (list :id "r2" :pid 200 :label "other"))
         (open nil) (asked nil))
    (cl-letf (((symbol-function 'vigil-running--lsof)
               (lambda (pids) (setq asked (sort (copy-sequence pids) #'<)) open))
              ((symbol-function 'executable-find) (lambda (&rest _) "/usr/sbin/lsof"))
              ((symbol-function 'cooked-run--directory) (lambda () "/nowhere/runs/")))
      (setq open '((101 read "/data/001.mgz") (101 read "/tmp/out/a.log")
                   (101 read "/usr/lib/libz.dylib") (101 read "/dev/null")
                   (200 write "/tmp/other.log") (300 write "/tmp/unrelated")))
      (vigil-running--look (list run other) processes children)
      ;; One lsof, of both commands' processes and no others.
      (should (equal asked '(100 101 200)))
      (should (equal (mapcar #'car (vigil-running--files-of "r1"))
                     '("/data/001.mgz" "/tmp/out/a.log")))
      (should (equal (mapcar #'car (vigil-running--files-of "r2")) '("/tmp/other.log")))
      (should (equal (plist-get (cdr (assoc "/data/001.mgz" (vigil-running--files-of "r1")))
                                :by)
                     "fsr"))
      ;; Later: the input is closed, the log is written, a new one is open.
      (setq open '((101 write "/tmp/out/a.log") (101 write "/tmp/out/b.log")))
      (vigil-running--look (list run) processes children)
      (let ((files (vigil-running--files-of "r1")))
        (should (equal (mapcar (lambda (file) (cons (car file) (plist-get (cdr file) :mode)))
                               files)
                       '(("/data/001.mgz" . read) ("/tmp/out/a.log" . write)
                         ("/tmp/out/b.log" . write))))
        (should (< (plist-get (cdr (car files)) :last)
                   (plist-get (cdr (cadr files)) :last))))
      (should (= (gethash "r1" vigil-running--looks) 2))
      ;; The other is no longer running.
      (should-not (vigil-running--files-of "r2"))
      ;; Shown: what is written, then what is read.
      (with-temp-buffer
        (vigil-running--insert-files run)
        (should (string-match-p
                 "looked at 2 times.*\n.*\n\nWriting (2)\n. /tmp/out/a\\.log.*\n. /tmp/out/b\\.log.*\n\nReading (1)\n. /data/001\\.mgz"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest vigil-running-says-what-a-script-is-for ()
  "Where the agent gave no reason, the last script the command names gives
its own: the comment it begins with."
  (skip-unless (executable-find vigil-command-shfmt))
  (let* ((home (file-name-as-directory (make-temp-file "vigil-scripts" t)))
         (vigil-command--scripts-of (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "heavy.sh" home)
            (insert "#!/usr/bin/env bash\n# Run a heavy command under a limit.\nexec \"$@\"\n"))
          (with-temp-file (expand-file-name "run.sh" home)
            (insert "#!/bin/zsh\n# usage: run.sh <before|after>: every config.\n# More.\necho hi\n"))
          (should (equal (vigil-running--reason
                          (list :label "./heavy.sh run.sh after 2>&1 | tail -20" :cwd home)
                          nil)
                         "usage: run.sh <before|after>: every config."))
          (should (equal (vigil-running--reason (list :label "ls -la" :cwd home) nil) "")))
      (delete-directory home t))))

;;; vigil-running-tests.el ends here
