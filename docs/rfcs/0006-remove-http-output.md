# RFC 0006: Remove HTTP Output Destination

| Field       | Value                          |
|-------------|--------------------------------|
| **RFC**     | 0006                           |
| **Title**   | Remove HTTP Output Destination |
| **Status**  | Accepted                       |
| **Created** | 2026-02-19                     |
| **Session** | 6                              |

---

## Summary

Remove `Output.http` and the `cohttp-eio` runtime dependency from the core
`olog` package before any public release. The current implementation opens a
new TCP connection per write with no pooling, retry, backoff, or circuit
breaker. Keeping it inflates the mandatory dependency footprint for every user
of the library — including those who only need `stdout` or `file` output. A
production-grade HTTP sink belongs in a future, opt-in `olog-http` package.

---

## Problem

`Output.http`, added in RFC 0004, makes `cohttp-eio` (and its transitive
dependencies: `http`, `uri`, `cohttp`, and others) a mandatory runtime
dependency of every application that links `olog`. A developer who only needs
`Output.stdout` or `Output.file` pays the full installation and compile-time
cost for an HTTP client they will never use.

The implementation itself is not production-grade:

- Opens a new TCP connection on every `write` call — no connection pooling.
- No retry or exponential backoff on transient network failure — entries are
  silently dropped when a POST fails.
- No circuit breaker — a permanently unreachable endpoint imposes latency on
  every log batch processed by the worker fiber.
- No back-pressure signal to the logger — a slow HTTP endpoint stalls the
  flush cycle for all sinks.

Removing an incomplete, dependency-heavy feature before the first public
release is a one-commit deletion. Removing it after a release requires a
semver major bump and a migration guide.

---

## Scope

**In scope:**

- Remove `val http` from `lib/output.mli` and its implementation block from
  `lib/output.ml`.
- Remove `cohttp-eio` from the `libraries` list in `lib/dune` (and its
  associated comment).
- Remove `cohttp-eio` as a runtime dependency from the `olog` package stanza
  in `dune-project` (which regenerates `olog.opam`).
- Remove `cohttp-eio` as a `:with-test` dependency from the `olog_ppx` package
  stanza in `dune-project` (it was added because `test_output.ml` compiled the
  HTTP tests; with those gone, the dep is unused).
- Remove the three HTTP test cases (`test_http_name`, `test_http_error_safety`,
  `test_http_close_noop`) and the `"Output.http"` group registration from
  `test/test_output.ml`.
- Update the module-level doc comment in `lib/output.mli` to remove the
  reference to HTTP output.
- Verify the full quality gate passes after the change.

**Out of scope:**

- Designing or implementing a replacement `olog-http` package.
- Any changes to `Output.t`, `Output.make`, `Output.file`, `Output.stdout`,
  `Output.stderr`, or `Output.to_sink`.
- Graceful-shutdown or lifecycle API changes (separate concern).
- Changes to the PPX (`ppx/ppx_olog.ml`) or public entry point
  (`lib/olog.ml` / `lib/olog.mli`).
- CI pipeline changes.

---

## Requirements

### Functional Requirements

| #  | Requirement |
|----|-------------|
| F1 | `val http` does not appear in `lib/output.mli` after the change. |
| F2 | `Output.http` is not callable from any consumer of the `olog` library — no deprecated alias, no backward-compat shim. |
| F3 | `test_http_name`, `test_http_error_safety`, `test_http_close_noop`, and the `"Output.http"` group registration are removed from `test/test_output.ml`. |
| F4 | All remaining `Output` test groups (`Output.make`, `Output.stdout`, `Output.stderr`, `Output.file`, `Output.to_sink`) continue to pass unchanged. |
| F5 | The module-level doc comment of `lib/output.mli` no longer references HTTP output. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | `cohttp-eio` does not appear in `lib/dune` after the change. |
| NF2 | `cohttp-eio` does not appear as a runtime dependency in the `olog` package stanza of `dune-project` or the generated `olog.opam`. |
| NF3 | `cohttp-eio` does not appear in the `olog_ppx` package stanza of `dune-project`. |
| NF4 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings after the change. |
| NF5 | `opam-dune-lint` reports `olog.opam: OK`. |

---

## Public Interface

After this change, `lib/output.mli` exposes exactly:

```ocaml
(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches
    of entries and releasing resources. Built-in constructors cover stdout,
    stderr, and file (size-based rotation).

    {!t.write} never propagates exceptions — I/O errors are caught and a
    best-effort error line is written to the process stderr. Use {!to_sink} to
    adapt an {!t} for use with [Logger.Config.sinks]. *)

type t = {
  name  : string;
  write : Entry.t list -> unit;
  close : unit -> unit;
}

val make   : name:string -> formatter:Formatter.t -> _ Eio.Flow.sink -> t
val stdout : env:< stdout : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
val stderr : env:< stderr : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
val file   : env:_ -> formatter:Formatter.t -> path:_ Eio.Path.t -> max_bytes:int -> unit -> t
val to_sink : t -> Logger.sink

(* val http — removed; no deprecation alias *)
```

`Output.http` is not deprecated — it is completely removed. There is no
migration path within the `olog` package. Users who need HTTP output can
implement `Output.make` with a custom flow, or wait for a future `olog-http`
package.

---

## Options Considered

### Option A: Remove `Output.http` entirely — chosen

Remove the function, its implementation, its test cases, and the `cohttp-eio`
dependency from the core package.

**Pros:**
- Reduces the mandatory transitive dependency closure of every `olog` user.
- Eliminates an incomplete implementation before it becomes a public API
  commitment that requires a major version bump to undo.
- The diff is entirely deletions — zero risk of regressions in retained code.
- A future `olog-http` package can design pooling, retry, and circuit-breaking
  correctly without being constrained by the existing incomplete interface.

**Cons:**
- Any user of the development branch who called `Output.http` must update
  their code. (No such users exist pre-release, so this cost is zero.)

### Option B: Keep `Output.http` but mark it `[@alert deprecated]`

Emit a compile-time alert on every call to `Output.http`, directing users to a
future `olog-http` package.

**Pros:** Non-breaking at the source level; existing callers get a warning
rather than a compile error.

**Cons:** `cohttp-eio` remains in the runtime dependency closure for *all*
users, which is the primary motivation for removal. A deprecated function that
still compiles is not meaningfully different from an active one from a
packaging standpoint. **Rejected.**

### Option C: Move `Output.http` into an `olog_http` sub-library

Create an `http/` directory alongside `lib/` with its own dune stanza,
exporting a separate `olog_http` library so that `cohttp-eio` is not in the
`olog` closure.

**Pros:** Users who want HTTP can add `olog_http` to their deps; core users
pay no cost.

**Cons:** The sub-library would expose the same incomplete, no-pooling
implementation under a new name. Moving a broken implementation to a new
package without fixing it produces a worse outcome than removing it outright.
The correct path is removal now and a properly designed `olog-http` package
later. **Rejected.**

---

## Open Questions

None. The change is pure deletion with no design decisions required.

---

## Future Work

A future `olog-http` package (tracked separately) should include:

- Connection pooling (reuse across `write` calls via a client held in closure).
- Configurable retry with exponential backoff and a jitter term.
- A circuit breaker to avoid stalling the logger worker on permanently dead
  endpoints.
- Integration with `Eio.Switch` for graceful shutdown.

The current `Output.t` record-of-functions interface is sufficient for a basic
`olog-http` adapter: the `write` field can close over a pooled client
reference. A richer lifecycle API beyond the current `close` field is a
separate design question and should be addressed in its own RFC if required.
