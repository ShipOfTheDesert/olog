# RFC 0010: Remove File Output Destination

| Field       | Value                              |
|-------------|------------------------------------|
| **RFC**     | 0010                               |
| **Title**   | Remove File Output Destination     |
| **Status**  | Draft                              |
| **Created** | 2026-02-20                         |
| **Session** | 10                                 |

---

## Summary

Remove `Output.file` and its associated size-based rotation logic from the
core `olog` package before any public release. The current implementation
reopens the file descriptor on every write call with no persistent handle,
making `close ()` a no-op and log rotation tools incompatible. Fixing these
issues (persistent handle, `reopen`, multi-copy rotation, SIGHUP support)
would add significant complexity, mutable state, and new API surface —
all to serve a use case that modern deployments have moved away from.

Production applications overwhelmingly log to stdout and delegate routing,
rotation, and retention to infrastructure (container runtimes, systemd
journal, log shippers). The `Output.make` escape hatch remains available
for users who genuinely need a custom file sink — they wire it themselves
with full control over handle lifecycle.

Removing an incomplete feature before the first public release is a
one-commit deletion. Removing it after a release requires a semver major
bump and a migration guide.

---

## Problem

`Output.file`, added in RFC 0004, has three concrete problems that
RFC 0010 (original draft) attempted to solve with persistent handles,
`reopen`, multi-copy rotation, and SIGHUP support:

1. **Performance.** Every log batch requires an `open` / `write` / `close`
   syscall triple via `Eio.Path.with_open_out`. On a hot path this adds
   20-40 ms/s of pure syscall overhead.

2. **Log rotation incompatibility.** Standard Unix rotation tools
   (`logrotate`, `newsyslog`) expect a persistent handle they can signal
   to reopen. The per-write-open design has nothing to reopen. The
   built-in size-based rotation keeps only one archive copy.

3. **No lifecycle management.** `close ()` is a no-op. The logger
   shutdown sequence cannot ensure the last bytes are flushed.

Fixing all three requires: a `~sw:Eio.Switch.t` parameter, a persistent
`Eio.Flow.sink ref`, a `reopen` field on both `Output.t` and
`Logger.sink`, multi-copy rename chains, `install_sighup_handler` via
`Eio_unix`, and TOCTOU guards for concurrent filesystem operations.
This is substantial complexity for a feature that modern deployments
do not use.

The 12-factor app methodology (widely adopted in containerised, cloud,
and Kubernetes environments) prescribes logging to stdout and treating
logs as event streams. The infrastructure layer — not the application —
handles persistence, rotation, and shipping. `Output.stdout` (backed by
`Output.make`) already serves this pattern.

Users who genuinely need file output can construct a custom sink via
`Output.make` with an `Eio.Flow.sink` they manage themselves. This
preserves full flexibility without burdening every `olog` user with
file lifecycle complexity in the core API.

---

## Scope

**In scope:**

- Remove `val file` from `lib/output.mli` and its implementation from
  `lib/output.ml` (including the `rotated_path` helper).
- Remove the eight `Output.file` test cases and the `"Output.file"` group
  registration from `test/test_output.ml`.
- Remove the file-specific test helpers (`tmp_path`, `rotated_path`,
  `cleanup`) from `test/test_output.ml`.
- Update the module-level doc comment in `lib/output.mli` to remove the
  reference to file output.
- Supersede ADR 0005 (`output-file-per-write-open`) — it documents a
  design decision for code that no longer exists.
- Verify the full quality gate passes after the change.

**Out of scope:**

- Designing or implementing a replacement `olog-file` package.
- Any changes to `Output.t`, `Output.make`, `Output.stdout`,
  `Output.stderr`, or `Output.to_sink`.
- Changes to `Logger.sink` — no `reopen` field is added.
- Changes to `Entry.t`, `Entry.create`, `Context`, or the PPX.
- Changes to `Formatter.t` or any formatter implementation.
- CI pipeline changes.

---

## Requirements

### Functional Requirements

| #  | Requirement |
|----|-------------|
| F1 | `val file` does not appear in `lib/output.mli` after the change. |
| F2 | `Output.file` is not callable from any consumer of the `olog` library — no deprecated alias, no backward-compat shim. |
| F3 | The `rotated_path` helper function is removed from `lib/output.ml`. |
| F4 | The eight `Output.file` test cases and the `"Output.file"` group registration are removed from `test/test_output.ml`. |
| F5 | The file-specific test helpers (`tmp_path`, `rotated_path`, `cleanup`) are removed from `test/test_output.ml`. |
| F6 | All remaining `Output` test groups (`Output.make`, `Output.stdout`, `Output.stderr`, `Output.to_sink`) continue to pass unchanged. |
| F7 | The module-level doc comment of `lib/output.mli` no longer references file output. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings after the change. |
| NF2 | `opam-dune-lint` reports `olog.opam: OK`. |
| NF3 | No new dependencies are introduced. |

