;; -*- lexical-binding: t -*- An experimental implementation of
;; multiple REPLs multiplexed over a single Slime socket.  M-x
;; sly-mrepl or M-x sly-mrepl-new create new REPL buffers.
;;
(require 'sly)
(require 'cl-lib)

(define-sly-contrib sly-mrepl
  "Multiple REPLs."
  (:swank-dependencies swank-mrepl)
  (:on-load
   (define-key sly-inspector-mode-map (kbd "M-RET") 'sly-inspector-copy-down-to-repl)
   (define-key sldb-mode-map (kbd "M-RET") 'sldb-copy-down-to-repl)
   (define-key sly-mode-map (kbd "C-c ~") 'sly-mrepl-sync-package-and-default-directory)
   (add-hook 'sly-connected-hook 'sly-mrepl-connected-hook)
   (add-hook 'sly-net-process-close-hooks 'sly-mrepl-close-repls)
   ;; FIXME: ugly
   (add-hook 'sly-trace-dialog-mode-hook
             #'(lambda ()
                 (local-set-key (kbd "M-RET") 'sly-trace-dialog-copy-down-to-repl)))
   (setq sly-connection-list-button-action #'(lambda (process)
                                               (let ((sly-default-connection process))
                                                 (sly-mrepl 'interactive))))))

(require 'comint)

(defvar sly-mrepl-hook nil
  "Functions run after `sly-mrepl-new' sets up a REPL.")

(defvar sly-mrepl-runonce-hook nil
  "Functions run once after `sly-mrepl-new' sets up a REPL.

After running the contents of this hook it's default value is
emptied.See also `sly-mrepl-hook'")

(defvar sly-mrepl--remote-channel nil)
(defvar sly-mrepl--local-channel nil)
(defvar sly-mrepl--expect-sexp-mode t)
(defvar sly-mrepl--pending-requests nil)
(defvar sly-mrepl--result-counter -1)
(defvar sly-mrepl--output-mark nil)
(defvar sly-mrepl--dedicated-stream nil)

(defvar sly-mrepl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     'sly-mrepl-return)
    (define-key map [return]        'sly-mrepl-return)
    (define-key map (kbd "TAB")     'sly-indent-and-complete-symbol)
    (define-key map (kbd "C-c C-b") 'sly-interrupt)
    (define-key map (kbd "C-c C-c") 'sly-interrupt)
    map))

(define-derived-mode sly-mrepl-mode comint-mode "mrepl"
  (sly-mode)
  (cl-loop for (var value)
           in `((comint-use-prompt-regexp nil)
                (comint-inhibit-carriage-motion t)
                (comint-input-sender sly-mrepl--input-sender)
                (comint-output-filter-functions nil)
                (comint-input-filter-functions nil)
                (comint-history-isearch dwim)
                (comint-input-ring-file-name "~/.sly-mrepl-history")
                (comint-input-ignoredups t)
                (comint-input-ring-size  1500)
                (comint-prompt-read-only t)
                (indent-line-function lisp-indent-line)
                (sly-mrepl--expect-sexp-mode t)
                (sly-mrepl--result-counter -1)
                (sly-mrepl--output-mark ,(point-marker)))
           do (set (make-local-variable var) value))
  (set-marker-insertion-type sly-mrepl--output-mark nil)
  ;;(set (make-local-variable 'comint-get-old-input) 'ielm-get-old-input)
  (set-syntax-table lisp-mode-syntax-table))

(sly-define-channel-type listener)

(defun sly-mrepl-new ()
  "Create a new listener window."
  (interactive)
  (let* ((local (sly-make-channel sly-listener-channel-methods))
         ;; FIXME: Notice a subtle bug/feature than when invoking
         ;; sly-mrepl-new in a buffer which has a connection, but not
         ;; the default connection, the new REPL will be for that
         ;; connection.
         (connection (sly-connection))
         (buffer (pop-to-buffer (generate-new-buffer
                                 (format "*sly-mrepl %s*" (sly-connection-name connection))))))
    (with-current-buffer buffer
      (sly-mrepl-mode)
      (setq sly-buffer-connection connection)
      (start-process (format "sly-pty-%s-%s"
                             (process-get connection
                                          'sly--net-connect-counter)
                             (sly-channel.id local))
                     (current-buffer) nil)
      (set-process-query-on-exit-flag (sly-mrepl--process) nil)

      (setq header-line-format (format "Waiting for REPL creation ack for channel %d..."
                                       (sly-channel.id local)))
      (sly-channel-put local 'buffer (current-buffer))
      (add-hook 'kill-buffer-hook 'sly-mrepl--teardown nil 'local)
      (set (make-local-variable 'sly-mrepl--local-channel) local))
    (sly-eval-async
        `(swank-mrepl:create-mrepl ,(sly-channel.id local))
      (lambda (result)
        (cl-destructuring-bind (remote thread-id package prompt) result
          (with-current-buffer buffer
            (sly-mrepl-read-input-ring)
            (setq header-line-format nil)
            (when (zerop (buffer-size))
              (sly-mrepl--insert (concat "; SLY " (sly-version))))
            (setq sly-current-thread thread-id)
            (set (make-local-variable 'sly-mrepl--remote-channel) remote)
            (sly-channel-send local `(:prompt ,package ,prompt))
            (sly-mrepl--send-pending)
            (unwind-protect
                (run-hooks 'sly-mrepl-hook 'sly-mrepl-runonce-hook)
              (set-default 'sly-mrepl-runonce-hook nil))))))
    buffer))

(defun sly-mrepl-close-repls (process)
  (cl-loop for buffer in (buffer-list)
           when (buffer-live-p buffer)
           do (with-current-buffer buffer
                (when (eq sly-buffer-connection
                          process)
                  (insert "\n--------------------------------------------------------\n")
                  (sly-mrepl--teardown)))))

(defun sly-mrepl--process () (get-buffer-process (current-buffer))) ;stupid

(defun sly-mrepl--mark () (process-mark (sly-mrepl--process)))

(defmacro sly-mrepl--commiting-text (&rest body)
  (let ((start-sym (cl-gensym)))
    `(let ((,start-sym (marker-position (sly-mrepl--mark)))
           (inhibit-read-only t))
       ,@body
       (add-text-properties ,start-sym (sly-mrepl--mark)
                            '(read-only t front-sticky (read-only))))))

(defun sly-mrepl--insert (string)
  (sly-mrepl--commiting-text
   (comint-output-filter (sly-mrepl--process) string)))

(defun sly-mrepl--insert-output (string)
  (let ((inhibit-read-only t)
        (start (marker-position sly-mrepl--output-mark)))
    (save-excursion
      (goto-char sly-mrepl--output-mark)
      (unless (looking-at "\n")
        (save-excursion
          (insert "\n")))
      (insert-before-markers string)
      (add-text-properties start (point) '(read-only t)))))

(defun sly-mrepl--send-input ()
  (goto-char (point-max))
  (skip-chars-backward "\n\t\s")
  (delete-region (max (point)
                      (sly-mrepl--mark))
                 (point-max))
  (buffer-disable-undo)
  (sly-mrepl--commiting-text
   (comint-send-input)))

(sly-define-channel-method listener :prompt (package prompt)
  (with-current-buffer (sly-channel-get self 'buffer)
    (setq sly-buffer-package package)
    (when (and sly-mrepl--dedicated-stream
               (process-live-p sly-mrepl--dedicated-stream))
      ;; This non-blocking call should be enough to allow asynch calls
      ;; to `sly-mrepl--insert-output' to still see the correct value
      ;; for `sly-mrepl--output-marker' just before we set it.
      (accept-process-output))
    
    (sly-mrepl--prompt prompt)))

(defun sly-mrepl--prompt (prompt)
  (sly-mrepl--insert (pcase (current-column)
                       (0 "")
                       (t "\n")))
  (set-marker sly-mrepl--output-mark (sly-mrepl--mark))
  (sly-mrepl--insert (format "%s> " prompt))
  (sly-mrepl--recenter)
  (buffer-enable-undo))

(defun sly-mrepl--recenter ()
  (when (get-buffer-window)
    (recenter -1)))

(sly-define-channel-method listener :write-string (string)
  (with-current-buffer (sly-channel-get self 'buffer)
    (sly-mrepl--insert-output string)))

(define-button-type 'sly
  'face 'sly-inspectable-value-face)

(sly-define-channel-method listener :write-values (values)
  (with-current-buffer (sly-channel-get self 'buffer)
    (cl-incf sly-mrepl--result-counter)
    (let* ((comint-preoutput-filter-functions nil))
      (cl-loop for (value . more) on values
               for idx from 0
               for request = `(:inspect ,sly-mrepl--result-counter ,idx)
               do
               (sly-mrepl--insert (make-text-button value nil
                                                    'action `(lambda (_button)
                                                               (sly-mrepl--send ',request))
                                                    :type 'sly))
               when more do (sly-mrepl--insert "\n"))
      (when (null values)
        (sly-mrepl--insert "; No values")))))

(sly-define-channel-method listener :evaluation-aborted (&optional condition)
  (with-current-buffer (sly-channel-get self 'buffer)
    (sly-mrepl--insert (format "; Evaluation aborted on %s\n" condition))))

(sly-define-channel-method listener :inspect-result (parts)
  (cl-assert (sly-channel-p self))
  (sly-open-inspector parts))

(sly-define-channel-method listener :set-read-mode (mode)
  (with-current-buffer (sly-channel-get self 'buffer)
    (cl-ecase mode
      (:read (setq sly-mrepl--expect-sexp-mode nil)
	     (message "[Listener waiting for input to read]"))
      (:eval (setq sly-mrepl--expect-sexp-mode t)
             (message "[Listener waiting for sexps to eval]")))))

(defun sly-mrepl--busy-p ()
  (>= sly-mrepl--output-mark (sly-mrepl--mark)))

(defun sly-mrepl-return (&optional end-of-input)
  (interactive "P")
  (cl-assert (eq (process-status sly-buffer-connection)
                 'open)
             nil
             "Connection closed, cannot this REPL.")
  (cond ((and
	  sly-mrepl--expect-sexp-mode
          (sly-mrepl--busy-p))
	 (message "(wait for it!!!!)"))
        ((and sly-mrepl--expect-sexp-mode
	      (or (sly-input-complete-p (sly-mrepl--mark) (point-max))
		  end-of-input))
	 (sly-mrepl--send-input)
         (set-marker sly-mrepl--output-mark (point)))
	((not sly-mrepl--expect-sexp-mode)
	 (unless end-of-input
	   (newline))
	 (sly-mrepl--send-input))
        
        (t
	 (newline-and-indent)
         (message "[input not complete]")))
  (sly-mrepl--recenter))

;; (add-hook 'post-command-hook 'sly-mrepl--debug t t) is a useful
;; command to debug mrepl issues.
(defun sly-mrepl--debug ()
  (message "point at %s, output-mark at %s, process-mark at %s (%s)"
           (point)
           (marker-position sly-mrepl--output-mark)
           (marker-position (sly-mrepl--mark))
           (if (sly-mrepl--busy-p) "BUSY" "READY")))

(defun sly-mrepl--input-sender (_proc string)
  (sly-mrepl--send-string (substring-no-properties string)))

(defun sly-mrepl--send-string (string &optional _command-string)
  (sly-mrepl--send `(:process ,string)))

(defun sly-mrepl--send (msg)
  "Send MSG to the remote channel.

If message can't be sent right now, queue it onto
`sly-mrepl--pending-requests'"
  (if sly-mrepl--remote-channel
      (sly-send-to-remote-channel sly-mrepl--remote-channel msg)
    (add-to-list (make-local-variable 'sly-mrepl--pending-requests)
                 msg 'append)))

(defun sly-mrepl--send-pending ()
  "Send pending requests from `sly-mrepl--pending-requests'."
  (mapc #'sly-mrepl--send sly-mrepl--pending-requests)
  (setq sly-mrepl--pending-requests nil))

(defun sly-mrepl--find-create (connection)
  (or (cl-find-if (lambda (x)
                    (with-current-buffer x
                      (and (eq major-mode 'sly-mrepl-mode)
                           (eq sly-buffer-connection connection))))
                  (buffer-list))
      (sly-mrepl-new)))

(defun sly-mrepl (&optional interactive)
  "Find or create the first useful REPL for the default connection."
  (interactive (list t))
  (let* ((sly-buffer-connection nil)
         (sly-dispatching-connection nil)
         (buffer
          (sly-mrepl--find-create (sly-connection))))
    (when interactive
      (pop-to-buffer buffer))
    buffer))

(defun sly-mrepl-connected-hook ()
  (let* ((inferior-buffer (and (sly-process) (process-buffer (sly-process))))
         (inferior-window (and inferior-buffer (get-buffer-window inferior-buffer t))))
    (pop-to-buffer (sly-mrepl))
    (when inferior-window
      (bury-buffer inferior-buffer)
      (delete-window inferior-window))
    (goto-char (point-max))))


;;; copy-down-to-REPL behaviour
;;;
(defun sly-mrepl--eval-for-repl (slyfun &rest args)
  (sly-eval-async
   `(swank-mrepl:listener-save-value ',slyfun ,@args)
   #'(lambda (_ignored)
       (with-current-buffer (sly-mrepl--find-create (sly-connection))
         (comint-output-filter (sly-mrepl--process) "\n")
         (sly-mrepl--send `(:produce-saved-value))
         (pop-to-buffer (current-buffer))
         (goto-char (sly-mrepl--mark))))))

(defun sly-inspector-copy-down-to-repl (number)
  "Evaluate the inspector slot at point via the REPL (to set `*')."
  (interactive (list (or (get-text-property (point) 'sly-part-number)
                         (error "No part at point"))))
  (sly-mrepl--eval-for-repl 'swank:inspector-nth-part number))

(defun sldb-copy-down-to-repl (frame-id var-id)
  "Evaluate the frame var at point via the REPL (to set `*')."
  (interactive (list (sldb-frame-number-at-point) (sldb-var-number-at-point)))
  (sly-mrepl--eval-for-repl 'swank-backend:frame-var-value frame-id var-id))

(defun sly-trace-dialog-copy-down-to-repl (id part-id type)
  "Eval the Trace Dialog entry under point in the REPL (to set *)"
  (interactive (cl-loop for prop in '(sly-trace-dialog--id
                                      sly-trace-dialog--part-id
                                      sly-trace-dialog--type)
                        collect (get-text-property (point) prop)))
  (unless (and id part-id type) (error "No trace part at point %s" (point)))
  (sly-mrepl--eval-for-repl 'swank-trace-dialog::find-trace-part id part-id type))


;;; Dedicated output stream
;;;
(defun sly-mrepl--dedicated-stream-output-filter (process string)
  (let ((channel (process-get process 'sly-mrepl--channel)))
    (when channel 
      (with-current-buffer (sly-channel-get channel 'buffer)
        (when (and (cl-plusp (length string))
                   (eq (process-status sly-buffer-connection) 'open))
          (sly-mrepl--insert-output string))))))

(defvar sly-mrepl--dedicated-stream-hooks)

(defun sly-mrepl--open-dedicated-stream (channel port coding-system)
  (let* ((name (format "sly-dds-%s-%s"
                       (process-get sly-buffer-connection
                                    'sly--net-connect-counter)
                       (sly-channel.id channel)))
         (stream (open-network-stream name
                                      (generate-new-buffer
                                       (format " *%s*" name))
                                      (car (process-contact sly-buffer-connection))
                                      port))
         (emacs-coding-system (car (cl-find coding-system
                                            sly-net-valid-coding-systems
                                            :key #'cl-third))))
    (set-process-query-on-exit-flag stream nil)
    (set-process-plist stream `(sly-mrepl--channel ,channel))
    (set-process-filter stream 'sly-mrepl--dedicated-stream-output-filter)
    (set-process-coding-system stream emacs-coding-system emacs-coding-system)
    (when-let (secret (sly-secret))
      (sly-net-send secret stream))
    (run-hook-with-args 'sly-mrepl--dedicated-stream-hooks stream)
    stream))

(sly-define-channel-method listener :open-dedicated-output-stream (port _coding-system)
  (with-current-buffer (sly-channel-get self 'buffer)
    ;; HACK: no coding system
    (set (make-local-variable 'sly-mrepl--dedicated-stream)
         (sly-mrepl--open-dedicated-stream self port nil))))


;;; Misc
;;;
(defvar sly-mrepl-history-separator "####\n")

(defun sly-mrepl-read-input-ring ()
  (let ((comint-input-ring-separator sly-mrepl-history-separator))
    (comint-read-input-ring)))
  

(defun sly-mrepl--merge-and-save-history ()
  (let* ((current-ring (copy-tree comint-input-ring 'vectors-too))
         (index (ring-length current-ring))
         (comint-input-ring-separator sly-mrepl-history-separator))

    ;; this sets comint-input-ring from the file
    ;; 
    (comint-read-input-ring)
    (cl-loop for i from 0 below index
             for item = (ring-ref current-ring i)
             unless (ring-member comint-input-ring item)
             do (ring-insert comint-input-ring item))
    (comint-write-input-ring)))

(defun sly-mrepl--teardown ()
  (condition-case err
      (progn
        (sly-mrepl--merge-and-save-history)
        (ignore-errors
          (sly-mrepl--send `(:teardown)))
        (set (make-local-variable 'sly-mrepl--remote-channel) nil)
        (when sly-mrepl--dedicated-stream
          (kill-buffer (process-buffer sly-mrepl--dedicated-stream)))
        (delete-process (sly-mrepl--process))
        (sly-close-channel sly-mrepl--local-channel))
    (error
     (message "[sly-mrepl]: error tearing down %s (%s), removing from kill hook."
              (current-buffer)
              err)
     (remove-hook 'kill-buffer-hook 'sly-mrepl--teardown 'local))))


(defun sly-mrepl-sync-package-and-default-directory ()
  "Set Lisp's package and directory to the values in current buffer."
  (interactive)
  (let ((package (sly-current-package)))
    (with-current-buffer (sly-mrepl)
      (comint-output-filter (sly-mrepl--process) "\n")
      (sly-mrepl--send `(:sync-package-and-default-directory
                         ,package
                         ,default-directory))
      (pop-to-buffer (current-buffer))
      (goto-char (sly-mrepl--mark)))))


(def-sly-selector-method ?m
  "First mrepl-buffer"
  (or (sly-mrepl)
      (error "No mrepl buffer (%s)" (sly-connection-name))))

(provide 'sly-mrepl)
