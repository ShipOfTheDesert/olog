# RFC 0008: Structured Error and Exception Capture

| Field       | Value                                              |
|-------------|----------------------------------------------------|
| **RFC**     | 0008                                               |
| **Title**   | Structured Error and Exception Capture              |
| **Status**  | Draft                                              |
| **Created** | 2026-02-19                                         |
| **Session** | 8                                                  |

---

## Summary

Add first-class exception logging to olog via a new runtime function
`Logger.log_exn` and corresponding PPX extensions
`[%log.<level>_exn ...]`. When a caller catches an OCaml exception,
they can log it with structured fields — exception constructor name,
human-readable message, and backtrace — captured at the call site
before the stack unwinds. No changes to `Value.t` or `Entry.t` are
required; exception metadata is represented as ordinary
`(string * Value.t) list` fields using the existing `Value.String`
constructor.

---

## Problem

The current workaround for logging exceptions is manual and lossy:

```ocaml
try risky_operation ()
with exn ->
  [%log.error logger "operation failed"
    [("exn", Printexc.to_string exn)]]
```

This has three deficiencies:

1. **Lost backtrace.** `Printexc.to_string` does not include the stack
   trace. By the time the entry reaches the async worker fiber, the
   calling fiber's backtrace is gone. There is no way to recover it
   after the fact.

2. **Unstructured blob.** A single `"exn"` field containing
   `"Failure(\"connection refused\")"` mixes the exception constructor
   name with the message payload. Log aggregators (Loki, Elasticsearch,
   Datadog) cannot index or alert on the exception type independently.

3. **Boilerplate.** Every exception-logging call site must manually call
   `Printexc.to_string`, choose field names, and remember to capture the
   backtrace. This is error-prone and inconsistent across a codebase.

A production logging library must make exception capture a first-class,
ergonomic operation that produces structured, queryable fields.

---

## Scope

**In scope:**

- Add `Logger.log_exn` runtime function that accepts an `exn` and
  `Printexc.raw_backtrace`, decomposes them into structured fields, and
  delegates to `Logger.log`.
- Add PPX extensions `[%log.<level>_exn ...]` for all six levels
  (`trace_exn`, `debug_exn`, `info_exn`, `warn_exn`, `error_exn`,
  `fatal_exn`) that auto-capture `Printexc.get_raw_backtrace ()` at the
  expansion site, guarded by a `Printexc.backtrace_status ()` check.
- Define a stable field-name schema for exception fields (`exn.name`,
  `exn.message`, `exn.backtrace`).
- Add tests for the runtime function and PPX extensions following
  Articles III and IV (test-first, integration over mocks).
- Update `logger.mli` with the new function and doc comments.
- Verify the full quality gate passes.

**Out of scope:**

- Extending `Value.t` with new constructors (e.g., `Array of t list`).
  If structured backtrace frames are needed in the future, that is a
  separate RFC.
- Modifying `Entry.t`. Exception fields use the existing
  `(string * Value.t) list` mechanism.
- Changes to formatters (`Formatter.json_formatter`,
  `Formatter.logfmt_formatter`). Exception fields are ordinary fields
  and are already serialised correctly by existing formatters.
- Automatic `Printexc.record_backtrace true` at library init. This is
  a global side effect; the caller is responsible for enabling backtrace
  recording.
- Structured backtrace frame parsing (e.g., `Printexc.backtrace_slots`
  into per-frame records). The backtrace is stored as a single
  `Value.String`.
