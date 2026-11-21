;;; vigil-graph-tests.el --- A session's turns as a graph -*- lexical-binding: t; -*-

;; The graph as data, from reports written as `vigil hook' writes them; and,
;; where canvacs is beside this repository (../freeemacsform) or on the
;; `load-path', that data laid out on a canvas's model.  The canvas's view
;; needs a window, and is not tried here.
;;
;;   emacs -Q --batch -L emacs -L ../freeemacsform -l tests/vigil-graph-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "vigil-survey-tests.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)
(require 'vigil-graph)

(defvar vigil-directory)

(defun vigil-graph-tests--session ()
  "Write a turn with a command that failed, three reads and a subagent."
  (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Old turn")))
  (vigil-survey-tests--write "s" '((hook_event_name . "Stop") (last_assistant_message . "Old reply")))
  (vigil-survey-tests--write "s" '((hook_event_name . "UserPromptSubmit") (prompt . "Fix it")))
  (dolist (id '("r1" "r2" "r3"))
    (vigil-survey-tests--write
     "s" (vigil-survey-tests--call "PostToolUse" "Read" id `((file_path . ,(concat "/src/" id ".el")))
                                   '(tool_response . ((ok . t))))))
  (vigil-survey-tests--write
   "s" (vigil-survey-tests--call "PostToolUse" "Bash" "b1" '((command . "make test"))
                                 '(tool_response . ((exit_code . 2)))))
  (vigil-survey-tests--write
   "s" (vigil-survey-tests--call "PreToolUse" "Agent" "launch"
                                 '((description . "Find the callers") (subagent_type . "Explore"))))
  (vigil-survey-tests--write
   "s" (vigil-survey-tests--call "PostToolUse" "Grep" "g1" '((pattern . "foo"))
                                 '(agent_id . "a1") '(tool_response . ((ok . t)))))
  (vigil-survey-tests--write
   "s" (vigil-survey-tests--call "PostToolUse" "Agent" "launch" '((description . "Find the callers"))
                                 '(tool_response . ((agentId . "a1") (status . "completed")))))
  (vigil-survey-tests--write
   "s" (vigil-survey-tests--call "PostToolUse" "Edit" "e1" '((file_path . "/src/a.el"))
                                 '(tool_response . ((ok . t)))))
  (vigil-survey-tests--write "s" '((hook_event_name . "Stop") (last_assistant_message . "Fixed."))))

(defun vigil-graph-tests--node (graph prefix)
  "The node of GRAPH whose text begins with PREFIX."
  (cl-find-if (lambda (node) (string-prefix-p prefix (alist-get 'text node)))
              (alist-get 'nodes graph)))

(defun vigil-graph-tests--joined-p (graph from to)
  "Whether GRAPH has an edge from the node FROM to the node TO."
  (cl-some (lambda (edge)
             (and (equal (alist-get 'fromNode edge) (alist-get 'id from))
                  (equal (alist-get 'toNode edge) (alist-get 'id to))))
           (alist-get 'edges graph)))

(ert-deftest vigil-graph-nothing-to-draw ()
  (vigil-survey-tests--with
    (should-not (vigil-graph-data "coterie.none.1"))
    (should-not (vigil-graph-data "../x"))))

(ert-deftest vigil-graph-last-turn ()
  "The last turn: a chain from prompt to reply, the subagent's calls off its launch."
  (vigil-survey-tests--with
    (vigil-graph-tests--session)
    (let* ((graph (vigil-graph-data "s" 1))
           (prompt (vigil-graph-tests--node graph "Prompt\nFix it"))
           (looked (vigil-graph-tests--node graph "Looked ×3"))
           (bash (vigil-graph-tests--node graph "Bash · failed"))
           (launch (vigil-graph-tests--node graph "Explore · done"))
           (grep (vigil-graph-tests--node graph "Grep · done"))
           (edit (vigil-graph-tests--node graph "Edit · done"))
           (reply (vigil-graph-tests--node graph "Reply\nFixed.")))
      ;; Seven cards: the three reads share one, the old turn is left out.
      (should (= 7 (length (alist-get 'nodes graph))))
      (should-not (vigil-graph-tests--node graph "Prompt\nOld turn"))
      (should (and prompt looked bash launch grep edit reply))
      (should (string-match-p "Read r2\\.el" (alist-get 'text looked)))
      (should (vigil-graph-tests--joined-p graph prompt looked))
      (should (vigil-graph-tests--joined-p graph looked bash))
      (should (vigil-graph-tests--joined-p graph bash launch))
      (should (vigil-graph-tests--joined-p graph launch grep))
      (should (vigil-graph-tests--joined-p graph launch edit))
      (should (vigil-graph-tests--joined-p graph edit reply))
      (should (= 6 (length (alist-get 'edges graph))))
      ;; One colour a kind; a failure is red whatever it is; a look is plain.
      (should (equal "5" (alist-get 'color prompt)))
      (should (equal "6" (alist-get 'color reply)))
      (should (equal "1" (alist-get 'color bash)))
      (should (equal "3" (alist-get 'color launch)))
      (should (equal "4" (alist-get 'color edit)))
      (should-not (alist-get 'color looked))
      ;; Ids are the graph's own, and no two alike.
      (let ((ids (mapcar (lambda (n) (alist-get 'id n)) (alist-get 'nodes graph))))
        (should (equal ids (delete-dups (copy-sequence ids))))))))

(ert-deftest vigil-graph-every-turn ()
  "All the turns: one chain, each reply joined to the next prompt."
  (vigil-survey-tests--with
    (vigil-graph-tests--session)
    (let ((graph (vigil-graph-data "s" 0)))
      (should (= 9 (length (alist-get 'nodes graph))))
      (should (vigil-graph-tests--joined-p
               graph
               (vigil-graph-tests--node graph "Reply\nOld reply")
               (vigil-graph-tests--node graph "Prompt\nFix it"))))))

(ert-deftest vigil-graph-on-a-canvas ()
  "The graph is one canvacs lays out and takes: every card placed, every edge kept."
  (skip-unless (and (require 'canvacs-model nil t) (require 'canvacs-graph nil t)))
  (vigil-survey-tests--with
    (vigil-graph-tests--session)
    (let ((graph (vigil-graph-data "s" 1)))
      (with-temp-buffer
        (canvacs-model-init)
        (let ((ids (canvacs-graph-add graph)))
          (should (= 7 (length ids)))
          (should (= 7 (length (canvacs-model-nodes))))
          (should (= 6 (length (canvacs-model-edges))))
          (dolist (node (canvacs-model-nodes))
            (should (numberp (alist-get 'x node)))
            (should (> (alist-get 'height node) 0))))))))

(provide 'vigil-graph-tests)
;;; vigil-graph-tests.el ends here
