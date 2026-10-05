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

## Optional ast-grep backend

Load `clasted/ast-grep` to add UIOP and Argo. Install ast-grep separately, or pass
an existing executable pathname to `make-ast-grep-backend :program`.

```lisp
(let* ((backend (clasted:make-ast-grep-backend :program "ast-grep"))
       (snapshot (clasted:make-snapshot
                  :file "workspace:example.js" :revision "retained-resource-revision"
                  :text "foo(1);"))
       (plan (clasted:rewrite backend snapshot :language "javascript"
                              :pattern "foo($A)" :replacement "bar($A)")))
  (clasted:plan-preview plan)) ; => "bar(1);"
```

The adapter passes only `run --stdin --json=compact`, explicit language/pattern,
and an optional rewrite template. ast-grep returns the proposed replacements in
JSON. Source remains an immutable stdin observation. The adapter validates:

- An array with a bounded result count and coherent exit status (0 with matches,
  1 with an empty array).
- `file` equal to `STDIN`, typed language, positions and byte-offset ranges.
- Matched text equal to the exact UTF-8 source span.
- Required rewrite text and `replacementOffsets`, which can differ from the
  matched node range.
- Exact byte boundaries, ordered nonoverlapping edits and preview byte bounds.

JSON line/column fields are presentation metadata. Use validated byte offsets
for conversion to Common Lisp character indices, including astral Unicode.
Nested matches are valid query results; nested replacements fail with
`:overlapping-edits` instead of choosing an arbitrary rewrite order.

Constructor options are `:maximum-output-bytes` (8 MiB per stream),
`:maximum-matches` (10,000), `:maximum-preview-bytes` (16 MiB), `:timeout`
(30 seconds), `:cancelled-p`, and `:runner`. Language, pattern and template are
individually bounded to 64 KiB UTF-8. Structural JSON limits bound depth, nodes,
arrays, strings and numbers during parsing.

An injected runner has this contract:

```lisp
(lambda (argv stdin &key maximum-output-bytes timeout cancelled-p)
  ;; Capture bounded UTF-8 output, enforce timeout/cancellation and reap.
  (values stdout-string stderr-string exit-code))
```

`run-ast-grep` is the default runner. It launches an argument vector without a
shell, writes input into an owned temporary spool, polls process liveness,
timeout, cancellation and output spool sizes, then loads bounded UTF-8 output.
It terminates and reaps the child on errors and nonlocal exits. Spool growth
between polling intervals can exceed the configured bound; oversized output is
rejected before loading it into Lisp. Inject a runner for application command
authorization, process supervision or stronger spool constraints.

Catch `structural-error` and inspect `structural-error-code`: invalid requests,
invalid spans, source/query/result/output/preview limits, backend launch/exit/
contract/failure/output errors, timeout, cancellation, and overlapping edits
have distinct keywords. Reports contain no source or captured process output.

## Verification and upstream contract

Set `CLASTED_AST_GREP` to a real executable and run
`(asdf:test-system "clasted/ast-grep/tests")`. The default is `ast-grep` on PATH.
A missing executable fails this suite. Tests cover real JavaScript, Python and
Rust queries/rewrites, multibyte/astral Unicode, CRLF, empty rewrites, nested
matches, option-like templates, malformed queries, invalid languages and result
bounds. Injected contract tests mutate captured real-backend JSON rather than
inventing an unrelated response format. POSIX hosts additionally exercise real
process timeout, cancellation, stderr limits and nonlocal unwind cleanup.

Inspected upstream on 2026-10-05:

- Repository: https://github.com/ast-grep/ast-grep
- Commit: `029430eac79159575b36d35d75886e9c8ef81f00`, version `0.45.3`.
- CLI contract: `crates/cli/src/run.rs`, especially JSON printer selection,
  `RunWithSpecificLang::parse_stdin`, and match/no-match exit codes.
- JSON schema: `crates/cli/src/print/json_print.rs`, including UTF-8
  `range.byteOffset`, character position metadata and `replacementOffsets`.
- Official CLI reference: https://ast-grep.github.io/reference/cli.html

A real 0.45.3 executable was built and tested on NetBSD x86-64 using upstream
Cargo.lock and `cargo build --release --locked -p ast-grep`. Build artifacts
were confined to the workspace `.cache` checkout; no system installation was
performed. For a separately scoped dependency cache, set `CARGO_HOME` to a
workspace `.cache` directory when building.