- Error-as-value logging (e.g., `('a, 'e) result` unwrapping). This
  RFC addresses OCaml exceptions only.

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `Logger.log_exn t ~level exn bt ?fields ?src_pos msg` produces an entry whose `fields` list contains `("exn.name", Value.String name)` where `name` is `Printexc.exn_slot_name exn`. |
| F2  | The entry's `fields` list contains `("exn.message", Value.String message)` where `message` is `Printexc.to_string exn`. |
| F3  | The entry's `fields` list contains `("exn.backtrace", Value.String bt_str)` where `bt_str` is `Printexc.raw_backtrace_to_string bt`. When backtrace recording is not enabled, `bt_str` is the empty string `""`. |
| F4  | User-supplied `~fields` are merged with exception fields. Exception fields (`exn.name`, `exn.message`, `exn.backtrace`) appear after user fields in the list. Since `Entry.create` deduplicates by keeping the last occurrence, exception fields take precedence over any user field with a colliding key. |
| F5  | `Logger.log_exn` never raises, consistent with `Logger.log`. If the queue is full, the entry is dropped and the drop counter is incremented. |
| F6  | `[%log.error_exn logger exn "msg"]` (3-arg form) expands to code that (a) evaluates `logger` once, (b) checks `is_enabled`, (c) checks `Printexc.backtrace_status ()` and calls `Printexc.get_raw_backtrace ()` only when recording is enabled (otherwise uses an empty raw backtrace), and (d) calls `Logger.log_exn` with the captured backtrace, exception, and message. |
| F7  | `[%log.error_exn logger exn "msg" [("k", v)]]` (4-arg form) expands as F6 but additionally passes the user-supplied fields to `Logger.log_exn`. |
| F8  | PPX extensions exist for all six levels: `trace_exn`, `debug_exn`, `info_exn`, `warn_exn`, `error_exn`, `fatal_exn`. Each uses a distinct extension point name (e.g., `log.error_exn`), so arity is unambiguous with respect to the existing `log.error` extensions. |
| F9  | The PPX expansion captures `src_pos` (`__FILE__`, `__LINE__`, column) at the expansion site, consistent with the existing `[%log.<level> ...]` extensions. |
| F10 | The PPX `is_enabled` guard prevents evaluation of the exception expression, backtrace capture, and field construction when the level is disabled. |
| F11 | A compile-error test asserts that `[%log.error_exn logger]` (1-arg form, missing exception and message) produces a clear compile error. |
| F12 | A compile-error test asserts that `[%log.error_exn logger exn 42]` (non-string third argument) produces a compile error containing the substring `must be a string literal`. |
| F13 | All existing tests in `test/test_ppx.ml` and `test/ppx_errors.t` continue to pass unchanged. |
| F14 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | No new opam dependencies. |
| NF2 | When the level is disabled, zero work is done: no exception evaluation, no `Printexc.get_raw_backtrace ()`, no field construction. When the level is enabled but `Printexc.backtrace_status ()` is `false`, `Printexc.get_raw_backtrace ()` is skipped and `exn.backtrace` is set to `""`. |
| NF3 | The `exn.*` field names are reserved. Documentation in `logger.mli` warns that user-supplied fields with the `exn.` prefix will be overwritten by `log_exn`. |
| NF4 | OCaml >= 5.2, Eio >= 1.0. All APIs used (`Printexc.exn_slot_name`, `Printexc.get_raw_backtrace`, `Printexc.raw_backtrace_to_string`, `Printexc.backtrace_status`) are available since OCaml 4.02+. |
| NF5 | `opam-dune-lint` reports `olog.opam: OK`. |

---

## Public Interface

### `Logger` module addition (`lib/logger.mli`)

```ocaml
val log_exn :
  t ->
  level:Level.t ->
  exn ->
  Printexc.raw_backtrace ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log_exn t ~level exn bt ?fields ?src_pos msg] logs [msg] at [level]
    with structured exception fields extracted from [exn] and [bt]:

    - [("exn.name", Value.String (Printexc.exn_slot_name exn))]
    - [("exn.message", Value.String (Printexc.to_string exn))]
    - [("exn.backtrace", Value.String (Printexc.raw_backtrace_to_string bt))]

    Exception fields are appended after any user-supplied [~fields] and take
    precedence on key collision. The [exn.] key prefix is reserved.

    Like {!log}, this function never raises. If the internal queue is full the
    entry is dropped and the drop counter is incremented.

    {b Backtrace recording:} [bt] is typically obtained by calling
    [Printexc.get_raw_backtrace ()] immediately after catching the exception.
    Backtrace recording must be enabled for this to return a non-empty trace;
    see [Printexc.record_backtrace]. The PPX extensions
    [\[%log.<level>_exn ...\]] handle this automatically, skipping the
    backtrace call when recording is disabled. *)
```

### PPX extensions (`ppx/ppx_olog.ml`)

```ocaml
(* 3-arg form: logger, exception, message *)
[%log.error_exn logger exn "request failed"]

(* 4-arg form: logger, exception, message, fields *)
[%log.warn_exn logger exn "retrying" [("attempt", attempt_num)]]
```

Expansion of `[%log.error_exn logger exn "msg" [fields]]`:

```ocaml
let __olog_logger = logger in
if Olog.Logger.is_enabled __olog_logger Olog.Level.Error then
  let __olog_bt =
    if Printexc.backtrace_status () then Printexc.get_raw_backtrace ()
    else Printexc.get_callstack 0
  in
  Olog.Logger.log_exn __olog_logger ~level:Olog.Level.Error exn __olog_bt
    ~fields:[fields]
    ~src_pos:{ Olog.Entry.file = "foo.ml"; line = 10; col = 4 }
    "msg"
```

The 3-arg form (no user fields) omits `~fields`.

Note: `Printexc.get_callstack 0` returns an empty `raw_backtrace`,
serving as the zero-cost empty value when recording is disabled.

---

## Options Considered

