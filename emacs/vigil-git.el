;;; vigil-git.el --- Asking git -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, vc

;;; Commentary:

;; What vigil-codebase.el, vigil-magit.el and vigil-snapshot.el ask of git,
;; asked one way: in a repository, for what it prints, and nil where it
;; fails.  Nothing here changes a repository.

;;; Code:

(require 'subr-x)

(defgroup vigil-git nil
  "Asking git."
  :group 'vigil)

(defcustom vigil-git-program "git"
  "The git to ask."
  :type 'string)

(defconst vigil-git--environment
  '("GIT_PAGER=cat" "LC_ALL=C" "GIT_OPTIONAL_LOCKS=0")
  "What git is told beside what it is asked: to print plainly, and to wait
for nobody's lock.")

(defun vigil-git (root &rest args)
  "What git prints for ARGS in ROOT, or nil if it fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root))
          (coding-system-for-read 'utf-8)
          (process-environment (append vigil-git--environment process-environment)))
      (and (eq 0 (ignore-errors
                   (apply #'call-process vigil-git-program nil '(t nil) nil
                          "-c" "core.quotepath=off" args)))
           (buffer-string)))))

(defun vigil-git-parse (root parse input &rest args)
  "What PARSE makes of what git prints for ARGS in ROOT, or nil if it fails.
Git is given INPUT on its standard input.  PARSE is called in the buffer
holding what git printed, as bytes, which is not made a string first: a
month of a large repository's changes is large."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when input (insert input))
    (let ((default-directory (file-name-as-directory root))
          (coding-system-for-read 'no-conversion)
          (coding-system-for-write 'utf-8)
          (process-environment (append vigil-git--environment process-environment)))
      (when (eq 0 (ignore-errors
                    (apply #'call-process-region (point-min) (point-max)
                           vigil-git-program t '(t nil) nil
                           "-c" "core.quotepath=off" args)))
        (funcall parse)))))

(defun vigil-git-root (&optional directory)
  "The top of the repository DIRECTORY is in, by default this buffer's."
  (let ((top (vigil-git (or directory default-directory) "rev-parse" "--show-toplevel")))
    (and top (not (string-empty-p (string-trim top)))
         (file-name-as-directory (string-trim top)))))

(provide 'vigil-git)
;;; vigil-git.el ends here
