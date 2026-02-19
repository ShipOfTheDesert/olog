# RFC 0004: Output Destinations and Formatters

| Field       | Value                                      |
|-------------|--------------------------------------------|
| **RFC**     | 0004                                       |
| **Title**   | Output Destinations and Formatters         |
| **Status**  | Accepted                                   |
| **Created** | 2026-02-18                                 |
| **Session** | 4                                          |

---

## Summary

Introduce `Formatter` and `Output` — the concrete I/O layer for olog. `Formatter.t` is a pure function `Entry.t -> string` with three built-in implementations: JSON Lines (`Formatter.json`), logfmt (`Formatter.logfmt`), and human-readable text (`Formatter.text`). `Output.t` is a vtable record `{ name; write; close }` with four built-in constructors: `Output.stdout`, `Output.stderr`, `Output.file` (size-based rotation via rename-and-reopen), and `Output.http` (per-write batched POST via `cohttp-eio`). All file I/O uses `Eio.Path` and `Eio.Flow`; `Stdlib.open_out` is prohibited. `Output.t.write` never propagates exceptions — I/O errors are written to a fallback stderr channel. `Output.to_sink` adapts an `Output.t` to the `Logger.sink` type defined in RFC 0003.

---

## Motivation

RFC 0003 introduced `Logger.t` and `Logger.sink` but explicitly deferred formatters and concrete sink implementations. `Logger.Config.default` has `sinks = []` — the library cannot emit any log output until this session adds real destinations.

Existing OCaml logging libraries either bundle formatting and I/O into a single opaque reporter with no compositional boundary (`logs` reporters), provide no structured (JSON) or machine-parseable output, or rely on `Stdlib.out_channel` — which is unsafe in Eio contexts because it blocks the underlying OS thread and is not fiber-safe.

olog decouples the two concerns, matching Article X.5: formatters are pure functions; outputs are I/O records. Each is independently testable — a formatter test needs no Eio scheduler; an output test can inject a mock formatter. New formatters compose with all outputs; new outputs compose with all formatters.

---

## Scope

### In Scope

- `Formatter.t` — type alias `Entry.t -> string`
- `Formatter.json` — JSON Lines: one compact JSON object per entry, `\n`-terminated; uses `Yojson`
- `Formatter.logfmt` — logfmt: space-separated `key=value` pairs, `\n`-terminated
- `Formatter.text` — human-readable plain text, `\n`-terminated
- `Output.t` — concrete record: `{ name : string; write : Entry.t list -> unit; close : unit -> unit }`
- `Output.make` — low-level constructor from a formatter and an `Eio.Flow.sink`
- `Output.stdout` — writes to env stdout
- `Output.stderr` — writes to env stderr
- `Output.file` — appends to a file; size-based rotation (rename path to `<path>.1`, reopen)
- `Output.http` — POSTs each `write` batch as one HTTP request via `cohttp-eio`
- Error-safety contract: `Output.t.write` catches all I/O exceptions; errors are written to process stderr via raw Eio stderr flow
- `Output.to_sink : Output.t -> Logger.sink` — adapter for `Logger.Config.sinks`
- `.mli` files for `Formatter` and `Output`
- Alcotest tests: pure string tests for `Formatter`; `Eio_main.run` integration tests for `Output.file`

### Out of Scope

