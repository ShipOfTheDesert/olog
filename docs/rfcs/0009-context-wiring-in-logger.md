# RFC 0009: Context Wiring in Logger

| Field       | Value                                              |
|-------------|----------------------------------------------------|
| **RFC**     | 0009                                               |
| **Title**   | Context Wiring in Logger                           |
| **Status**  | Draft                                              |
| **Created** | 2026-02-19                                         |
| **Session** | 9                                                  |

---

## Problem

The `Context` module (RFC 0002) provides fiber-local storage of structured
fields via `Context.with_context` and `Context.current`. However,
`Logger.log` and `Logger.log_exn` never call `Context.current ()`. The
fiber-local context propagation module is completely inert — fields set
via `Context.with_context` do not appear in any emitted log entry.

This is the most visible correctness gap in the library.
`examples/structured.ml` carries a `(* FUTURE *)` comment marking it,
and both RFC 0002 (§Out of Scope) and RFC 0003 (§Out of Scope)
explicitly deferred this work to a later session.

The consequence is that users who want correlation fields (e.g.,
`request_id`, `trace_id`) to appear in every log entry within a scope
must manually thread them through every `[%log.*]` call:

```ocaml
Context.with_context ~fields:[("request_id", Value.String "req-abc123")]
@@ fun () ->
(* Context fields are set but completely ignored by Logger.log *)
[%log.info logger "started" [("request_id", "req-abc123")]];  (* manual *)
[%log.info logger "done"    [("request_id", "req-abc123")]];  (* manual *)
```

This defeats the purpose of `Context` entirely. A production logging
library with fiber-local context must wire that context into emitted
entries automatically.

---

## Scope

**In scope:**

- Write a "red phase" integration test that exercises the expected
  behavior (context fields appearing in emitted entries) and confirm it
  fails against the current implementation. This test is written and
  committed before any production code changes, per Article III.
- Modify `Logger.log` to call `Context.current ()` at the call site
  (in the calling fiber), merge the context fields with any
  user-supplied `~fields`, and pass the merged list to `Entry.create`.
- Apply the same change to `Logger.log_exn`, maintaining the existing
  merge order (context < user fields < exception fields).
- Document the merge precedence in `logger.mli`: call-site `~fields`
  override context fields; exception fields (in `log_exn`) override
  both.
- Add integration tests: log inside `Context.with_context`, verify
  context fields appear in the emitted entry; log outside, verify they
  don't.
- Add a merge-precedence test: set a field in context and pass the
  same key in `~fields`, verify the call-site value wins.
- Add a test for `log_exn` with context: verify context fields,
  user fields, and exception fields all appear with correct precedence.
- Update `examples/structured.ml` to remove the `(* FUTURE *)` comment
  and demonstrate that context fields appear automatically.
- Verify the full quality gate passes.

**Out of scope:**

- Changes to `Entry.t` or `Entry.create`. The merged field list is
  passed through the existing `~fields` parameter.
- Changes to `Context.t`, `Context.current`, or `Context.with_context`.
  The context module is complete as designed.
- Changes to the PPX. The PPX delegates to `Logger.log` / `Logger.log_exn`;
  context wiring at the `Logger` level means the PPX needs no changes.
- Changes to formatters or output destinations. Context fields are
  ordinary `(string * Value.t)` entries in the fields list and are
  already serialised correctly.
- Context inheritance across forked fibers. Forked fibers start with
  empty context by design (RFC 0002, Article X.1). This RFC does not
  change that.
