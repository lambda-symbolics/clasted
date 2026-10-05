(in-package #:clasted)

;;;; -- Optional ast-grep adapter --

(defclass ast-grep-backend (backend)
  ((program :initarg :program :reader backend--program
            :documentation "Executable name or pathname, never a shell command.")
   (runner :initarg :runner :reader backend--runner
           :documentation "Function accepting command/input and keyword limits.")
   (maximum-output-bytes :initarg :maximum-output-bytes :reader backend--output-limit
                         :documentation "Bound on each captured process stream.")
   (maximum-matches :initarg :maximum-matches :reader backend--match-limit
                    :documentation "Maximum number of matches or edits.")
   (maximum-preview-bytes :initarg :maximum-preview-bytes :reader backend--preview-limit
                          :documentation "Bound on proposed UTF-8 content.")
   (timeout :initarg :timeout :reader backend--timeout
            :documentation "Maximum process runtime in seconds.")
   (cancelled-p :initarg :cancelled-p :reader backend--cancelled-p
                :documentation "Optional synchronous cancellation predicate."))
  (:documentation "Immutable stdin ast-grep queries with validated JSON results."))

(defun make-ast-grep-backend (&key (program "ast-grep") (runner #'run-ast-grep)
                                 (maximum-output-bytes (* 8 1024 1024))
                                 (maximum-matches 10000)
                                 (maximum-preview-bytes (* 16 1024 1024))
                                 (timeout 30) cancelled-p)
  "Construct an optional CLI backend. RUNNER returns stdout, stderr, exit code.
RUNNER receives COMMAND, INPUT, :MAXIMUM-OUTPUT-BYTES, :TIMEOUT, :CANCELLED-P.
It must bound capture and honor timeout/cancellation; no shell is involved."
  (unless (and (stringp program) (plusp (length program)) (functionp runner)
               (every (lambda (value) (and (integerp value) (<= 0 value)))
                      (list maximum-output-bytes maximum-matches maximum-preview-bytes))
               (realp timeout) (plusp timeout)
               (or (null cancelled-p) (functionp cancelled-p)))
    (fail ':invalid-backend))
  (make-instance 'ast-grep-backend :program (copy-seq program) :runner runner
                 :maximum-output-bytes maximum-output-bytes
                 :maximum-matches maximum-matches
                 :maximum-preview-bytes maximum-preview-bytes
                 :timeout timeout :cancelled-p cancelled-p))

(defun check-cancelled (predicate)
  "Check synchronous cancellation without swallowing predicate failures."
  (when (and predicate (funcall predicate)) (fail ':cancelled)))

(defun file-byte-size (path)
  "Measure a process spool file without loading it."
  (with-open-file (stream path :element-type '(unsigned-byte 8))
    (file-length stream)))

(defun read-bounded-utf8 (path maximum)
  "Read a completed spool file only after its byte size passes the bound."
  (with-open-file (stream path :element-type '(unsigned-byte 8))
    (let ((length (file-length stream)))
      (when (> length maximum) (fail ':output-limit))
      (let ((bytes (make-array length :element-type '(unsigned-byte 8))))
        (unless (= length (read-sequence bytes stream)) (fail ':backend-output))
        (handler-case (babel:octets-to-string bytes :encoding :utf-8 :errorp t)
          (error () (fail ':backend-output)))))))

(defun run-ast-grep (command input &key (maximum-output-bytes (* 8 1024 1024))
                                      (timeout 30) cancelled-p)
  "Run argv COMMAND using owned temporary spools and UTF-8 stdin.
Poll timeout/cancellation and stream sizes; always terminate/reap on unwind.
Spools avoid pipe deadlocks. File growth between polls may exceed the bound,
but no oversized stream is loaded into Lisp. Returns stdout, stderr, exit code."
  (unless (and command (listp command) (integerp maximum-output-bytes)
               (<= 0 maximum-output-bytes) (realp timeout) (plusp timeout)
               (or (null cancelled-p) (functionp cancelled-p)))
    (fail ':invalid-runner-request))
  (loop with remaining = command
        for count from 1
        while remaining
        do (unless (and (<= count 64) (consp remaining) (stringp (first remaining)))
             (fail ':invalid-runner-request))
           (setf remaining (rest remaining)))
  (check-cancelled cancelled-p)
  (uiop:with-temporary-file (:pathname input-path :stream input-stream
                            :direction :output :element-type '(unsigned-byte 8))
    (write-sequence (utf8 input) input-stream)
    :close-stream
    (uiop:with-temporary-file (:pathname output-path)
      (uiop:with-temporary-file (:pathname error-path)
        (let ((process nil)
              (start (get-internal-real-time))
              (finished nil))
          (unwind-protect
               (progn
                 (setf process
                       (handler-case
                           (uiop:launch-program command :input input-path
                                                :output output-path :error-output error-path)
                         (error () (fail ':backend-launch))))
                 (loop
                   (check-cancelled cancelled-p)
                   (when (or (> (file-byte-size output-path) maximum-output-bytes)
                             (> (file-byte-size error-path) maximum-output-bytes))
                     (fail ':output-limit))
                   (unless (uiop:process-alive-p process) (return))
                   (when (> (/ (- (get-internal-real-time) start)
                               internal-time-units-per-second)
                            timeout)
                     (fail ':timeout))
                   (sleep 0.01))
                 (let ((code (uiop:wait-process process)))
                   (setf finished t)
                   (values (read-bounded-utf8 output-path maximum-output-bytes)
                           (read-bounded-utf8 error-path maximum-output-bytes) code)))
            (when (and process (not finished))
              (unwind-protect
                   (when (uiop:process-alive-p process)
                     (uiop:terminate-process process :urgent t))
                (uiop:wait-process process)))))))))

(defun required-field (object field type)
  "Require FIELD in a JSON object with TYPE, rejecting missing/null values."
  (unless (hash-table-p object) (fail ':backend-contract))
  (multiple-value-bind (value present) (gethash field object)
    (unless (and present (typep value type)) (fail ':backend-contract))
    value))

(defun offsets (object)
  "Validate a JSON half-open unsigned byte-offset object."
  (let ((start (required-field object "start" '(integer 0)))
        (end (required-field object "end" '(integer 0))))
    (unless (<= start end) (fail ':backend-contract))
    (values start end)))

(defun request-results (backend snapshot &key language pattern replacement)
  "Run only immutable stdin operations and parse bounded JSON arrays."
  (unless (and (typep snapshot 'snapshot) (stringp language)
               (plusp (length language)) (stringp pattern)
               (or (null replacement) (stringp replacement)))
    (fail ':invalid-query))
  (dolist (text (remove nil (list language pattern replacement)))
    (when (> (length (utf8 text)) 65536) (fail ':query-limit)))
  (check-cancelled (backend--cancelled-p backend))
  (let ((command (append (list (backend--program backend) "run" "--stdin" "--json=compact"
                              (concatenate 'string "--lang=" language)
                              (concatenate 'string "--pattern=" pattern))
                         (when replacement
                           (list (concatenate 'string "--rewrite=" replacement))))))
    (multiple-value-bind (output errors code)
        (handler-case
            (funcall (backend--runner backend) command (snapshot-text snapshot)
                     :maximum-output-bytes (backend--output-limit backend)
                     :timeout (backend--timeout backend)
                     :cancelled-p (backend--cancelled-p backend))
          (structural-error (condition) (error condition))
          (error () (fail ':backend-failure)))
      (check-cancelled (backend--cancelled-p backend))
      (unless (and (stringp output) (stringp errors) (integerp code))
        (fail ':backend-contract))
      (when (or (> (length (utf8 output)) (backend--output-limit backend))
                (> (length (utf8 errors)) (backend--output-limit backend)))
        (fail ':output-limit))
      (unless (member code '(0 1)) (fail ':backend-exit))
      (let ((results
              (handler-case
                  (argo:json-decode
                   output :limits
                   (argo:make-json-limits
                    :maximum-characters (backend--output-limit backend)
                    :maximum-depth 32
                    :maximum-nodes (* 128 (1+ (backend--match-limit backend)))
                    :maximum-string-characters (backend--output-limit backend)
                    :maximum-array-elements (backend--match-limit backend)
                    :maximum-number-characters 32))
                (argo:json-limit-exceeded () (fail ':result-limit))
                (argo:json-error () (fail ':backend-contract)))))
        (unless (and (vectorp results) (not (stringp results)))
          (fail ':backend-contract))
        (when (> (length results) (backend--match-limit backend)) (fail ':result-limit))
        (unless (= code (if (zerop (length results)) 1 0)) (fail ':backend-contract))
        results))))

(defun result-match (result snapshot query-id)
  "Validate the ast-grep stdin identity, source text and byte range."
  (unless (string= (required-field result "file" 'string) "STDIN")
    (fail ':backend-contract))
  (required-field result "language" 'string)
  (let* ((range (required-field result "range" 'hash-table))
         (byte-offset (required-field range "byteOffset" 'hash-table)))
    ;; Position columns are presentation fields, never character edit offsets.
    (dolist (field '("start" "end"))
      (let ((position (required-field range field 'hash-table)))
        (required-field position "line" '(integer 0))
        (required-field position "column" '(integer 0))))
    (multiple-value-bind (start end) (offsets byte-offset)
      (make-structural-match :snapshot snapshot :query-id query-id
                             :start-byte start :end-byte end
                             :text (required-field result "text" 'string)))))

(defmethod backend-query ((backend ast-grep-backend) snapshot &key language pattern)
  (let* ((results (request-results backend snapshot :language language :pattern pattern))
         (query-id (identity-digest "ast-grep" language pattern))
         (matches nil)
         (seen (make-hash-table :test #'equal)))
    (loop for result across results
          do (check-cancelled (backend--cancelled-p backend))
             (let ((match (result-match result snapshot query-id)))
               (when (gethash (match--id match) seen) (fail ':backend-contract))
               (setf (gethash (match--id match) seen) t)
               (push match matches)))
    (stable-sort matches #'< :key #'match--start)))

(defmethod backend-rewrite ((backend ast-grep-backend) snapshot &key language pattern replacement)
  (unless (stringp replacement) (fail ':invalid-query))
  (let* ((results (request-results backend snapshot :language language :pattern pattern
                                   :replacement replacement))
         (query-id (identity-digest "ast-grep" language pattern))
         (edits nil))
    (loop for result across results
          do (check-cancelled (backend--cancelled-p backend))
             (result-match result snapshot query-id)
             (multiple-value-bind (start end)
                 (offsets (required-field result "replacementOffsets" 'hash-table))
               ;; Replacement offsets can differ from match offsets. Honor the
               ;; actual fixer range rather than silently using the match span.
               (push (make-edit :start (byte-index snapshot start)
                                :end (byte-index snapshot end)
                                :replacement (required-field result "replacement" 'string))
                     edits)))
    (make-edit-plan :snapshot snapshot :edits edits
                    :maximum-edits (backend--match-limit backend)
                    :maximum-bytes (backend--preview-limit backend))))
