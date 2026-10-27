(in-package #:clasted)

;;;; -- Immutable snapshots and spans --

(define-condition structural-error (error)
  ((code :initarg :code :reader structural-error-code
         :documentation "Machine-readable failure category."))
  (:documentation "Invalid structural request, backend failure or unsafe edit plan.")
  (:report (lambda (condition stream)
             (format stream "Structural operation failed: ~A."
                     (structural-error-code condition)))))

(defun fail (code)
  "Signal a structured failure without source or process output in its report."
  (error 'structural-error :code code))

(defun utf8 (text)
  "Encode Unicode scalar TEXT as UTF-8, rejecting surrogate code points."
  (unless (and (stringp text)
               (every (lambda (character)
                        (let ((code (char-code character)))
                          (and (<= code #x10ffff) (not (<= #xd800 code #xdfff)))))
                      text))
    (fail ':invalid-text))
  (babel:string-to-octets text :encoding :utf-8))

(defun identity-digest (&rest fields)
  "Hash length-framed UTF-8 string FIELDS, independent of Lisp print settings."
  (let ((state (ironclad:make-digest ':sha256)))
    (dolist (field fields)
      (let* ((bytes  (utf8 field))
             (prefix (utf8 (format nil "~D:" (length bytes)))))
        (ironclad:update-digest state prefix)
        (ironclad:update-digest state bytes)))
    (ironclad:byte-array-to-hex-string (ironclad:produce-digest state))))

(defstruct (snapshot (:constructor %snapshot)
                     (:conc-name snapshot--))
  "An owned immutable source observation; public readers copy strings."
  (id "" :type string :read-only t)
  (file "" :type string :read-only t)
  (revision "" :type string :read-only t)
  (text "" :type string :read-only t)
  (boundaries #() :type vector :read-only t))

(defun make-snapshot (&key file revision text (maximum-bytes (* 16 1024 1024)))
  "Copy FILE identity, opaque REVISION and TEXT. No filesystem access occurs."
  (unless (and (stringp file) (plusp (length file)) (stringp revision)
               (integerp maximum-bytes) (<= 0 maximum-bytes))
    (fail ':invalid-snapshot))
  (let* ((bytes      (utf8 text))
         (boundaries (make-array (1+ (length text)) :element-type 'integer))
         (offset     0))
    (when (> (length bytes) maximum-bytes) (fail ':source-limit))
    (setf (aref boundaries 0) 0)
    (loop for character across text for index from 1
          for code = (char-code character)
          do (incf offset (cond ((<= code #x7f)
                                 1)
                                ((<= code #x7ff)
                                 2)
                                ((<= code #xffff)
                                 3)
                                (t
                                 4)))
             (setf (aref boundaries index) offset))
    (%snapshot :id (identity-digest file revision text)
               :file (copy-seq file) :revision (copy-seq revision)
               :text (copy-seq text) :boundaries boundaries)))

(defun snapshot-id (snapshot)
  "Return a copy of the content/revision/file SHA-256 identity."
  (copy-seq (snapshot--id snapshot)))

(defun snapshot-file (snapshot)
  "Return a copy of the caller-defined file identity."
  (copy-seq (snapshot--file snapshot)))

(defun snapshot-revision (snapshot)
  "Return a copy of the caller's opaque resource revision."
  (copy-seq (snapshot--revision snapshot)))

(defun snapshot-text (snapshot)
  "Return a copy of the observed source."
  (copy-seq (snapshot--text snapshot)))

(defun byte-index (snapshot offset)
  "Convert an exact UTF-8 boundary OFFSET by binary search."
  (unless (and (integerp offset) (<= 0 offset)) (fail ':invalid-span))
  (let* ((boundaries (snapshot--boundaries snapshot))
         (low        0)
         (high       (length boundaries)))
    (loop while (< low high)
          for middle = (floor (+ low high) 2)
          for value = (aref boundaries middle)
          do (cond ((= value offset)
                    (return-from byte-index middle))
                   ((< value offset)
                    (setf low (1+ middle)))
                   (t
                    (setf high middle))))
    (fail ':invalid-span)))

(defstruct (structural-match (:constructor %match) (:conc-name match--))
  "A validated structural match anchored to one immutable snapshot."
  (id "" :type string :read-only t)
  (snapshot-id "" :type string :read-only t)
  (start-byte 0 :type integer :read-only t)
  (end-byte 0 :type integer :read-only t)
  (start 0 :type integer :read-only t)
  (end 0 :type integer :read-only t)
  (text "" :type string :read-only t))

(defun make-structural-match (&key snapshot query-id start-byte end-byte text)
  "Validate byte boundaries and matched TEXT; identity includes QUERY-ID and span."
  (unless (stringp query-id) (fail ':invalid-query))
  (let ((start (byte-index snapshot start-byte))
        (end   (byte-index snapshot end-byte)))
    (unless (and (<= start end) (stringp text)
                 (string= text (subseq (snapshot--text snapshot) start end)))
      (fail ':invalid-span))
    (%match :id          (identity-digest (snapshot--id snapshot) query-id
                                         (format nil "~D:~D" start-byte end-byte) text)
            :snapshot-id (snapshot--id snapshot)
            :start-byte start-byte :end-byte end-byte
            :start start :end end :text (copy-seq text))))

(defun match-id (match)
  "Return a copy of the stable match identity."
  (copy-seq (match--id match)))

(defun match-snapshot-id (match)
  "Return a copy of the match's snapshot identity."
  (copy-seq (match--snapshot-id match)))

(defun match-start-byte (match)
  "Return the inclusive UTF-8 byte offset."
  (match--start-byte match))

(defun match-end-byte (match)
  "Return the exclusive UTF-8 byte offset."
  (match--end-byte match))

(defun match-start (match)
  "Return the inclusive Common Lisp character offset."
  (match--start match))

(defun match-end (match)
  "Return the exclusive Common Lisp character offset."
  (match--end match))

(defun match-text (match)
  "Return a copy of the validated source span."
  (copy-seq (match--text match)))


;;;; -- Ordered, previewable edits --

(defstruct (edit (:constructor %edit) (:conc-name edit--))
  "A replacement at half-open character offsets into a snapshot."
  (start 0 :type integer :read-only t)
  (end 0 :type integer :read-only t)
  (replacement "" :type string :read-only t))

(defun make-edit (&key start end replacement)
  "Copy REPLACEMENT and validate nonnegative ordered character offsets."
  (unless (and (integerp start) (integerp end) (<= 0 start end))
    (fail ':invalid-span))
  (utf8 replacement)
  (%edit :start start :end end :replacement (copy-seq replacement)))

(defun edit-start (edit)
  "Return the inclusive character offset."
  (edit--start edit))

(defun edit-end (edit)
  "Return the exclusive character offset."
  (edit--end edit))

(defun edit-replacement (edit)
  "Return a copy of the replacement source."
  (copy-seq (edit--replacement edit)))

(defstruct (edit-plan (:constructor %plan) (:conc-name plan--))
  "An immutable ordered, nonoverlapping edit plan with complete preview."
  (snapshot nil :type snapshot :read-only t)
  (edits nil :type list :read-only t)
  (preview "" :type string :read-only t))

(defun make-edit-plan (&key snapshot edits (maximum-edits 10000)
                           (maximum-bytes (* 16 1024 1024)))
  "Sort EDITS by source offset, reject ambiguity and compute bounded preview.
Coincident insertions, duplicate and nested edits are rejected, not merged."
  (unless (and (typep snapshot 'snapshot) (listp edits)
               (integerp maximum-edits) (<= 0 maximum-edits)
               (integerp maximum-bytes) (<= 0 maximum-bytes))
    (fail ':invalid-plan))
  (loop with count = 0
        with remaining = edits
        while remaining
        do (unless (and (consp remaining) (typep (first remaining) 'edit))
             (fail ':invalid-plan))
           (when (> (incf count) maximum-edits) (fail ':result-limit))
           (setf remaining (rest remaining)))
  (let* ((ordered   (stable-sort (copy-list edits) #'< :key #'edit--start))
         (text      (snapshot--text snapshot))
         (previous  nil)
         (byte-size (length (utf8 text))))
    (dolist (edit ordered)
      (unless (<= (edit--end edit) (length text)) (fail ':invalid-span))
      (when (and previous
                 (or (< (edit--start edit) (edit--end previous))
                     (= (edit--start edit) (edit--start previous))))
        (fail ':overlapping-edits))
      (decf byte-size (- (aref (snapshot--boundaries snapshot) (edit--end edit))
                        (aref (snapshot--boundaries snapshot) (edit--start edit))))
      (incf byte-size (length (utf8 (edit--replacement edit))))
      (setf previous edit))
    (when (> byte-size maximum-bytes) (fail ':preview-limit))
    (%plan :snapshot snapshot :edits ordered
           :preview (with-output-to-string (output)
                      (let ((position 0))
                        (dolist (edit ordered)
                          (write-string text output :start position :end (edit--start edit))
                          (write-string (edit--replacement edit) output)
                          (setf position (edit--end edit)))
                        (write-string text output :start position))))))

(defun plan-snapshot (plan)
  "Return the immutable snapshot to revalidate before publication."
  (plan--snapshot plan))

(defun plan-edits (plan)
  "Return a fresh list of immutable edits in ascending source order."
  (copy-list (plan--edits plan)))

(defun plan-preview (plan)
  "Return a copy of the full proposed source content."
  (copy-seq (plan--preview plan)))


;;;; -- Backend protocol --

(defclass backend () ()
  (:documentation "Structural engine producing observations and plans, never source writes."))

(defgeneric backend-query (backend snapshot &key language pattern)
  (:documentation "Return validated STRUCTURAL-MATCH objects for SNAPSHOT."))

(defgeneric backend-rewrite (backend snapshot &key language pattern replacement)
  (:documentation "Return an EDIT-PLAN for SNAPSHOT without changing files."))

(defun query (backend snapshot &key language pattern)
  "Query BACKEND over SNAPSHOT with explicit LANGUAGE and structural PATTERN."
  (backend-query backend snapshot :language language :pattern pattern))

(defun rewrite (backend snapshot &key language pattern replacement)
  "Preview a structural rewrite of SNAPSHOT; publication belongs to the caller."
  (backend-rewrite backend snapshot :language language :pattern pattern :replacement replacement))
