(in-package #:clasted)

(defun backend-test-program ()
  "Select a real executable; missing backend is a test failure, not a skip."
  (or (uiop:getenv "CLASTED_AST_GREP") "ast-grep"))

(defun fixture-backend (output &key (code 0) (errors "") (maximum-matches 10000)
                                   (maximum-output-bytes (* 8 1024 1024)))
  "Inject a recorded/modified real-backend response through the public runner."
  (make-ast-grep-backend
   :maximum-matches maximum-matches :maximum-output-bytes maximum-output-bytes
   :runner (lambda (command input &key maximum-output-bytes timeout cancelled-p)
             (declare (ignore command input maximum-output-bytes timeout cancelled-p))
             (values output errors code))))

(defun run-real-backend-tests ()
  "Exercise real ast-grep syntax, Unicode, rewrite ranges and failure paths."
  (let* ((program  (backend-test-program))
         (backend  (make-ast-grep-backend :program program))
         (text     (format nil "const é = foo(1);~%foo(\"😀\");~%"))
         (snapshot (make-snapshot :file "workspace:é.js" :revision "r1" :text text))
         (matches  (query backend snapshot :language "javascript" :pattern "foo($A)"))
         (plan     (rewrite backend snapshot :language "javascript"
                            :pattern "foo($A)" :replacement "bar($A)")))
    (test-check (= 2 (length matches)))
    (test-check (equal '(10 18) (mapcar #'match-start matches)))
    (test-check (equal '(11 19) (mapcar #'match-start-byte matches)))
    (test-check (equal '(16 26) (mapcar #'match-end matches)))
    (test-check (equal '(17 30) (mapcar #'match-end-byte matches)))
    (test-check (equal '("foo(1)" "foo(\"😀\")") (mapcar #'match-text matches)))
    (test-check (equal (mapcar #'match-id matches)
                       (mapcar #'match-id (query backend snapshot :language "javascript"
                                                  :pattern                  "foo($A)"))))
    (test-check (string= (plan-preview plan)
                        (format nil "const é = bar(1);~%bar(\"😀\");~%")))
    (test-check (string= text (snapshot-text snapshot)))
    (test-check (equal '(10 18) (mapcar #'edit-start (plan-edits plan))))
    (test-check (null (query backend snapshot :language "javascript" :pattern "missing($A)")))
    (test-check (string= text
                        (plan-preview (rewrite backend snapshot :language "javascript"
                                               :pattern "missing($A)" :replacement ""))))
    (test-check (string= (format nil "const é = ;~%;~%")
                        (plan-preview (rewrite backend snapshot :language "javascript"
                                               :pattern "foo($A)" :replacement ""))))
    (let ((nested (make-snapshot :file "f.js" :revision "r" :text "foo(foo(1));")))
      (test-check (= 2 (length (query backend nested :language "javascript" :pattern "foo($A)"))))
      (test-error ':overlapping-edits
                  (lambda () (rewrite backend nested :language "javascript"
                                      :pattern "foo($A)" :replacement "bar($A)"))))
    (dolist (case (list '("python" "print('é')" "print($A)" "log($A)" "log('é')")
                       '("rust" "fn f() { foo(1); }" "foo($A)" "bar($A)" "fn f() { bar(1); }")
                       '("javascript" "-foo(1);" "-foo($A)" "-bar($A)" "-bar(1);")
                       (list "javascript" (format nil "foo(1);~C~Cfoo(2);" #\Return #\Newline)
                             "foo($A)" "bar($A)"
                             (format nil "bar(1);~C~Cbar(2);" #\Return #\Newline))))
      (destructuring-bind (language source pattern replacement expected) case
        (let ((observation (make-snapshot :file "virtual" :revision "r" :text source)))
          (test-check (string= expected
                              (plan-preview (rewrite backend observation :language language
                                                     :pattern pattern :replacement replacement)))))))
    (test-error ':backend-exit
                (lambda () (query backend snapshot :language "not-a-language" :pattern "x")))
    (test-error ':backend-exit
                (lambda () (query backend snapshot :language "javascript" :pattern "")))
    (test-error ':backend-launch
                (lambda () (query (make-ast-grep-backend :program "/absent-clasted-test-program")
                                  snapshot :language "javascript" :pattern "x")))
    (test-error ':result-limit
                (lambda () (query (make-ast-grep-backend :program program :maximum-matches 1)
                                  snapshot :language "javascript" :pattern "foo($A)")))
    (test-error ':output-limit
                (lambda () (query (make-ast-grep-backend :program program :maximum-output-bytes 20)
                                  snapshot :language "javascript" :pattern "foo($A)")))
    (test-error ':preview-limit
                (lambda () (rewrite (make-ast-grep-backend :program program :maximum-preview-bytes 1)
                                    snapshot :language "javascript" :pattern "foo($A)"
                                    :replacement "bar($A)")))
    (test-error ':cancelled
                (lambda () (query (make-ast-grep-backend :program program :cancelled-p (lambda () t))
                                  snapshot :language "javascript" :pattern "foo($A)")))
    ;; Capture real JSON, then mutate independently to test contract validation.
    (multiple-value-bind (output errors code)
        (run-ast-grep (list program "run" "--stdin" "--json=compact" "--lang" "javascript"
                           "--pattern" "foo($A)" "--rewrite" "bar($A)")
                      text :maximum-output-bytes 65536 :timeout 30)
      (test-check (= code 0))
      (test-check (string= errors ""))
      (test-check (string= (plan-preview plan)
                          (plan-preview (rewrite (fixture-backend output) snapshot
                                                 :language "javascript" :pattern "foo($A)"
                                                 :replacement "bar($A)"))))
      (flet ((mutated (function)
               (let ((value (argo:json-decode output)))
                 (funcall function value)
                 (argo:json-encode value))))
        (dolist (mutation (list
                           (lambda (value) (remhash "file" (aref value 0)))
                           (lambda (value) (setf (gethash "file" (aref value 0)) "other.js"))
                           (lambda (value) (setf (gethash "text" (aref value 0)) "wrong"))
                           (lambda (value) (setf (gethash "text" (aref value 0)) nil))
                           (lambda (value) (remhash "replacement" (aref value 0)))
                           (lambda (value) (remhash "replacementOffsets" (aref value 0)))
                           (lambda (value) (setf (gethash "language" (aref value 0)) 1))
                           (lambda (value)
                             (setf (gethash "start" (gethash "byteOffset" (gethash "range" (aref value 0)))) -1))))
          (let ((response (mutated mutation)))
            (test-check
             (handler-case
                 (progn (rewrite (fixture-backend response) snapshot :language "javascript"
                                 :pattern "foo($A)" :replacement "bar($A)") nil)
               (structural-error (condition)
                 (member (structural-error-code condition) '(:backend-contract :invalid-span)))))))
        (let ((response
                (mutated (lambda (value)
                           (setf (gethash "start" (gethash "replacementOffsets" (aref value 0))) 6
                                 (gethash "end" (gethash "replacementOffsets" (aref value 0))) 9
                                 (gethash "replacement" (aref value 0)) "X")))))
          ;; Actual fixer ranges need not equal the matched node's range.
          (test-check (= 6 (edit-start (first (plan-edits
                                               (rewrite (fixture-backend response) snapshot
                                                        :language "javascript" :pattern "foo($A)"
                                                        :replacement "bar($A)")))))))
        (let ((duplicate (argo:json-decode output)))
          (setf (aref duplicate 1) (aref duplicate 0))
          (test-error ':backend-contract
                      (lambda () (query (fixture-backend (argo:json-encode duplicate)) snapshot
                                        :language "javascript" :pattern "foo($A)")))))
      (test-error ':backend-contract
                  (lambda () (query (fixture-backend output :code 1) snapshot
                                    :language "javascript" :pattern "foo($A)")))
      (test-error ':output-limit
                  (lambda () (query (fixture-backend output :maximum-output-bytes 2) snapshot
                                    :language "javascript" :pattern "foo($A)"))))
    (dolist (response '("{}" "null" "\"x\"" "[" "[null]" "[1]" "[]"))
      (test-error ':backend-contract
                  (lambda () (query (fixture-backend response) snapshot
                                    :language "javascript" :pattern "foo($A)"))))
    (test-error ':backend-exit
                (lambda () (query (fixture-backend "[]" :code 2) snapshot
                                  :language "javascript" :pattern "foo($A)")))
    (test-error ':backend-failure
                (lambda () (query (make-ast-grep-backend :runner (lambda (&rest arguments)
                                                                  (declare (ignore arguments))
                                                                  (error "runner broke")))
                                  snapshot :language "javascript" :pattern "foo($A)")))
    (test-error ':query-limit
                (lambda () (query backend snapshot :language "javascript"
                                  :pattern                   (make-string 65537 :initial-element #\x))))
    (test-error ':invalid-query
                (lambda () (rewrite backend snapshot :language "javascript"
                                    :pattern "foo($A)" :replacement nil))))
  t)

(defun run-runner-lifecycle-tests ()
  "Exercise real process interruption and bounded stderr on POSIX test hosts."
  (dolist (command (list "echo shell" nil '("echo" . "bad") '(1)))
    (test-error ':invalid-runner-request
                (lambda () (run-ast-grep command ""))))
  (when (probe-file "/bin/sh")
    (test-error ':timeout
                (lambda () (run-ast-grep '("/bin/sh" "-c" "exec sleep 10") ""
                                        :maximum-output-bytes 1024 :timeout 0.05)))
    (let ((calls 0))
      (test-error ':cancelled
                  (lambda () (run-ast-grep '("/bin/sh" "-c" "exec sleep 10") ""
                                          :maximum-output-bytes 1024 :timeout 30
                                          :cancelled-p (lambda () (> (incf calls) 3))))))
    (test-error ':output-limit
                (lambda () (run-ast-grep '("/bin/sh" "-c" "printf 123456789 >&2") ""
                                        :maximum-output-bytes 2 :timeout 30)))
    (test-check
     (catch 'stop
       (run-ast-grep '("/bin/sh" "-c" "exec sleep 10") ""
                    :maximum-output-bytes 1024 :timeout 30
                    :cancelled-p (let ((calls 0))
                                   (lambda () (when (> (incf calls) 3) (throw 'stop t)))))
       nil)))
  t)

(defun run-backend-tests ()
  "Run core plus real/injected backend and process-lifecycle checks."
  (let ((*test-checks* 0))
    (run-core-tests)
    (run-real-backend-tests)
    (run-runner-lifecycle-tests)
    (format t "clasted core + ast-grep: ~D checks passed.~%" *test-checks*)
    *test-checks*))
