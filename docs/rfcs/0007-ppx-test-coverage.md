# RFC 0007: PPX Test Coverage — Float, Null, and Compile-Error Negative Tests

| Field       | Value                                                    |
|-------------|----------------------------------------------------------|
| **RFC**     | 0007                                                     |
| **Title**   | PPX Test Coverage: Float, Null, and Compile-Error Negative Tests |
| **Status**  | Accepted                                                 |
| **Created** | 2026-02-19                                               |
| **Session** | 7                                                        |

---

## Summary

Add missing test coverage for the `olog_ppx` PPX rewriter. Three categories
of PPX behaviour currently have zero tests:

1. **Float literal auto-wrapping** — `("k", 3.14)` should produce
   `("k", Olog.Value.Float 3.14)`.
2. **Backtick shorthands beyond `` `Int ``** — `` `Float e ``,
   `` `String e ``, `` `Bool e ``, and `` `Null `` are implemented in
   `ppx/ppx_olog.ml` (lines 46–50) but only `` `Int `` has a test case.
3. **Compile-error negative tests** — the three `Location.raise_errorf`
   paths in `expand_log` (lines 96–97, 104–105, 107–108) are not
   exercised by any test. Malformed PPX payloads should produce clear,
   actionable compile errors rather than cryptic ppxlib internals.

All changes are pure test additions. No production code is modified.

---

## Problem

