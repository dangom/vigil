;;; vigil-graph.el --- A session's turns as a graph on a canvas -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; `M-x vigil-graph': what an agent did in its last turns, as cards joined
;; in the order they happened, on a canvas of its own (canvacs).  A prompt,
;; then each call, then the reply; a subagent's calls branch off the call
;; that launched it.  Calls that only looked -- a run of reads and searches
;; one after another -- share a card.
;;
;; Every kind has one colour, here and wherever else vigil's kinds are
;; shown (`vigil-graph-colours'):
;;
;;   prompt     cyan       what was asked
;;   reply      purple     what was answered
;;   command    orange     a shell command
;;   edit       green      a file written or changed
;;   subagent   yellow     a subagent launched
;;   failed     red        any call that failed, whatever its kind
;;   the rest   plain      reads, searches, the web, other tools
;;
;; The canvas is thrown away: it belongs to no file, is made anew each time
;; it is asked for, and nothing is saved.  `vigil-graph-data' is the graph
;; itself, a JSON Canvas document with no places, for whoever wants it
;; without a canvas.
;;
;; It reads through vigil-survey.el, so it needs no agent's buffer, and
;; only reads.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vigil-survey)

(declare-function canvacs-mode "canvacs")
(declare-function canvacs-graph-add "canvacs-graph")
(defvar cooked-host-name)

(defcustom vigil-graph-colours
  '((prompt . "5") (reply . "6") (command . "2") (edit . "4")
    (subagent . "3") (failed . "1"))
  "The colour of each kind of step: a JSON Canvas colour, \"1\" to \"6\" or
a hex colour.  A kind not named is left plain."
  :type '(alist :key-type symbol :value-type string)
  :group 'vigil)