---

## Public Interface

After this change, `lib/output.mli` exposes exactly:

```ocaml
(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches of
    entries and releasing resources. Built-in constructors cover stdout and
    stderr.

    {!t.write} never propagates exceptions — I/O errors are caught and a
    best-effort error line is written to the process stderr. Use {!to_sink} to
    adapt an {!t} for use with [Logger.Config.sinks]. *)

type t = {
  name : string;
  write : Entry.t list -> unit;
  close : unit -> unit;
}

val make   : name:string -> formatter:Formatter.t -> _ Eio.Flow.sink -> t
val stdout : env:< stdout : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
val stderr : env:< stderr : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
val to_sink : t -> Logger.sink

(* val file — removed; no deprecation alias *)
```

`Output.file` is not deprecated — it is completely removed. There is no
migration path within the `olog` package. Users who need file output can
construct a custom sink via `Output.make` with an `Eio.Flow.sink` they
manage, or wait for a future `olog-file` package.

---

## Options Considered

### Option A: Remove `Output.file` entirely — chosen

Remove the function, its implementation, its test cases, and the
associated rotation logic from the core package.

**Pros:**
- Eliminates an incomplete implementation before it becomes a public API
  commitment requiring a major version bump to remove.
- Removes the entire class of file-lifecycle problems (persistent handles,
  rotation, reopen, SIGHUP, TOCTOU races) from the core library.
- The diff is entirely deletions — zero risk of regressions in retained code.
- Aligns with 12-factor app methodology: log to stdout, let infrastructure
  handle the rest.
- `Output.make` remains available as an escape hatch for users who need
  custom file output with their own lifecycle management.
- Reduces the API surface and test maintenance burden.
- A future `olog-file` package can design persistent handles, rotation,
  and signal handling correctly without being constrained by the existing
  incomplete interface.

**Cons:**
- Users who relied on `Output.file` during development must update their
  code. (No such users exist pre-release, so this cost is zero.)

### Option B: Fix `Output.file` with persistent handle, rotation, and reopen

The original RFC 0010 draft. Replace per-write-open with a persistent
handle via `~sw:Eio.Switch.t`, add `reopen` to `Output.t` and
`Logger.sink`, implement multi-copy rotation, add
`install_sighup_handler`.

**Pros:** Addresses the three problems (performance, rotation
compatibility, lifecycle) and provides a complete file output story.

**Cons:**
- Adds significant complexity: mutable handle refs, byte counters,
  rename chains with TOCTOU windows, `Eio_unix` dependency for SIGHUP,
  new `reopen` field on `Output.t` and `Logger.sink`.
- Solves a problem that modern containerised deployments do not have —
  applications log to stdout, not files.
- The `~sw` parameter is a breaking API change, as is the `reopen` field
  on `Output.t` and `Logger.sink`.
- All of this complexity serves a single constructor (`Output.file`) that
  advanced users can build themselves via `Output.make`.
- **Rejected.** YAGNI (Article IX). The complexity is not justified for
  a pre-1.0 library targeting modern deployment patterns.

### Option C: Keep `Output.file` as-is

Leave the per-write-open implementation unchanged. Accept the performance
and lifecycle limitations.

**Pros:** Zero-diff. No API changes.

**Cons:** Ships an incomplete, subtly broken feature as public API. The
`close ()` no-op and rotation limitations become API commitments that
require a major version bump to fix post-release. Users may rely on
behaviour that will need to change. **Rejected.**

---

## Decision

We choose **Option A**. `Output.file` is removed entirely before the
first public release. The 12-factor stdout-first approach is the
recommended pattern. `Output.make` provides an escape hatch for custom
file sinks. A properly designed `olog-file` package can be built in the
future if demand materialises.

---

## Open Questions

None. The change is pure deletion with no design decisions required.

---

## Future Work

- **`olog-file` package:** A separate, opt-in package providing file
  output with persistent handles, configurable rotation (size-based and
  date-based), and SIGHUP-based reopen. Designed from scratch without
  the constraints of the core `olog` API.
