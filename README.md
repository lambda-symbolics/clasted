# clasted

Portable Common Lisp structural queries and previewed rewrite plans.

The core `clasted` system depends on Babel and `ironclad/digest/sha256`.
Snapshots own copied source, caller-defined file identity, and an opaque resource
revision. SHA-256 identities include all three; match identities additionally
include the query and half-open UTF-8 byte span. Public string readers return
copies. Match character offsets are separate from byte offsets.

Construct observations with `make-snapshot :file :revision :text`, then call
`query backend snapshot :language :pattern` or
`rewrite backend snapshot :language :pattern :replacement`. Backends specialize
`backend-query` and `backend-rewrite`. Neither operation writes source files.

Use `make-structural-match :snapshot :query-id :start-byte :end-byte :text` in a
backend to validate a result against the exact source observation. Invalid
UTF-8 boundaries or mismatching text signal `structural-error`.

Use `make-edit :start :end :replacement` with Common Lisp character offsets,
then `make-edit-plan :snapshot :edits`. Plans contain immutable ascending edits
and a complete `plan-preview`. Overlapping, nested, duplicate edits and
coincident insertions are rejected. Adjacent edits and insertions at an earlier
edit's exclusive end are accepted. The default snapshot/preview bound is 16 MiB
UTF-8 and the edit count bound is 10,000; constructors accept explicit bounds.

`plan-snapshot`, `plan-edits`, `plan-preview`, `snapshot-file`,
`snapshot-revision`, and `snapshot-id` provide publication inputs. Revalidate the
resource revision before publishing the preview. For several files, construct
one plan per snapshot and publish all previews through one revision-guarded
resource change set. Authorization and atomic publication belong to the resource
adapter, not the structural backend.

Test the dependency-light core with `(asdf:test-system "clasted")`.
