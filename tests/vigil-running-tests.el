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
  "A process table, as `vigil-running--processes' gives one, of ROWS (PID PPID ARGS)."
  (let ((table (make-hash-table)))
    (dolist (row rows) (puthash (car row) (cons (nth 1 row) (nth 2 row)) table))
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
                                 (list (emacs-pid) 1 "emacs")
                                 '(99999 1 "unrelated")))))
            (with-temp-buffer
              (vigil-running-mode)
              (let ((rows (vigil-running--entries)))
                (should (equal (mapcar #'car rows) '("3.0-3" "2.0-2")))
                (should (equal (aref (cadr (car rows)) 0) "b.1"))
                (should (equal (aref (cadr (car rows)) 2) "10m00s"))
                ;; A command on one line, laid out; without shfmt, its first.
                (should (equal (substring-no-properties (aref (cadr (cadr rows)) 4))
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
            ;; Watching only: no key in the list signals anything.
            (with-temp-buffer
              (vigil-running-mode)
              (should-not (where-is-internal #'cooked-run-interrupt (current-local-map))))))
      (delete-directory cooked-run-directory t))))

;;; vigil-running-tests.el ends here
