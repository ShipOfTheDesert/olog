# Contributing to olog

Thank you for considering a contribution to olog. This document describes the
principles, conventions, and workflow that every contributor must follow.
These rules exist to keep the codebase correct, minimal, and easy to change.

---

## Prerequisites

```bash
# OCaml toolchain
opam init
opam switch create 5.2.0
eval $(opam env)

# Project dependencies
opam install . --deps-only --with-test

# Verify everything builds
dune build && dune test
```

---

## Quality Gate

Every pull request must pass all five checks before merge:

```bash
dune build          # compiles without errors
dune test           # all tests pass
dune build @fmt     # ocamlformat compliance
dune build @doc     # odoc generation succeeds
opam-dune-lint      # opam/dune dependency alignment
```

Run all five locally before opening a PR. CI will reject anything that fails.

---

## Project Principles

The following articles govern all implementation decisions. They are
non-negotiable. If a contribution violates any article, it will be requested
to be revised during review.

### Article I — Library-First

Every feature is a standalone, reusable module. No feature is implemented
directly in application code. All public modules have a clear, minimal `.mli`.

Libraries must be:
- Self-contained with explicit, minimal opam dependencies
- Independently testable without the surrounding application
- Documented with `(** ... *)` doc comments at every public value

### Article II — Spec Before Code

No significant feature or architectural change begins without an approved
specification in `memory/spec.md`. The spec is the source of truth. Code
serves the spec — never the reverse. For small bug fixes, a clear issue
description serves the same purpose.

### Article III — Test-First (Non-Negotiable)

All implementation follows strict TDD:
1. Write tests that define the intended behaviour
2. Confirm tests **fail** (red phase)
3. Write the minimum implementation to make them pass (green phase)
4. Refactor under green

No `.ml` implementation file should exist before its corresponding test file
exists and is confirmed failing. PRs that add untested code paths will be
asked for tests before review proceeds.

### Article IV — Integration Testing Over Mocks

- Prefer real Eio environments (`Eio_main.run`) in tests over stubs
- Use `Eio.Mock` only when testing scheduler behaviour specifically
- All inter-module contracts have a dedicated contract test

### Article V — Simplicity Gate

Maximum 3 top-level public modules for the initial library:
`Olog` (main API), `Olog.Entry`, `Olog.Context`.
Internal submodules under `lib/internal/` are unrestricted.
Additional top-level modules require written justification in the PR
description. YAGNI is a hard constraint — build for the current spec, not
the imagined next one.

### Article VI — Observability by Default

The library itself is observable:
- Exposes internal metrics (queue depth, drop count, write latency)
- Provides a `diagnostics` function returning structured data, not opaque strings
- All output formatters produce valid, machine-parseable output (JSON by default)

### Article VII — Reversible by Default

Prefer approaches that are easy to change. Correctness first, performance
second. Document architectural decisions in the PR description or in
`quality_reports/session_logs/` so future contributors understand *why*
a choice was made.

### Article VIII — Verify Before Done

A task is not complete until:
- `dune build` exits 0
- `dune test` exits 0
- The quality gate (all five checks above) passes

Do not mark a PR as ready for review without this evidence.

### Article IX — Minimal Scope

Do exactly what the current task requires. Scope creep is a bug — note
future ideas in a comment `(* FUTURE: ... *)` and file a separate issue.
Do not act on them within the current PR.

### Article X — Functional Patterns (Non-Negotiable)

#### X.1 — Immutable by Default

All records are immutable unless mutation is explicitly justified.
`mutable` fields require a comment `(* mutable: justified because ... *)`.
Atomic values for shared counters are permitted and do not require
justification.

#### X.2 — Errors as Values

Never `raise` for expected failure cases. All fallible public functions
return `('a, error) result`. Internal helpers may use exceptions for truly
unrecoverable programmer errors only, and must be marked
`(* raises: ... *)`.

#### X.3 — Pattern Matching Over Conditionals

Exhaustive `match` on variants. Never use catch-all `_` where the compiler
can enforce exhaustiveness. When adding a variant, the compiler must guide
all necessary changes.

#### X.4 — Interpreter Pattern for Side Effects

- Core logic: pure functions producing values or `effect_plan` ADTs
- Interpreter: single impure function at the Eio boundary executing the plan
- Logging itself follows this: pure `Entry.t` construction, impure emission
  via the async worker fiber

#### X.5 — Composition Over Inheritance

Use modules, functors, and first-class modules for polymorphism.
No class hierarchies. The output destination system uses a record of
functions (vtable pattern) rather than classes.

---

## Code Conventions

- **Naming**: `snake_case` for all identifiers, module names `PascalCase`
- **Files**: one module per file; implementation in `lib/`, tests in `test/`
- **Test files**: named `test_<module>.ml`, e.g., `test_entry.ml` for `Entry`
- **Formatting**: run `dune fmt` before committing; the project uses
  ocamlformat with the config in `.ocamlformat`
- **Module interface**: every public module has a `.mli` file with
  `(** ... *)` doc comments on every exported value; internal helpers live
  under `lib/internal/` with no `.mli` exposed

---

## PR Workflow

1. **Create a branch** from `main` with a descriptive name
   (e.g., `feat/context-module`, `fix/level-compare`)
2. **Write tests first** — confirm they fail
3. **Implement** — minimum code to make tests pass
4. **Run the full quality gate** (all five checks)
5. **Open a PR** with:
   - A title under 60 characters in imperative mood
     (e.g., "Add fiber-local context propagation")
   - A summary explaining *what* changed and *why*
   - A bullet list of key changes
   - Testing instructions (`dune test`, specific test names to look at)
6. **Address review feedback** — fix issues and force-push or add commits
   as appropriate

---

## Review Checklist

Reviewers will verify every PR against the following:

- [ ] All articles (I–X) are respected
- [ ] Every public module has a `.mli` with doc comments
- [ ] No `raise` for recoverable errors (X.2)
- [ ] No `mutable` fields without justifying comments (X.1)
- [ ] Exhaustive `match` on all variants — no unnecessary `_` catch-alls (X.3)
- [ ] No I/O or Eio effects inside pure data-construction functions (X.4)
- [ ] No class hierarchies — record-of-functions where polymorphism is needed (X.5)
- [ ] Tests were written before implementation where possible
- [ ] All five quality gate checks pass
- [ ] Scope matches the stated goal — no unrelated changes

---

## Getting Help

- Open an issue for questions about architecture or conventions
- Tag `@maintainers` on a PR if you are unsure about an approach
- Read `memory/constitution.md` for the authoritative source of these principles