- Performance optimisation of context snapshot cost (e.g., lazy copy,
  reference sharing). `Context.current ()` already returns a list
  value; copying semantics are handled by the existing implementation.

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F0  | Before any production code changes, a red-phase integration test is written that logs inside `Context.with_context` and asserts that the emitted entry's fields contain the context fields. This test must fail against the current implementation (confirming the gap exists) and pass after the wiring is implemented. |
| F1  | `Logger.log` calls `Context.current ()` in the calling fiber before constructing the `Entry.t`. The returned context fields are merged with any user-supplied `~fields`. |
| F2  | Merge precedence for `Logger.log`: call-site `~fields` override context fields on key collision. Implementation: `context @ user_fields`, since `Entry.dedup_fields` keeps the last occurrence of duplicate keys. |
| F3  | `Logger.log_exn` calls `Context.current ()` in the calling fiber. Merge precedence: context fields < user fields < exception fields. Implementation: `context @ user_fields @ exn_fields`. |
| F4  | When `Context.current ()` returns `[]` (no active `with_context` scope), `Logger.log` and `Logger.log_exn` behave identically to the current implementation — no empty list is prepended, no extra allocation occurs beyond the `Context.current ()` call itself. |
| F5  | Context is captured in the calling fiber, not in the worker fiber. The worker fiber's `Context.current ()` would return `[]` (it runs outside any `with_context` scope). The `Entry.t` must be fully constructed — including merged context — before being enqueued. |
| F6  | When `is_enabled` returns `false`, `Context.current ()` is not called. Zero work is done for disabled levels. |
| F7  | An integration test logs inside `Context.with_context ~fields:[("request_id", Value.String "req-abc123")]` and verifies the emitted entry's `fields` contains `("request_id", Value.String "req-abc123")`. |
| F8  | An integration test logs outside any `with_context` scope and verifies no unexpected context fields appear. |
| F9  | A merge-precedence test sets `("k", Value.String "ctx")` in context and passes `[("k", Value.String "explicit")]` as `~fields`. The emitted entry contains `("k", Value.String "explicit")` — the call-site value wins. |
| F10 | A test for `log_exn` with active context verifies that context fields, user fields, and exception fields all appear in the emitted entry, and that on key collision `exn.name` from the exception takes precedence over a user-supplied `("exn.name", ...)`. |
| F11 | A test with nested `Context.with_context` scopes verifies that the inner (deeper) context fields appear in the emitted entry, consistent with Context's "deeper wins" merge semantics. |
| F12 | `examples/structured.ml` is updated to remove the `(* FUTURE *)` comment. When run, the emitted JSON entries include `"request_id": "req-abc123"` without it being listed in each `[%log.*]` call's fields. |
| F13 | All existing tests in `test/test_logger.ml`, `test/test_context.ml`, `test/test_ppx.ml`, and `test/ppx_errors.t` continue to pass unchanged. |
| F14 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | No new opam dependencies. |
| NF2 | When the level is disabled, `Context.current ()` is not called. The `is_enabled` guard prevents all work, including context snapshot. |
| NF3 | `Context.current ()` outside any `with_context` scope returns `[]` via a caught `Effect.Unhandled` exception. This is a lightweight operation (no heap allocation beyond the empty list) and is acceptable per-log-call overhead. |
| NF4 | OCaml >= 5.2, Eio >= 1.0. No new API surface from `Context` or `Entry` is required. |
| NF5 | `opam-dune-lint` reports `olog.opam: OK`. |

---

## Public Interface

### `Logger` module changes (`lib/logger.mli`)

No signature changes. The types of `log` and `log_exn` are unchanged.
The behavioral change is documented in updated doc comments:

```ocaml
val log :
  t ->
  level:Level.t ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log logger ~level ~fields ~src_pos message] enqueues an {!Entry.t} for
    async emission.

    The entry's fields are the merge of the current fiber-local context
    (see [Context.current]) and any user-supplied [~fields]. Call-site fields
    override context fields on key collision.

    If [level] is below the logger's minimum level, returns immediately without
    calling [Context.current] or allocating an [Entry.t]. If the queue is full,
    the entry is dropped and the drop counter is incremented — the calling fiber
    is never suspended.

    @param level Log severity.
    @param fields Structured key-value pairs (default [[]]).
      Override context fields with the same key.
    @param src_pos
      Source location, typically injected by a PPX (default [None]).
    @param message Human-readable log message. *)

val log_exn :
  t ->
  level:Level.t ->
  exn ->
  Printexc.raw_backtrace ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log_exn t ~level exn bt ?fields ?src_pos msg] logs [msg] at [level] with
    structured exception fields extracted from [exn] and [bt]:

    - [("exn.name", Value.String (Printexc.exn_slot_name exn))]
    - [("exn.message", Value.String (Printexc.to_string exn))]
    - [("exn.backtrace", Value.String (Printexc.raw_backtrace_to_string bt))]

    The entry's fields are the merge of fiber-local context, user-supplied
    [~fields], and exception fields, in that precedence order (exception fields
    win on collision, then user fields, then context fields). The [exn.] key
    prefix is reserved; user-supplied fields with this prefix will be
    overwritten.

    Like {!log}, this function never raises. If [level] is below the logger's
    minimum level, returns immediately without calling [Context.current] or
    capturing any fields. If the internal queue is full the entry is dropped
    and the drop counter is incremented.

    {b Backtrace recording:} [bt] is typically obtained by calling
    [Printexc.get_raw_backtrace ()] immediately after catching the exception.
    Backtrace recording must be enabled for this to return a non-empty trace;
    see [Printexc.record_backtrace]. The PPX extensions [[%log.<level>_exn ...]]
    handle this automatically, skipping the backtrace call when recording is
    disabled. *)
```