(defcustom vigil-graph-turns 1
  "How many of a session's last turns `vigil-graph' shows when not told."
  :type 'integer
  :group 'vigil)

(defconst vigil-graph--shared-lines 8
  "How many calls a card shared by several lists before it only counts them.")

(defun vigil-graph--quiet-p (step)
  "Whether STEP only looked, and went well: one to share a card."
  (and (eq (vigil-survey-step-kind step) 'read)
       (eq (vigil-survey-step-status step) 'done)))

(defun vigil-graph--text (steps)
  "What the card of STEPS, one step or a run sharing it, says."
  (let ((step (car steps)))
    (if (cdr steps)
        (let ((shown (seq-take steps vigil-graph--shared-lines)))
          (concat (format "Looked ×%d\n" (length steps))
                  (mapconcat (lambda (s)
                               (vigil-base-one-line
                                (format "%s %s" (or (vigil-survey-step-name s) "?")
                                        (or (vigil-survey-step-text s) ""))
                                60))
                             shown "\n")
                  (if (> (length steps) (length shown))
                      (format "\n… and %d more" (- (length steps) (length shown)))
                    "")))
      (pcase (vigil-survey-step-kind step)
        ('prompt (concat "Prompt\n" (vigil-base-one-line (vigil-survey-step-text step) 280)))
        ('reply (concat "Reply\n" (vigil-base-one-line (vigil-survey-step-text step) 280)))
        ('session (concat "Session\n" (or (vigil-survey-step-text step) "")))
        ('subagent
         (format "%s · %s\n%s"
                 (or (vigil-survey-step-type step) "Subagent")
                 (cond ((vigil-survey-step-background step) "in the background")
                       (t (symbol-name (or (vigil-survey-step-status step) 'running))))
                 (vigil-base-one-line (or (vigil-survey-step-asked step)
                                        (vigil-survey-step-text step))
                                    200)))
        (_ (format "%s · %s\n%s"
                   (or (vigil-survey-step-name step) "?")
                   (symbol-name (or (vigil-survey-step-status step) 'running))
                   (vigil-base-one-line (vigil-survey-step-text step) 200)))))))

(defun vigil-graph--colour (steps)
  "The colour of the card of STEPS, or nil for a plain one."
  (let ((step (car steps)))
    (cdr (assq (if (and (null (cdr steps))
                        (eq (vigil-survey-step-status step) 'failed))
                   'failed
                 (vigil-survey-step-kind step))
               vigil-graph-colours))))

(defun vigil-graph-data (session &optional turns)
  "SESSION's last TURNS turns as a graph: a JSON Canvas document, no places.
An alist of `nodes' and `edges', as `canvacs-graph-add' takes one.  TURNS
defaults to `vigil-graph-turns'; all of them, if it is not a number above 0.
Nil if SESSION has nothing to show."
  (let* ((turns (vigil-survey-turns session (or turns vigil-graph-turns)))
         (count 0)
         (cards nil)                    ; (ID . STEPS), newest first
         (edges nil)
         (card-of (make-hash-table :test #'eq)) ; a step's card's id
         (last-of (make-hash-table :test #'equal))) ; a line's last card: (ID . STEPS)
    (dolist (step (apply #'append turns))
      (let* ((line (or (vigil-survey-step-agent step) 'main))
             (last (gethash line last-of)))
        (if (and last
                 (vigil-graph--quiet-p step)
                 (vigil-graph--quiet-p (cadr last)))
            ;; One more on the card of those that only looked.
            (progn (setcdr last (append (cdr last) (list step)))
                   (puthash step (car last) card-of))
          (let* ((id (format "s%d" (cl-incf count)))
                 (card (list id step))
                 ;; A subagent's first card hangs off the call that launched
                 ;; it, if that is among the cards; else off nothing.
                 (from (cond (last (car last))
                             ((eq line 'main) nil)
                             (t (when-let* ((launch (vigil-survey-launch session step)))
                                  (gethash launch card-of))))))
            (push card cards)
            (puthash step id card-of)
            (puthash line card last-of)
            (when from
              (push `((id . ,(format "e%d" count)) (fromNode . ,from) (toNode . ,id))
                    edges))))))
    (when cards
      `((nodes . ,(mapcar (lambda (card)
                            (let ((colour (vigil-graph--colour (cdr card))))
                              `((id . ,(car card))
                                (type . "text")
                                (text . ,(vigil-graph--text (cdr card)))
                                ,@(and colour `((color . ,colour))))))
                          (nreverse cards)))
        (edges . ,(nreverse edges))))))

(defun vigil-graph--read-session ()
  "The session to graph: this buffer's, or one asked for."
  (or (and (boundp 'cooked-host-name) (stringp cooked-host-name) cooked-host-name)
      (let ((sessions (vigil-survey-sessions)))
        (unless sessions (user-error "vigil: no session has reported anything"))
        (completing-read "Graph the session: " sessions nil t))))

;;;###autoload
(defun vigil-graph (session &optional turns)
  "Show SESSION's last TURNS turns as a graph, on a canvas to throw away.
SESSION is this buffer's agent's, or asked for.  TURNS is the prefix
argument, default `vigil-graph-turns'; with \\[universal-argument] alone,
every turn there is a record of."
  (interactive
   (list (vigil-graph--read-session)
         (cond ((consp current-prefix-arg) 0)
               (current-prefix-arg (prefix-numeric-value current-prefix-arg)))))
  (unless (and (require 'canvacs nil t) (require 'canvacs-graph nil t))
    (user-error "vigil: the graph is drawn on a canvas, and canvacs is not installed"))
  (let ((graph (or (vigil-graph-data session turns)
                   (user-error "vigil: %s has reported nothing to draw" session)))
        (name (format "*vigil graph: %s*" session)))
    ;; Anew each time: the last one was to be thrown away.
    (when-let* ((old (get-buffer name)))
      (kill-buffer old))
    (let ((buffer (get-buffer-create name)))
      (condition-case err
          (with-current-buffer buffer
            (canvacs-mode)
            (canvacs-graph-add graph)
            (set-buffer-modified-p nil))
        (error (kill-buffer buffer)
               (signal (car err) (cdr err))))
      (pop-to-buffer buffer))))

(provide 'vigil-graph)
;;; vigil-graph.el ends here
