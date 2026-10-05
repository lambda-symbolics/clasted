(asdf:defsystem "clasted"
  :description "Immutable structural queries and previewed edit plans"
  :author "Lambda Symbolics" :license "ISC" :version "0.1.0"
  :depends-on ("babel" "ironclad/digest/sha256")
  :serial t :components ((:file "package") (:file "structural"))
  :in-order-to ((asdf:test-op (asdf:test-op "clasted/tests"))))

(asdf:defsystem "clasted/ast-grep"
  :description "Optional ast-grep CLI backend for clasted"
  :depends-on ("clasted" "uiop" "argo")
  :serial t :components ((:file "ast-grep")))

(asdf:defsystem "clasted/tests"
  :depends-on ("clasted")
  :serial t :components ((:file "core-tests"))
  :perform (asdf:test-op (operation system)
             (declare (ignore operation system))
             (uiop:symbol-call :clasted :run-tests)))

(asdf:defsystem "clasted/ast-grep/tests"
  :depends-on ("clasted/tests" "clasted/ast-grep")
  :serial t :components ((:file "backend-tests"))
  :perform (asdf:test-op (operation system)
             (declare (ignore operation system))
             (uiop:symbol-call :clasted :run-backend-tests)))