- Time-based or count-based log rotation
- Keeping more than one rotated file copy (`.1`, `.2`, …)
- TLS/HTTPS connections for `Output.http`
- HTTP connection pooling or keep-alive
- Per-sink or per-output level filters
- Internal buffering within `Output.t` (each `write` call is forwarded immediately)
- Gzip compression of rotated files
- Syslog, journald, or platform-specific destinations
- `Formatter.t` combinators (prefix, suffix, compose)
- Batch/multi-entry formatter signature
- PPX source-location integration
- `Output.t.flush` (see Options Considered §D)

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `Formatter.t` is the type alias `Entry.t -> string` |
| F2  | `Formatter.json entry` returns a single valid JSON object followed by `'\n'` (JSON Lines format); the object always contains keys `"timestamp"` (ISO 8601 UTC string via `Ptime.to_rfc3339`), `"level"` (lowercase level name), `"message"` (string), and one additional key per `Entry.fields` entry serialised via `Value.to_yojson`; if `entry.src_pos` is `Some p`, a `"src_pos"` object with `"file"`, `"line"`, and `"col"` is also included |
| F3  | `Formatter.logfmt entry` returns a space-separated logfmt line followed by `'\n'`; fixed keys appear first in order: `ts=<ISO8601>`, `level=<level>`, `msg=<value>`; structured fields follow; string values containing whitespace, `=`, or `"` are double-quoted with interior `"` escaped as `\"` |
| F4  | `Formatter.text entry` returns a human-readable line followed by `'\n'` in the form `<ISO8601> <LEVEL> <message>[ key=value ...]`; level is upper-cased; fields follow the message as space-separated `key=value` pairs using `Value.to_string` for rendering |
| F5  | `Output.t` is a concrete (non-abstract) record type: `{ name : string; write : Entry.t list -> unit; close : unit -> unit }` |
| F6  | `Output.t.write` must never propagate an exception to the caller; if an I/O exception occurs the implementation catches it and writes one line `[olog error] <output.name>: <Printexc.to_string exn>` to the raw Eio stderr flow, then returns |
| F7  | `Output.make ~name ~formatter flow` creates an `Output.t` that formats each entry in the list with `formatter` and writes the resulting strings to `flow` using `Eio.Flow.write`; entries are processed in list order; `close ()` is a no-op — the caller owns `flow` |
| F8  | `Output.stdout ~env ~formatter ()` creates an `Output.t` writing to the stdout flow of `env`; `name = "stdout"`; `close ()` is a no-op |
| F9  | `Output.stderr ~env ~formatter ()` creates an `Output.t` writing to the stderr flow of `env`; `name = "stderr"`; `close ()` is a no-op |
| F10 | `Output.file ~env ~formatter ~path ~max_bytes ()` opens the file at `path` in append mode (creating if absent) using `Eio.Path.open_out ~append:true`; the `name` field is the string representation of `path` |
| F11 | When cumulative formatted bytes written to the current file handle reach or exceed `max_bytes`, `Output.file` rotates: closes the current handle, renames the file to `<path_string>.1` via `Eio.Path.rename` (overwriting any existing file at that name), then opens a new file at the original path; the byte counter resets to zero after rotation |
| F12 | `Output.file`'s `close ()` closes the current file handle |
| F13 | `Output.http ~net ~formatter ~uri ?headers ()` creates an `Output.t`; on each `write entries` call it constructs a body by applying `formatter` to each entry and concatenating the results, then sends one HTTP POST to `uri` using `cohttp-eio`; the `Content-Type` header is `text/plain; charset=utf-8`; additional `headers` are appended verbatim; `close ()` is a no-op |
| F14 | If the HTTP POST fails (network error or non-2xx response), the failure is caught and written to fallback stderr per F6; the entries are not retried |
| F15 | `Output.to_sink output` returns a `Logger.sink` where `emit entry` calls `output.write [entry]`; `flush ()` is a no-op; `close ()` calls `output.close ()` |
| F16 | All `Output.t` values produced by the built-in constructors are safe to call from the Logger worker fiber |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | OCaml >= 5.2.0 |
| NF2 | Eio >= 1.0 (`Eio.Flow`, `Eio.Path`, `Eio.Net`) |
| NF3 | `cohttp-eio >= 6.0` for `Output.http` |
| NF4 | `Stdlib.open_out`, `Stdlib.open_in`, and all `out_channel`/`in_channel` I/O are prohibited; all file access uses `Eio.Path` and `Eio.Flow` |
| NF5 | `Formatter` depends only on `Entry` and `Yojson`; it must not depend on `eio` or `eio_main` |
| NF6 | `Output` depends on `eio` and `cohttp-eio`; it must not depend on `eio_main` |
| NF7 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` must all pass |
| NF8 | `Formatter` tests use pure Alcotest — no Eio scheduler required |
| NF9 | Integration tests for `Output.file` use `Eio_main.run` with a real temporary directory from `env` |

---

## Public Interface

```ocaml
(** Formatter.mli *)

