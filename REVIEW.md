# Structural backend review

Scope: immutable source observations, stable file/snapshot/match identities,
structural query results and ordered preview plans. Publication belongs to a
revision-guarded resource adapter such as cl-resources.

Inspected freshly cloned official ast-grep source:
https://github.com/ast-grep/ast-grep at
`029430eac79159575b36d35d75886e9c8ef81f00` (0.45.3), 2026-10-05.
No upstream tracked files were changed. Its Cargo.lock was used for a local
release build under the workspace cache.

`run.rs` selects JSONPrinter before interactive/update printers. In stdin mode
it parses one supplied string, uses the `STDIN` file identity, and returns match
or replacement records. `json_print.rs` serializes half-open UTF-8 byte offsets
and separate replacement offsets. Empty results use exit 1, successful matches
exit 0. Real Unicode and rewrite output confirmed these contracts.

The public backend protocol uses keyword language/pattern/template arguments.
The optional CLI backend supplies argv values with equals assignment, preserving
patterns and templates starting with a hyphen. It never supplies source paths,
update flags, command-only actions, or shell command strings.

The default runner owns temporary spools and always reaps its process. Memory
capture and parsed result bounds are enforced; spool disk growth can overshoot
between polling intervals. Applications can inject their own bounded runner to
compose command authority and process supervision.

Verification on NetBSD 11.0 x86-64 / SBCL 2.6.6:

- `(asdf:test-system "clasted")`: 62 assertions passed.
- `(asdf:test-system "clasted/ast-grep/tests")`: 122 assertions passed,
  including the 62 core assertions and real ast-grep 0.45.3 execution.
- Fresh named worker `clasted-verification` loaded the declared systems and
  passed both suites; suites were rerun after final source/API changes.
- `git diff --check` passed. All library Lisp sources compiled successfully.

The directory delimiter tool could not enumerate the checkout on this host
because its libc `dirfd` binding was missing. ASDF compilation and execution
verified the actual Lisp source instead; this was an Autolith tool issue rather
than a library failure.