### Option A: String-only fields, no type changes — recommended

Exception metadata is represented as three `Value.String` fields using
the existing `(string * Value.t) list` mechanism. The backtrace is a
single multi-line string (output of `Printexc.raw_backtrace_to_string`).

**Pros:**
- Zero breaking changes to `Value.t`, `Entry.t`, or formatters.
- Existing JSON and logfmt formatters serialize exception fields
  correctly without modification.
- Minimal implementation surface: one new function in `Logger`, six new
  PPX extensions reusing the existing `make_extension` pattern.
- Aligned with YAGNI (Article IX) — solves the immediate problem without
  speculative type extensions.
- The `exn.name` field is independently queryable by log aggregators,
  solving the primary indexing complaint.

**Cons:**
- `exn.backtrace` is a multi-line string blob. Log aggregators that
  want per-frame indexing must parse the string themselves. However,
  this matches the representation used by most logging libraries in
  other ecosystems (e.g., Python's `exc_info`, Java's
  `getStackTrace().toString()`).
- No `Value.Array` means backtrace frames cannot be queried
  individually via olog's own `Value.t` — but this is an aggregator
  concern, not a library concern.

### Option B: Extend `Value.t` with `Array of t list`

Add a new constructor `Array of t list` to `Value.t`. Backtrace frames
are parsed via `Printexc.backtrace_slots` and stored as an array of
strings (or structured records).

**Pros:**
- Backtrace frames are individually addressable in the structured log
  output (e.g., `fields.exn.backtrace[0]` in Elasticsearch).
- `Value.Array` is independently useful for other structured data
  (e.g., lists of tags, request IDs).
- Aligns with JSON log aggregator conventions.

**Cons:**
- Breaking change to `Value.t` — every pattern match across the
  codebase (formatters, serializers, PPX `wrap_value`, tests) must be
  updated.
- `Value.to_yojson` / `Value.of_yojson` become recursive.
- `Printexc.backtrace_slots` returns `backtrace_slot option array` —
  slots can be `None` (unknown frames), requiring defensive handling.
- Significantly larger scope for what is primarily an
  exception-logging feature. Violates Article IX (minimal scope).
- **Rejected** for this RFC. Can be proposed separately if demand for
  structured backtrace frames materialises.

### Option C: Dedicated `exn_info` record in `Entry.t`

Add an optional `exn_info` field to `Entry.t`:

```ocaml
type exn_info = {
  name : string;
  message : string;
  backtrace : string;
}

type t = {
  (* ... existing fields ... *)
  exn_info : exn_info option;
}
```

**Pros:**
- Semantically clean — exception data is structurally distinct from
  user fields, not mixed into the same key-value list.
- No key-collision concerns with user-supplied fields.
- Formatters can render exception info in a dedicated section.

**Cons:**
- Changes `Entry.t`, `Entry.create`, `Entry.to_yojson`, and all
  formatters. Moderate blast radius.
- The `exn_info` field is `option`, adding a branch to every formatter
  and serializer.
- Breaks the current simplicity where all structured data lives in
  `fields`. Introduces a second data channel that must be threaded
  through the entire pipeline (entry -> queue -> worker -> formatter ->
  output).
- Over-engineers the solution. Exception fields are just fields — they
  don't need special structural treatment. The reserved `exn.` prefix
  achieves namespace separation without type-level changes.
- **Rejected** for this RFC.

---

## Decision

We choose **Option A**. Exception metadata is represented as three
`Value.String` fields (`exn.name`, `exn.message`, `exn.backtrace`)
appended to the entry's existing `fields` list. A new `Logger.log_exn`
function decomposes the exception and backtrace into these fields and
delegates to `Logger.log`. Six PPX extensions (`[%log.<level>_exn ...]`)
provide ergonomic call-site capture with automatic backtrace retrieval
and `is_enabled` guarding. A `Printexc.backtrace_status ()` check
avoids throwaway backtrace-capture work when recording is disabled.

This approach solves the structured-exception-logging problem with zero
breaking changes, minimal scope, and full backward compatibility.

---

## Open Questions

None. All design decisions are resolved.

---

## Future Work

- **Structured backtrace frames:** If log aggregators require per-frame
  indexing, a follow-up RFC can propose `Value.Array of t list` and
  backtrace frame parsing via `Printexc.backtrace_slots`.
- **Result logging:** A `Logger.log_error` or PPX
  `[%log.<level>_result ...]` for `('a, 'e) result` types, using
  a user-supplied `'e -> string` formatter.
- **Exception re-raise helper:** A convenience function
  `Logger.log_and_reraise` that logs the exception and re-raises it,
  preserving the original backtrace via `Printexc.raise_with_backtrace`.
