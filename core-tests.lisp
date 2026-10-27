(in-package #:clasted)

(defvar *test-checks* 0
  "The number of assertions that passed in the current test run.")

(defun test-check (value)
  "Record a successful assertion or signal a test failure."
  (assert value)
  (incf *test-checks*))

(defun test-error (code thunk)
  "Require a structural failure with exactly CODE."
  (test-check
   (handler-case (progn (funcall thunk) nil)
     (structural-error (condition) (eq code (structural-error-code condition))))))

(defun run-core-tests ()
  "Exercise snapshot ownership, stable identities, spans and ordered previews."
  (let* ((source (copy-seq "aé😀z"))
         (file (copy-seq "workspace:α.js"))
         (revision (copy-seq "R1"))
         (snapshot (make-snapshot :file file :revision revision :text source))
         (match (make-structural-match :snapshot snapshot :query-id "Q"
                                       :start-byte 1 :end-byte 7 :text "é😀")))
    (setf (char source 0) #\b (char file 0) #\x (char revision 0) #\x)
    (test-check (string= (snapshot-text snapshot) "aé😀z"))
    (test-check (string= (snapshot-file snapshot) "workspace:α.js"))
    (test-check (string= (snapshot-revision snapshot) "R1"))
    (dolist (reader (list #'snapshot-text #'snapshot-file #'snapshot-revision #'snapshot-id))
      (let* ((value (funcall reader snapshot)) (expected (copy-seq value)))
        (setf (char value 0) #\x)
        (test-check (string= expected (funcall reader snapshot)))))
    (test-check (= (match-start match) 1))
    (test-check (= (match-end match) 3))
    (test-check (= (match-start-byte match) 1))
    (test-check (= (match-end-byte match) 7))
    (test-check (string= (match-text match) "é😀"))
    (test-check (string= (match-snapshot-id match) (snapshot-id snapshot)))
    (test-check (string= (match-id match)
                        (match-id (make-structural-match :snapshot snapshot :query-id "Q"
                                                         :start-byte 1 :end-byte 7 :text "é😀"))))
    (dolist (arguments '((:file "workspace:α.js" :revision "R2" :text "aé😀z")
                         (:file "workspace:β.js" :revision "R1" :text "aé😀z")
                         (:file "workspace:α.js" :revision "R1" :text "bé😀z")))
      (test-check (not (string= (snapshot-id snapshot)
                               (snapshot-id (apply #'make-snapshot arguments))))))
    (test-check (not (string= (match-id match)
                             (match-id (make-structural-match :snapshot snapshot :query-id "X"
                                                              :start-byte 1 :end-byte 7 :text "é😀")))))
    (dolist (span '((2 7 "é😀") (1 4 "é😀") (-1 7 "é😀") (7 1 "") (1 9 "é😀")
                    (1 7 "wrong") (1 7 nil) (1.0 7 "é😀")))
      (destructuring-bind (start end text) span
        (test-error ':invalid-span
                    (lambda () (make-structural-match :snapshot snapshot :query-id "Q"
                                                      :start-byte start :end-byte end :text text)))))
    (let* ((replacement (copy-seq "λ"))
           (edit (make-edit :start 1 :end 3 :replacement replacement))
           (plan (make-edit-plan :snapshot snapshot
                                :edits (list (make-edit :start 3 :end 4 :replacement "!") edit))))
      (setf (char replacement 0) #\x)
      (test-check (string= (edit-replacement edit) "λ"))
      (test-check (eq snapshot (plan-snapshot plan)))
      (test-check (equal '(1 3) (mapcar #'edit-start (plan-edits plan))))
      (test-check (string= (plan-preview plan) "aλ!"))
      (setf (first (plan-edits plan)) nil)
      (test-check (= 2 (length (plan-edits plan))))
      (setf (char (plan-preview plan) 0) #\x)
      (test-check (string= (plan-preview plan) "aλ!"))
      (test-error ':preview-limit
                  (lambda () (make-edit-plan :snapshot snapshot :edits (plan-edits plan)
                                             :maximum-bytes 3)))
      (test-error ':result-limit
                  (lambda () (make-edit-plan :snapshot snapshot :edits (plan-edits plan)
                                             :maximum-edits 1))))
    (test-check (string= "aé😀z" (plan-preview (make-edit-plan :snapshot snapshot :edits nil))))
    (test-check (string= "aé😀z!"
                        (plan-preview (make-edit-plan :snapshot snapshot
                                       :edits (list (make-edit :start 4 :end 4 :replacement "!"))))))
    (test-check (string= ""
                        (plan-preview (make-edit-plan :snapshot snapshot
                                       :edits (list (make-edit :start 0 :end 4 :replacement ""))))))
    (dolist (spans '(((0 3) (2 4)) ((0 4) (1 2)) ((1 1) (1 1)) ((1 3) (1 3))
                     ((1 3) (1 1)) ((1 3) (2 2))))
      (test-error ':overlapping-edits
                  (lambda () (make-edit-plan :snapshot snapshot
                               :edits (mapcar (lambda (span)
                                                (make-edit :start (first span) :end (second span)
                                                           :replacement "x")) spans)))))
    (test-error ':invalid-span
                (lambda () (make-edit-plan :snapshot snapshot
                             :edits (list (make-edit :start 4 :end 5 :replacement "x")))))
    (test-error ':source-limit
                (lambda () (make-snapshot :file "f" :revision "r" :text "é" :maximum-bytes 1)))
    (test-error ':invalid-text
                (lambda () (make-snapshot :file "f" :revision "r" :text nil)))
    (test-error ':invalid-snapshot
                (lambda () (make-snapshot :file "" :revision "r" :text "")))
    (test-check (not (string= (identity-digest "a" "bc") (identity-digest "ab" "c")))))
  (let* ((text "aé→😀")
         (snapshot (make-snapshot :file "unicode" :revision "r" :text text)))
    (loop for start in '(0 1 3 6 10) for index from 0
          do (let ((match (make-structural-match :snapshot snapshot :query-id "Q"
                                               :start-byte start :end-byte start :text "")))
               (test-check (= index (match-start match)))))
    (dolist (invalid '(2 4 5 7 8 9 11))
      (test-error ':invalid-span
                  (lambda () (make-structural-match :snapshot snapshot :query-id "Q"
                                                   :start-byte invalid :end-byte invalid :text "")))))
  (let* ((snapshot (make-snapshot :file "f" :revision "r" :text "x"))
         (edit (make-edit :start 0 :end 1 :replacement "y"))
         (circular (list edit)))
    (test-error ':invalid-plan
                (lambda () (make-edit-plan :snapshot snapshot :edits (cons edit 'tail))))
    (setf (rest circular) circular)
    (test-error ':result-limit
                (lambda () (make-edit-plan :snapshot snapshot :edits circular :maximum-edits 2))))
  t)

(defun run-tests ()
  "Run the dependency-light core suite and report assertion count."
  (let ((*test-checks* 0))
    (run-core-tests)
    (format t "clasted core: ~D checks passed.~%" *test-checks*)
    *test-checks*))
