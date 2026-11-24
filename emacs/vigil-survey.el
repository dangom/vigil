;;; vigil-survey.el --- An agent's objectives and subagents, without its buffer -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Keywords: tools, processes

;;; Commentary:

;; vigil.el reads an agent's reports into the buffer attached to it.  A list
;; of every agent that runs wants less, of agents that may have no buffer:
;; what each is set on, and which subagents it has out.  This reads a
;; session's reports by the session's name and keeps only that:
;;
;;   (vigil-survey-objective "coterie.proj.1")  what it is working on now,
;;                                              of the list it keeps, if it
;;                                              keeps one
;;   (vigil-survey-objectives "coterie.proj.1") the whole list
;;   (vigil-survey-subagents "coterie.proj.1")  its subagents: what each was
;;                                              asked, how it is going
;;   (vigil-survey-turns "coterie.proj.1" 2)    its last two turns, step by
;;                                              step (vigil-graph.el)
;;
;; A report is read once: what was read is kept by session, and a later
;; question reads only the files that are new.  A conversation begun afresh
;; under the same name starts the record afresh, as it does the reports.
;;
;; It is made to be asked from a list that must draw whatever happens:
;; nothing here signals.  A report that cannot be read, or says something
;; unexpected, is passed over; a session with no reports has no objectives
;; and no subagents.  And it only reads: nothing here writes, or sends
;; anything to an agent.
;;
;; It needs nothing of vigil.el, and so nothing of cooked.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'vigil-base)
(require 'vigil-pi)

(defvar vigil-directory)

(cl-defstruct (vigil-survey-step (:constructor vigil-survey-step--make) (:copier nil))
  "One thing that happened in a session: a prompt, a call, a reply."
  id time end
  (kind nil :documentation
        "`session', `prompt', `reply', or for a call `command', `edit',
`read', `web', `subagent' or `other'.")
  name
  (text nil :documentation "A prompt's or a reply's text; a call's summary.")
  (status nil :documentation "A call's: `running', `done' or `failed'.")
  (agent nil :documentation "The id of the subagent it happened in, if any.")
  (asked nil :documentation "For a call launching a subagent: what was asked.")
  (type nil :documentation "For a call launching a subagent: of what type.")
  (launched nil :documentation "For such a call: the subagent's id, once told.")
  (background nil :documentation "For such a call: whether it did not wait."))

(cl-defstruct (vigil-survey--subagent (:constructor vigil-survey--subagent-make)
                                      (:copier nil))
  id type start end result
  (count 0 :documentation "How many calls it has made.")
  (last nil :documentation "The last call it made.")
  (launch nil :documentation "The call that launched it, once told."))

(cl-defstruct (vigil-survey--state (:constructor vigil-survey--state-make)
                                   (:copier nil))
  (seen (make-hash-table :test #'equal))
  (steps nil :documentation "Every step, newest first.")
  (calls (make-hash-table :test #'equal))
  (subagents (make-hash-table :test #'equal))
  (order nil :documentation "The subagents' ids, newest first.")
  (todos nil :documentation "The list TodoWrite last gave: plists.")
  (tasks nil :documentation "The tasks made one by one, oldest first: plists.")
  (aliases (make-hash-table :test #'equal))
  (source nil :documentation "Which of the two was touched last: `todos' or `tasks'."))

(defvar vigil-survey--sessions (make-hash-table :test #'equal)
  "What was read of each session, by its name.")

(defun vigil-survey-forget (&optional session)
  "Let go of what was read of SESSION, or of every session."
  (if session
      (remhash session vigil-survey--sessions)
    (clrhash vigil-survey--sessions)))

;;;; Reading

(defun vigil-survey--root ()
  "Where every session's reports are: a directory for each, named for it."
  (or (bound-and-true-p vigil-directory)
      (vigil-base-data-directory "records")))

(defun vigil-survey--directory (session)
  "Where SESSION's reports are, or nil if SESSION names no such place."
  (when (and (stringp session)
             (not (string-empty-p session))
             (not (string-match-p "/" session))
             (not (member session '("." ".."))))
    (expand-file-name session (vigil-survey--root))))

(defun vigil-survey--string (value)
  "VALUE if it is a string with something in it."
  (and (stringp value) (not (string-empty-p value)) value))

(defun vigil-survey--line (text &optional limit)
  "The first line of TEXT with something on it, at most LIMIT letters; or nil."
  (when (stringp text)
    (let ((line (car (split-string (string-trim text) "[\n\r]+" t "[ \t]+"))))
      (when (and line (not (string-empty-p line)))
        (if (and limit (> (length line) limit))
            (concat (substring line 0 (max 0 (1- limit))) "…")
          line)))))

(defun vigil-survey--kind (name)
  "What kind of call one of the tool NAME is."
  (cond ((member name '("Bash" "BashOutput" "KillShell" "bash")) 'command)
        ((member name '("Edit" "Write" "MultiEdit" "NotebookEdit")) 'edit)
        ((member name '("Read" "Grep" "Glob" "LS" "NotebookRead")) 'read)
        ((member name '("WebFetch" "WebSearch")) 'web)
        ((member name '("Agent" "Task")) 'subagent)
        (t 'other)))

(defun vigil-survey--summary (input)
  "What a call with INPUT was about, in a line."
  (when (consp input)
    (or (vigil-survey--line (alist-get 'description input) 120)
        (vigil-survey--line (alist-get 'command input) 120)
        (let ((path (or (alist-get 'file_path input) (alist-get 'notebook_path input))))
          (and (vigil-survey--string path) (file-name-nondirectory path)))
        (vigil-survey--line (alist-get 'pattern input) 120)
        (vigil-survey--line (alist-get 'url input) 120)
        (vigil-survey--line (alist-get 'query input) 120)
        (vigil-survey--line (alist-get 'subject input) 120)
        (vigil-survey--line (alist-get 'prompt input) 120))))

(defun vigil-survey--failed-p (response)
  "Whether RESPONSE, what a call gave back, says that it failed."
  (and (consp response)
       (or (alist-get 'interrupted response)
           (alist-get 'is_error response)
           (let ((code (alist-get 'exit_code response)))
             (and (numberp code) (/= code 0))))))

(defun vigil-survey--subagent (state id time)
  "The subagent ID of STATE, made if this, at TIME, is the first heard of it."
  (or (gethash id (vigil-survey--state-subagents state))
      (let ((subagent (vigil-survey--subagent-make :id id :start time)))
        (push id (vigil-survey--state-order state))
        (puthash id subagent (vigil-survey--state-subagents state)))))

(defun vigil-survey--step (state &rest slots)
  "A new step of STATE with SLOTS, the newest."
  (let ((step (apply #'vigil-survey-step--make slots)))
    (push step (vigil-survey--state-steps state))
    step))

(defun vigil-survey--begin (state)
  "Start STATE's record afresh: a new conversation has begun."
  (setf (vigil-survey--state-steps state) nil
        (vigil-survey--state-order state) nil
        (vigil-survey--state-todos state) nil
        (vigil-survey--state-tasks state) nil
        (vigil-survey--state-source state) nil)
  (clrhash (vigil-survey--state-calls state))
  (clrhash (vigil-survey--state-subagents state))
  (clrhash (vigil-survey--state-aliases state)))

(defun vigil-survey--take-todos (state input)
  "Keep the list a TodoWrite with INPUT gave, in STATE."
  (let ((todos (alist-get 'todos input)))
    (when (listp todos)
      (setf (vigil-survey--state-todos state)
            (delq nil
                  (mapcar (lambda (todo)
                            (when-let* (((consp todo))
                                        (text (or (vigil-survey--line (alist-get 'content todo) 200)
                                                  (vigil-survey--line (alist-get 'subject todo) 200))))
                              (list :text text
                                    :status (or (vigil-survey--string (alist-get 'status todo))
                                                "pending"))))
                          todos))
            (vigil-survey--state-source state) 'todos))))

(defun vigil-survey--task (state key)
  "The task of STATE that KEY names: its call, its id, or its place in the list."
  (let* ((tasks (vigil-survey--state-tasks state))
         (called (lambda (call)
                   (cl-find call tasks :key (lambda (task) (plist-get task :key))
                            :test #'equal)))
         (alias (gethash key (vigil-survey--state-aliases state))))
    (cond ((funcall called key))
          ;; An id known for one task is that task or nothing: once it is
          ;; deleted, its number is not whatever now stands in its place.
          (alias (funcall called alias))
          ((and (stringp key) (string-match-p "\\`[0-9]+\\'" key))
           (nth (1- (string-to-number key)) tasks)))))

(defun vigil-survey--id (value)
  "VALUE, a task's id as a report gives it, as a string; or nil."
  (cond ((vigil-survey--string value) value)
        ((integerp value) (number-to-string value))))

(defun vigil-survey--take-task (state name call input response)
  "Keep what the task tool NAME did in STATE.
CALL is its call's id, INPUT what it was given, RESPONSE what it gave back."
  (pcase name
    ("TaskCreate"
     (when-let* ((text (or (vigil-survey--line (alist-get 'subject input) 200)
                           (vigil-survey--line (alist-get 'description input) 200))))
       (unless (vigil-survey--task state call)
         (setf (vigil-survey--state-tasks state)
               (append (vigil-survey--state-tasks state)
                       (list (list :key call :text text :status "pending")))))
       (when-let* (((consp response))
                   (id (vigil-survey--id
                        (or (let ((task (alist-get 'task response)))
                              (and (consp task) (alist-get 'id task)))
                            (alist-get 'id response)
                            (alist-get 'taskId response)))))
         (puthash id call (vigil-survey--state-aliases state)))
       (setf (vigil-survey--state-source state) 'tasks)))
    ("TaskUpdate"
     (when-let* ((id (vigil-survey--id (or (alist-get 'taskId input) (alist-get 'id input))))
                 (task (vigil-survey--task state id)))
       (let ((status (vigil-survey--string (alist-get 'status input)))
             (text (vigil-survey--line (alist-get 'subject input) 200)))
         (if (equal status "deleted")
             (setf (vigil-survey--state-tasks state)
                   (delq task (vigil-survey--state-tasks state)))
           ;; In place: the list holds this very plist.
           (when status (plist-put task :status status))
           (when text (plist-put task :text text))))
       (setf (vigil-survey--state-source state) 'tasks)))))

(defun vigil-survey--take-call (state report event time name)
  "Read REPORT, the tool call EVENT at TIME, into STATE.
NAME, the report's file, names a call whose report gives it no id."
  (let* ((id (or (vigil-survey--string (alist-get 'tool_use_id report)) name))
         (tool (or (vigil-survey--string (alist-get 'tool_name report)) "?"))
         (input (alist-get 'tool_input report))
         (response (alist-get 'tool_response report))
         (agent (vigil-survey--string (alist-get 'agent_id report)))
         (calls (vigil-survey--state-calls state))
         (new (not (gethash id calls)))
         (step (or (gethash id calls)
                   (puthash id (vigil-survey--step state :id id :time time
                                                   :status 'running :agent agent)
                            calls))))
    (setf (vigil-survey-step-name step) tool
          (vigil-survey-step-kind step) (vigil-survey--kind tool)
          (vigil-survey-step-text step) (or (vigil-survey--summary input)
                                            (vigil-survey-step-text step)))
    (when (eq (vigil-survey-step-kind step) 'subagent)
      (when (consp input)
        (setf (vigil-survey-step-asked step)
              (or (vigil-survey--line (alist-get 'description input) 120)
                  (vigil-survey--line (alist-get 'prompt input) 120)
                  (vigil-survey-step-asked step))
              (vigil-survey-step-type step)
              (or (vigil-survey--string (alist-get 'subagent_type input))
                  (vigil-survey-step-type step)))))
    (when agent
      (let ((subagent (vigil-survey--subagent state agent time)))
        (setf (vigil-survey--subagent-type subagent)
              (or (vigil-survey--subagent-type subagent)
                  (vigil-survey--string (alist-get 'agent_type report)))
              (vigil-survey--subagent-last subagent) step)
        (when new (cl-incf (vigil-survey--subagent-count subagent)))))
    (when (and (not agent) (consp input))
      (cond ((equal tool "TodoWrite") (vigil-survey--take-todos state input))
            ((member tool '("TaskCreate" "TaskUpdate"))
             (vigil-survey--take-task state tool id input
                                      (and (equal event "PostToolUse") response)))))
    (when (equal event "PostToolUse")
      (setf (vigil-survey-step-end step) time
            (vigil-survey-step-status step)
            (if (vigil-survey--failed-p response) 'failed 'done))
      (when (and (eq (vigil-survey-step-kind step) 'subagent) (consp response))
        (when (equal (alist-get 'status response) "async_launched")
          (setf (vigil-survey-step-background step) t))
        (when-let* ((launched (vigil-survey--string (alist-get 'agentId response))))
          (setf (vigil-survey-step-launched step) launched)
          (let ((subagent (vigil-survey--subagent state launched time)))
            (setf (vigil-survey--subagent-launch subagent) step
                  (vigil-survey--subagent-type subagent)
                  (or (vigil-survey--subagent-type subagent)
                      (vigil-survey-step-type step)))))))))

(defun vigil-survey--take (state report time name)
  "Read REPORT, written at TIME to the file NAME, into STATE."
  (let* ((report (if (equal (alist-get 'agent report) "pi")
                     (or (ignore-errors (vigil-pi-report report)) report)
                   report))
         (event (alist-get 'hook_event_name report))
         (agent (vigil-survey--string (alist-get 'agent_id report))))
    (cond
     ((not (stringp event)))
     ((equal event "SessionStart")
      (unless agent
        (when (equal (alist-get 'source report) "startup")
          (vigil-survey--begin state))
        (vigil-survey--step state :id name :time time :kind 'session
                            :text (vigil-survey--string (alist-get 'source report)))))
     ((equal event "UserPromptSubmit")
      (unless agent
        (vigil-survey--step state :id name :time time :kind 'prompt
                            :text (vigil-survey--string (alist-get 'prompt report)))))
     ((equal event "Stop")
      (unless agent
        (vigil-survey--step state :id name :time time :kind 'reply
                            :text (vigil-survey--string
                                   (alist-get 'last_assistant_message report)))))
     ((member event '("SubagentStart" "SubagentStop"))
      (when agent
        (let ((subagent (vigil-survey--subagent state agent time)))
          (setf (vigil-survey--subagent-type subagent)
                (or (vigil-survey--string (alist-get 'agent_type report))
                    (vigil-survey--subagent-type subagent)))
          (if (equal event "SubagentStart")
              (setf (vigil-survey--subagent-start subagent)
                    (min time (or (vigil-survey--subagent-start subagent) time)))
            (setf (vigil-survey--subagent-end subagent) time
                  (vigil-survey--subagent-result subagent)
                  (vigil-survey--string (alist-get 'last_assistant_message report)))))))
     ((member event '("PreToolUse" "PostToolUse"))
      (vigil-survey--take-call state report event time name)))))

(defun vigil-survey--state (session)
  "What SESSION's reports say, the ones written since last asked read first.
Nil if SESSION names no place for reports.  Never signals."
  (when-let* ((directory (vigil-survey--directory session)))
    (let ((state (or (gethash session vigil-survey--sessions)
                     (puthash session (vigil-survey--state-make)
                              vigil-survey--sessions))))
      (ignore-errors
        (let* ((seen (vigil-survey--state-seen state))
               (present (make-hash-table :test #'equal))
               new)
          (dolist (entry (and (file-directory-p directory)
                              (directory-files-and-attributes directory t "\\.json\\'" t)))
            (let ((file (car entry)))
              (puthash file t present)
              (unless (gethash file seen)
                (push (cons (vigil-base-report-time file (cdr entry)) file) new))))
          ;; Files that are gone were pruned or cleared: no need to know them.
          (maphash (lambda (file _) (unless (gethash file present) (remhash file seen)))
                   seen)
          (dolist (item (sort new (lambda (a b)
                                    (or (< (car a) (car b))
                                        (and (= (car a) (car b))
                                             (string< (cdr a) (cdr b)))))))
            (puthash (cdr item) t seen)
            ;; One report that cannot be taken costs that report, no more.
            (ignore-errors
              (when-let* ((report (vigil-base-json-file (cdr item))))
                (vigil-survey--take state report (car item)
                                    (file-name-nondirectory (cdr item))))))))
      state)))

;;;; What is asked of it

(defun vigil-survey-objectives (session)
  "The list SESSION's agent keeps of what it is to do, in its order.
Each a plist: :text, and :status, one of \"pending\", \"in_progress\" and
\"completed\".  Nil if it keeps none."
  (when-let* ((state (vigil-survey--state session)))
    (mapcar (lambda (item)
              (list :text (plist-get item :text) :status (plist-get item :status)))
            (if (eq (vigil-survey--state-source state) 'tasks)
                (vigil-survey--state-tasks state)
              (vigil-survey--state-todos state)))))

(defun vigil-survey-objective (session)
  "What SESSION's agent is working on now, of the list it keeps.
A plist: :text, the item in progress or else the first not yet begun;
:done, how many are completed; :total, how many there are.  Nil if it
keeps no list, or has done everything on it."
  (when-let* ((items (vigil-survey-objectives session)))
    (let ((status (lambda (item) (plist-get item :status))))
      (when-let* ((now (or (cl-find "in_progress" items :key status :test #'equal)
                           (cl-find "pending" items :key status :test #'equal))))
        (list :text (plist-get now :text)
              :done (cl-count "completed" items :key status :test #'equal)
              :total (length items))))))

(defun vigil-survey--main-after-p (state time)
  "Whether STATE's own agent was prompted, or done with a turn, after TIME."
  (cl-some (lambda (step)
             (and (memq (vigil-survey-step-kind step) '(prompt reply session))
                  (> (vigil-survey-step-time step) time)))
           (vigil-survey--state-steps state)))

(defun vigil-survey--guess-launches (state)
  "For STATE's subagents not yet told their launching calls, the likeliest.
A subagent that is waited for is only tied to the call that launched it once
it is done: until then, the oldest such call of its type still unanswered.
An alist of subagent ids and steps."
  (let ((waiting (cl-remove-if-not
                  (lambda (step)
                    (and (eq (vigil-survey-step-kind step) 'subagent)
                         (eq (vigil-survey-step-status step) 'running)
                         (not (vigil-survey-step-launched step))))
                  (reverse (vigil-survey--state-steps state))))
        guesses)
    (dolist (id (reverse (vigil-survey--state-order state)))
      (let ((subagent (gethash id (vigil-survey--state-subagents state))))
        (unless (or (vigil-survey--subagent-launch subagent)
                    (vigil-survey--subagent-end subagent))
          (when-let* ((step (cl-find-if
                             (lambda (step)
                               (and (<= (vigil-survey-step-time step)
                                        (+ 1 (vigil-survey--subagent-start subagent)))
                                    (or (null (vigil-survey-step-type step))
                                        (null (vigil-survey--subagent-type subagent))
                                        (equal (vigil-survey-step-type step)
                                               (vigil-survey--subagent-type subagent)))))
                             waiting)))
            (setq waiting (delq step waiting))
            (push (cons id step) guesses)))))
    guesses))

(defun vigil-survey-subagents (session)
  "SESSION's subagents, oldest first, each a plist:

:id           its id
:type         what kind it is (\"Explore\"), if told
:asked        what it was asked, in a line, if known
:status       `running', `done', `failed' or `interrupted'
:background   whether its agent did not wait for it
:start :end   when, as seconds since the epoch; :end nil while it runs
:calls        how many calls it has made
:doing        what its last call is about, while it runs
:result       the first line of what it reported, once done

A subagent its agent waited for, and then went on without -- a prompt or a
reply came after it began, and it never said it was done -- is taken for
interrupted rather than left running for good."
  (when-let* ((state (vigil-survey--state session)))
    (ignore-errors
      (let ((guesses (vigil-survey--guess-launches state)))
        (mapcar
         (lambda (id)
           (let* ((subagent (gethash id (vigil-survey--state-subagents state)))
                  (told (vigil-survey--subagent-launch subagent))
                  (launch (or told (cdr (assoc id guesses))))
                  (background (and told (vigil-survey-step-background told)))
                  (start (or (vigil-survey--subagent-start subagent) 0))
                  (end (or (vigil-survey--subagent-end subagent)
                           ;; Waited for and answered: it is done.
                           (and told (not background) (vigil-survey-step-end told))))
                  (status (cond ((and told (not background)
                                      (eq (vigil-survey-step-status told) 'failed))
                                 'failed)
                                (end 'done)
                                ((and (not background)
                                      (vigil-survey--main-after-p state start))
                                 'interrupted)
                                (t 'running)))
                  (last (vigil-survey--subagent-last subagent)))
             (list :id id
                   :type (or (vigil-survey--subagent-type subagent)
                             (and launch (vigil-survey-step-type launch)))
                   :asked (and launch (vigil-survey-step-asked launch))
                   :status status
                   :background (and background t)
                   :start start
                   :end end
                   :calls (vigil-survey--subagent-count subagent)
                   :doing (and (eq status 'running) last
                               (string-join
                                (delq nil (list (vigil-survey-step-name last)
                                                (vigil-survey-step-text last)))
                                " "))
                   :result (vigil-survey--line
                            (vigil-survey--subagent-result subagent) 160))))
         (reverse (vigil-survey--state-order state)))))))

(defun vigil-survey-turns (session &optional count)
  "SESSION's last COUNT turns, default all, oldest first.
Each a list of `vigil-survey-step', oldest first: the prompt that began it,
if it was read, then what followed up to the next prompt."
  (when-let* ((state (vigil-survey--state session)))
    (let (turns turn)
      ;; Newest first: a prompt closes the turn gathered so far.
      (dolist (step (vigil-survey--state-steps state))
        (push step turn)
        (when (eq (vigil-survey-step-kind step) 'prompt)
          (push turn turns)
          (setq turn nil)))
      (when turn (push turn turns))
      (if (and (integerp count) (> count 0))
          (last turns count)
        turns))))

(defun vigil-survey-launch (session step)
  "The call that launched the subagent STEP of SESSION happened in, or nil.
As told by its report, or guessed while it is still waited for."
  (when-let* ((agent (vigil-survey-step-agent step))
              (state (vigil-survey--state session)))
    (ignore-errors
      (or (when-let* ((subagent (gethash agent (vigil-survey--state-subagents state))))
            (vigil-survey--subagent-launch subagent))
          (cdr (assoc agent (vigil-survey--guess-launches state)))))))

(defun vigil-survey-sessions ()
  "The names of the sessions that have reports."
  (when-let* ((directory (vigil-survey--root))
              ((file-directory-p directory)))
    (ignore-errors
      (cl-remove-if-not
       (lambda (name) (file-directory-p (expand-file-name name directory)))
       (directory-files directory nil "\\`[^.]")))))

(provide 'vigil-survey)
;;; vigil-survey.el ends here
