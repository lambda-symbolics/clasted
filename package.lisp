(defpackage #:clasted
  (:documentation "Structural queries over immutable source snapshots and previewed edit plans.")
  (:use #:cl)
  (:export #:structural-error #:structural-error-code
           #:snapshot #:make-snapshot #:snapshot-id #:snapshot-file
           #:snapshot-revision #:snapshot-text
           #:structural-match #:make-structural-match #:match-id #:match-snapshot-id
           #:match-start-byte #:match-end-byte #:match-start #:match-end #:match-text
           #:edit #:make-edit #:edit-start #:edit-end #:edit-replacement
           #:edit-plan #:make-edit-plan #:plan-snapshot #:plan-edits #:plan-preview
           #:backend #:backend-query #:backend-rewrite #:query #:rewrite
           #:ast-grep-backend #:make-ast-grep-backend #:run-ast-grep #:run-tests))
(in-package #:clasted)