(** Pure log entry formatters.

    A {!t} is a function from {!Entry.t} to [string]. Each built-in
    formatter produces a newline-terminated line. Formatters are composable:
    supply one to any {!Output} constructor. Formatters have no Eio
    dependency and may be tested without a scheduler. *)

type t = Entry.t -> string
(** A formatter converts a single log entry to a newline-terminated string. *)

val json : t
(** [json entry] serialises [entry] as a compact JSON object followed by
    ['\n'] (JSON Lines format).

    Fixed keys: ["timestamp"] (ISO 8601 UTC), ["level"] (lower-case),
    ["message"] (string). Each field in {!Entry.fields} appears as an
    additional key serialised via {!Value.to_yojson}. If {!Entry.src_pos}
    is [Some p], a ["src_pos"] object with ["file"], ["line"], and ["col"]
    is included. *)

val logfmt : t
(** [logfmt entry] serialises [entry] in logfmt format followed by ['\n'].

    Fixed keys appear first: [ts], [level], [msg]. Structured fields follow.
    String values containing whitespace, [=], or ["] are double-quoted;
    interior ["] characters are escaped as [\\"]. *)

val text : t
(** [text entry] serialises [entry] as a human-readable line followed by
    ['\n'].

    Format: [<ISO8601> <LEVEL> <message>[ key=value ...]]
    Level is upper-cased. Fields follow the message as space-separated
    [key=value] pairs. Values are rendered with {!Value.to_string}. *)
```

```ocaml
(** Output.mli *)

(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches
    of entries and releasing resources. Built-in constructors cover stdout,
    stderr, file (size-based rotation), and HTTP (batched POST).

    {!t.write} never propagates exceptions — I/O errors are caught and a
    best-effort error line is written to the process stderr. Use {!to_sink}
    to adapt an {!t} for use with {!Logger.Config.sinks}. *)

type t = {
  name  : string;
  (** Human-readable name, used in error messages and diagnostics. *)
  write : Entry.t list -> unit;
  (** Write a batch of entries to the destination. Must not raise — see
      module documentation. Called by the logger worker fiber. *)
  close : unit -> unit;
  (** Release underlying resources. Called once at teardown by
      {!Logger}'s worker via {!to_sink}. Must not raise. *)
}
(** An output destination — a named pair of write and close functions. *)

val make :
  name:string ->
  formatter:Formatter.t ->
  _ Eio.Flow.sink ->
  t
(** [make ~name ~formatter flow] creates an output that formats each entry
    with [formatter] and writes the resulting strings to [flow].

    [close ()] is a no-op — the caller retains ownership of [flow].
    Exceptions from [flow] writes are caught per the error-safety contract. *)

val stdout :
  env:_ Eio.Stdenv.t ->
  formatter:Formatter.t ->
  unit ->
  t
(** [stdout ~env ~formatter ()] writes formatted entries to [env]'s standard
    output. [name = "stdout"]. [close] is a no-op. *)

val stderr :
  env:_ Eio.Stdenv.t ->
  formatter:Formatter.t ->
  unit ->
  t
(** [stderr ~env ~formatter ()] writes formatted entries to [env]'s standard
    error. [name = "stderr"]. [close] is a no-op. *)

val file :
  env:_ Eio.Stdenv.t ->
  formatter:Formatter.t ->
  path:_ Eio.Path.t ->
  max_bytes:int ->
  unit ->
  t
(** [file ~env ~formatter ~path ~max_bytes ()] opens [path] in append mode
    and writes formatted entries.

    When cumulative written bytes reach [max_bytes], the output rotates: the
    current file is closed, renamed to [<path>.1] (overwriting any existing
    file at that name), and a new file is opened at [path]. The byte counter
    resets after each rotation.

    [close ()] closes the current file handle.

    @param max_bytes Must be a positive integer. *)

val http :
  net:_ Eio.Net.t ->
  formatter:Formatter.t ->
  uri:string ->
  ?headers:(string * string) list ->
  unit ->
  t
(** [http ~net ~formatter ~uri ?headers ()] creates an output that POSTs
    each batch of entries as a single HTTP request.

    The request body is the concatenation of [formatter entry] for each entry
    in the batch. [Content-Type] is [text/plain; charset=utf-8]. Additional
    [headers] are appended verbatim.

    On network error or non-2xx response, entries are dropped and the error
    is reported to fallback stderr per the error-safety contract. [close] is
    a no-op. *)

val to_sink : t -> Logger.sink
(** [to_sink output] adapts [output] for use with {!Logger.Config.sinks}.

    Mapping:
    - [emit entry]  →  [output.write [entry]]
    - [flush ()]    →  no-op
    - [close ()]    →  [output.close ()] *)
```

---

## Options Considered

### Option A: Separate `Formatter.t` and `Output.t` — chosen

Two distinct types with a clear boundary: formatters produce strings from entries; outputs consume entry batches and perform I/O.

**Pros:** `Formatter` has zero Eio dependency — tests are pure and fast. New formatters compose with all outputs; new outputs compose with all formatters. The vtable pattern for `Output.t` mirrors `Logger.sink` (Article X.5). Both are independently documented and testable.

**Cons:** Callers must always supply a formatter to output constructors — a two-argument construction rather than one. Minor verbosity at call sites.

### Option B: Unified `Sink.t` (formatting + I/O in one type)

Define one type that bundles format and write logic. No separate `Formatter.t`.

**Pros:** Fewer types; simpler API for the most common case.

**Cons:** Cannot reuse formatting logic across destinations. Custom destination authors must re-implement formatting. Swapping a formatter requires recreating the sink. Contradicts Article X.5 (composition over inheritance). **Rejected.**

### Option C: Batch formatter — `Formatter.t = Entry.t list -> string`

Make `Formatter.t` operate on a list of entries rather than one.

**Pros:** Single call for HTTP body construction; enables JSON-array wrapping for batch semantics.

**Cons:** Per-entry destinations (stdout, file) must pass singleton lists or handle empty batches specially. HTTP can concatenate per-entry strings without a batch signature. Adds complexity for marginal gain in one destination. **Rejected.**

### Option D: Add `flush : unit -> unit` to `Output.t`

Extend `Output.t` to `{ name; write; flush; close }`, matching `Logger.sink.flush`.

**Pros:** Allows `Output.to_sink` to propagate `Logger.flush` through to file I/O buffers; necessary if `Output.file` uses buffered writes internally.

**Cons:** The specified `Output.t` interface omits `flush`. File output using `Eio.Flow.write` is written unbuffered (one write per entry); flush is unnecessary for correctness. `Logger.sink.flush` in `to_sink` is a no-op — the Logger's flush barrier already guarantees all `emit` calls have returned before `flush` is invoked on any sink. If buffered writes are needed in future, this can be added in a subsequent RFC without breaking callers. **Rejected for this RFC.**

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| `Eio.Path.rename` unavailable in the target Eio backend | File rotation silently fails | Test against the Unix backend (`eio_main`); document Unix-backend requirement for rotation |
| `cohttp-eio` version API changes | `Output.http` fails to compile | Pin `cohttp-eio >= 6.0`; isolate HTTP logic to one internal function |
| Fallback stderr write itself raises | Error line lost | Wrap the fallback write in a second `try … with _ -> ()` that silently discards |
| Per-write HTTP POST latency stalls Logger worker fiber | Drop counter increases as queue fills | Document that `Output.http` is suitable for low-volume or best-effort use; suggest Logger-level batching for high-throughput sinks |
| `max_bytes` check fires mid-batch | Some entries in a batch go to old file, remainder to new | Acceptable — rotation is approximate; documented as known behaviour |
| Article V: two additional library modules beyond the initial three | Review concern | `Formatter` (pure, no Eio) and `Output` (I/O, Eio + cohttp-eio) have incompatible dependency profiles; merging them into `Olog` would force an Eio dependency on the pure formatter. Keeping them separate preserves the dependency boundary and is independently justified by their different testing requirements |

---

## Open Questions

- **Q1:** Should `Output.http` use `cohttp-eio` or an alternative HTTP client (`piaf`, `h2-eio`)? `cohttp-eio` is the most widely deployed Eio-compatible HTTP client as of 2026-02; `piaf` supports HTTP/2 but adds more transitive dependencies. The public interface is client-library-agnostic — the decision can be resolved at implementation time without changing the `.mli`.