`test/test_ppx.ml` has eight test cases. They cover int literal, string
literal, bool literal, backtick `` `Int ``, no-fields form, `src_pos`,
entry count, and `is_enabled` guard. The following implemented behaviours
have no test coverage:

| PPX feature                  | Implementation line(s) | Test exists? |
|------------------------------|------------------------|--------------|
| Float literal → `Value.Float`| `ppx_olog.ml:41`       | No           |
| `` `Float e `` → `Value.Float`| `ppx_olog.ml:47`      | No           |
| `` `String e `` → `Value.String`| `ppx_olog.ml:48`   | No           |
| `` `Bool e `` → `Value.Bool` | `ppx_olog.ml:49`       | No           |
| `` `Null `` → `Value.Null`   | `ppx_olog.ml:50`       | No           |
| Error: non-string message (2-arg) | `ppx_olog.ml:96–97` | No       |
| Error: non-string message (3-arg) | `ppx_olog.ml:104–105` | No     |
| Error: wrong arity           | `ppx_olog.ml:107–108`  | No           |

Untested code is unverified code (Article III). If a future refactor of
`wrap_value` or `expand_log` breaks any of these branches, no test will
catch the regression.

---

## Scope

**In scope:**

- Add Alcotest runtime tests to `test/test_ppx.ml` for:
  float literal auto-wrapping, backtick `` `Float ``, backtick `` `String ``,
  backtick `` `Bool ``, and backtick `` `Null ``.
- Add dune cram tests (`test/ppx_errors.t`) exercising the three
  `Location.raise_errorf` error paths and asserting that each produces the
  expected compiler error message.
- Add the cram test stanza to `test/dune`.
- Verify the full quality gate passes after the change.

**Out of scope:**

- Modifying `ppx/ppx_olog.ml` (no PPX behaviour changes).
- Adding new PPX features or error messages.
- Testing expansion AST structure (e.g., via `ppx_expect` or `ppx_deriving`
  test drivers) — runtime integration tests are sufficient per Article IV.
- Changes to `lib/`, `examples/`, or the public API.
- CI pipeline changes.

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | A test case asserts that `[%log.info logger "data" [("pi", 3.14)]]` produces an entry whose `fields` list contains `("pi", Value.Float 3.14)`. Float equality uses `Value.Float` structural equality (OCaml `float` structural equality is safe for non-NaN finite literals like `3.14`). |
| F2  | A test case asserts that `` [%log.info logger "data" [("x", `Float t)]] `` where `t` is a `float` binding produces an entry whose `fields` list contains `("x", Value.Float t)`. |
| F3  | A test case asserts that `` [%log.info logger "data" [("s", `String v)]] `` where `v` is a `string` binding produces an entry whose `fields` list contains `("s", Value.String v)`. |
| F4  | A test case asserts that `` [%log.info logger "data" [("ok", `Bool b)]] `` where `b` is a `bool` binding produces an entry whose `fields` list contains `("ok", Value.Bool b)`. |
| F5  | A test case asserts that `` [%log.info logger "data" [("k", `Null)]] `` produces an entry whose `fields` list contains `("k", Value.Null)`. |
| F6  | A cram test compiles a file containing `[%log.info logger 42]` (non-string second argument, 2-arg form) and asserts the compiler output contains the substring `the second argument must be a string literal`. |
| F7  | A cram test compiles a file containing `[%log.info logger 42 []]` (non-string second argument, 3-arg form) and asserts the compiler output contains the substring `the second argument must be a string literal`. |
| F8  | A cram test compiles a file containing `[%log.info logger]` (wrong arity — only one expression, no message) and asserts the compiler output contains the substring `expected \`logger "msg"\` or \`logger "msg" [fields]\``. |
| F9  | All eight existing test cases in `test/test_ppx.ml` continue to pass unchanged. |
| F10 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | No new opam dependencies. Cram tests use dune's built-in `(cram ...)` stanza; no `ppx_expect` or `ppx_inline_test`. |
| NF2 | Cram test `.t` files live under `test/` alongside the existing test files. |
| NF3 | The float-comparison approach in F1 does not use `Alcotest.float` with an epsilon — `Value.Float 3.14` is compared structurally via `List.mem`, consistent with the existing int/string/bool tests. This is safe because `3.14` is a finite, non-NaN float literal whose `float` representation is deterministic. |
| NF4 | `opam-dune-lint` reports `olog.opam: OK`. |

---

## Public Interface

No public interface changes. This RFC adds only test files.

---

## Options Considered

### Option A: Cram tests for negative compile-error cases — chosen

Use dune's built-in `(cram ...)` stanza to write `.t` files that invoke
`ocamlfind ocamlc` (or `ocamlfind ocamlopt`) on small `.ml` snippets
containing malformed PPX payloads, then assert on the compiler's stderr
output containing the expected error message substring.

Each negative case is a separate `.ml` file under `test/ppx_errors/`
compiled within the cram test. The `.t` file captures the expected output.

**Pros:**
- Dune natively supports cram tests — no new dependencies.
- Tests run as part of `dune test` with no extra configuration beyond a
  `(cram ...)` stanza.
- The `.t` file is a human-readable transcript: input commands on the left,
  expected output on the right. Easy to review and update (`dune promote`).
- Completely decoupled from the Alcotest runtime tests — a cram failure
  does not break unrelated positive tests.

**Cons:**
- Introduces a second test style (cram) alongside Alcotest. However, cram
  tests are the standard dune mechanism for testing compiler output and
  are used by ppxlib itself.
- Cram tests are slightly slower than in-process tests due to process
  spawning, but three compile-error tests add negligible wall time.

### Option B: `ppx_expect` inline expect tests

Use `ppx_expect` to test PPX expansion output and error messages as inline
expect blocks.

**Pros:** Single test file, in-process, fast.

**Cons:** Adds `ppx_expect` (and transitively `ppx_inline_test`, `base`,
`ppx_sexp_conv`) as test dependencies — a significant footprint increase
for three tests. The project explicitly avoids heavy Jane Street
dependencies. **Rejected.**

### Option C: Skip negative tests; only add positive coverage

Add float/null/backtick tests to `test/test_ppx.ml` and leave the error
paths untested.

**Pros:** Minimal change; no new test infrastructure.

**Cons:** The three `Location.raise_errorf` paths remain unverified. A
future refactor could silently turn a clear PPX error into a cryptic
ppxlib internal error. Violates Article III (test-first, no untested code
paths). **Rejected.**

---

## Decision

We choose **Option A**. Positive tests go into the existing
`test/test_ppx.ml` as Alcotest cases. Negative compile-error tests go into
a dune cram test under `test/ppx_errors.t` with small `.ml` input files in
`test/ppx_errors/`. This avoids new dependencies while covering all
untested PPX code paths.

---

## Open Questions

None. All implementation details are straightforward.

---

## Future Work

- Additional backtick shorthand tests for edge cases (e.g., `` `Int (f x) ``
  where the argument is a function application) could be added later.
- If the PPX gains new features (e.g., format-string interpolation, lazy
  message evaluation), their tests should follow the same dual strategy:
  Alcotest for runtime behaviour, cram for compile-error messages.