No new functions. No new types. No breaking changes.

---

## Options Considered

### Option A: Wire at Logger.log level — recommended

`Logger.log` and `Logger.log_exn` call `Context.current ()` inside the
`is_enabled` guard, prepend context fields to user fields, and pass the
merged list to `Entry.create`. The merge uses list concatenation
(`context @ user_fields`) relying on `Entry.dedup_fields` (keeps last
occurrence) for precedence.

**Pros:**
- Zero changes to `Entry.t`, `Entry.create`, `Context`, PPX, or
  formatters. Only `Logger.log` and `Logger.log_exn` are modified.
- Minimal blast radius — two functions change, doc comments updated.
- `is_enabled` guard ensures zero context work for disabled levels.
- Context is captured in the calling fiber (correct) because `Logger.log`
  runs in the calling fiber; only the `Eio.Stream.add` interacts with
  the worker.
- Consistent with how `log_exn` already merges exception fields — same
  concatenation + dedup pattern.
- PPX needs no changes — it delegates to `Logger.log` which now handles
  context automatically.

**Cons:**
- `Context.current ()` is called on every enabled log call, even when
  no `with_context` scope is active. The cost is one caught
  `Effect.Unhandled` exception returning `[]`. This is a lightweight
  operation but is not zero-cost.
- If a user has an extremely hot logging path with no context, the
  per-call overhead of `Context.current ()` is new. However, the
  existing `t.now ()` call (Eio clock read) already dominates per-call
  cost, so this is negligible in practice.

### Option B: Wire at Entry.create level

Add an optional `?context:(string * Value.t) list` parameter to
`Entry.create`. `Logger.log` passes `~context:(Context.current ())` and
`Entry.create` handles the merge internally.

**Pros:**
- Centralises merge logic in `Entry.create`, which already owns
  `dedup_fields`.
- Other callers of `Entry.create` (if any appear in the future) get
  context support automatically.

**Cons:**
- Changes the signature of `Entry.create` and `entry.mli`. Larger blast
  radius than Option A.
- `Entry.create` is a pure function that constructs an immutable record.
  Adding context awareness makes it depend on the "source of fields"
  semantics, which is a `Logger` concern, not an `Entry` concern.
- `Entry.create` would need to know about merge precedence (context <
  user < exn). This conflates the entry data structure with logging
  policy.
- No current caller of `Entry.create` other than `Logger` exists, so the
  "future-proofing" argument is speculative (YAGNI, Article IX).
- **Rejected.** Merge policy belongs in `Logger`, not `Entry`.

### Option C: Wire at PPX level

The PPX expansion calls `Context.current ()` at the expansion site and
prepends context fields to user fields before passing them to
`Logger.log`.

**Pros:**
- Context capture is visible in the expanded code — no "magic" inside
  `Logger.log`.
- Callers using `Logger.log` directly (without PPX) opt into context
  explicitly, avoiding any surprise fields.

**Cons:**
- Every PPX extension (`log.trace` through `log.fatal`, plus all six
  `_exn` variants — 12 extensions) must be modified.
- Direct callers of `Logger.log` (non-PPX usage) would not get context
  fields, creating an inconsistency: PPX calls include context, direct
  calls don't.
- Increases the expanded code size at every call site.
- If context wiring logic changes (e.g., merge order), the PPX must be
  updated and all call sites re-expanded.
- **Rejected.** Context wiring is a runtime concern; the PPX should
  remain a thin syntactic layer.

---

## Decision

We choose **Option A**. `Logger.log` and `Logger.log_exn` call
`Context.current ()` inside the `is_enabled` guard, prepend context
fields to user fields via list concatenation, and pass the merged list
to `Entry.create`. `Entry.dedup_fields` (which keeps the last
occurrence) ensures correct precedence: context < user < exception.

This approach has the smallest blast radius (two functions, doc comment
updates, no signature changes), maintains the PPX as a pure syntactic
layer, and is consistent with the existing field-merge pattern
established by `log_exn`.

---

## Open Questions

None. All design decisions are resolved.

---

## Future Work

- **Context inheritance for forked fibers:** If users need child fibers
  to inherit the parent's context, a follow-up RFC can propose an
  opt-in `Context.with_inheritable_context` using
  `Eio.Fiber.with_binding` instead of raw effects.
- **Lazy context snapshot:** If profiling reveals `Context.current ()`
  overhead on hot paths with no active context, a future optimisation
  could cache the "no handler installed" state. However, the caught
  `Effect.Unhandled` path is already cheap and unlikely to be a
  bottleneck.
