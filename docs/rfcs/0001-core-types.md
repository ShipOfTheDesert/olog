# RFC 0001: Core Types — Level, Value, Entry

| Field       | Value                                  |
|-------------|----------------------------------------|
| **RFC**     | 0001                                   |
| **Title**   | Core Types — Level, Value, Entry       |
| **Status**  | Accepted                               |
| **Created** | 2026-02-16                             |
| **Accepted**| 2026-02-16                             |
| **Session** | 1                                      |

---

## Summary

Introduce the pure, immutable data model that underpins olog's structured
logging: a `Level` type for log severity, a `Value` type for structured field
values, and an `Entry` record that combines them into a single log event. These
types have no I/O or Eio dependency — they are the foundation on which async
emission, formatting, and output destinations will be built in later sessions.

---

## Motivation

OCaml's existing logging libraries (`logs`, `Lwt_log`) represent log events as
unstructured strings with no standard way to attach typed key-value metadata.
There is no shared, pure data model for structured log entries that is
independent of I/O backend, concurrency library, or output format. `olog` needs
a foundation of immutable, purely functional types that describe a log event —
its severity, its structured fields, and its metadata — before any async
emission or formatting can be built on top.

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `Level.t` defines exactly 6 variants: `Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal` |
| F2  | `Level.to_string` returns lowercase string for each variant (e.g., `Info` -> `"info"`) |
| F3  | `Level.of_string` parses case-insensitive string, returns `(Level.t, string) result` where error is the invalid input |
| F4  | `Level.compare` implements total ordering: `Trace < Debug < Info < Warn < Error < Fatal` |
| F5  | `Level.equal` returns `true` iff two levels are the same variant |
| F6  | `Level.to_yojson` / `Level.of_yojson` round-trip through `Yojson.Safe.t` string values |
| F7  | `Value.t` defines variants: `String of string`, `Int of int`, `Float of float`, `Bool of bool`, `Null` |
| F8  | `Value.to_yojson` converts each `Value.t` variant to the corresponding `Yojson.Safe.t` |
| F9  | `Value.of_yojson` round-trips with `to_yojson`; returns `(Value.t, string) result` for unsupported JSON types |
| F10 | `Entry.t` is an immutable record: `timestamp : Ptime.t`, `level : Level.t`, `message : string`, `fields : (string * Value.t) list`, `src_pos : src_pos option` |
| F11 | `Entry.create` constructs an entry purely (no I/O), accepting level, message, optional fields, optional src_pos, and timestamp |
| F12 | `Entry.to_yojson` serializes an entry with keys `"timestamp"` (ISO 8601 UTC), `"level"`, `"message"`, `"fields"`, and optionally `"src_pos"` |
| F13 | `src_pos` is a record inlined in Entry: `{ file : string; line : int; col : int }` |
| F14 | All public functions are pure — no side effects, no Eio dependency |
| F15 | `Entry.fields` uses upsert semantics: duplicate keys resolved by keeping the last occurrence (deeper context wins) |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | OCaml >= 5.2.0 |
| NF2 | No Eio dependency for Level, Value, Entry modules (pure data) |
| NF3 | Yojson >= 2.1 (for JSON conversion) |
| NF4 | Ptime >= 1.1 (for timestamps) |
| NF5 | Alcotest >= 1.7 (test framework) |
| NF6 | All types must be constructable in < 1us (no allocation-heavy operations) |
| NF7 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc`, and `opam-dune-lint` must all pass at every step |

---

## Public Interface

### `Level`

```ocaml
type t = Trace | Debug | Info | Warn | Error | Fatal

val compare : t -> t -> int
val equal : t -> t -> bool
val to_string : t -> string
val of_string : string -> (t, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
```

### `Value`

```ocaml
type t = String of string | Int of int | Float of float | Bool of bool | Null

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
```

### `Entry`

```ocaml
type src_pos = { file : string; line : int; col : int }

type t = {
  timestamp : Ptime.t;
  level : Level.t;
  message : string;
  fields : (string * Value.t) list;
  src_pos : src_pos option;
}

val create :
  level:Level.t ->
  message:string ->
  ?fields:(string * Value.t) list ->
  ?src_pos:src_pos ->
  timestamp:Ptime.t ->
  unit ->
  t

val to_yojson : t -> Yojson.Safe.t
```

---

## Scope

### In Scope
- `Level.t` — log severity sum type with ordering and string conversion
- `Value.t` — structured field value sum type with JSON conversion
- `Entry.t` — immutable log event record combining level, message, timestamp, fields, and source location
- `Entry.create` — pure constructor (no I/O, no Eio)
- `.mli` files for all public modules
- Alcotest unit tests for all types
- `src_pos` — source location record inlined in Entry

### Out of Scope
- `Context` module (fiber-local storage — requires Eio, future session)
- Async emission / worker fiber / `Eio.Stream.t`
- Output formatting (JSON, logfmt)
- Output destinations
- PPX for source location capture
- Diagnostics / metrics
- Any I/O or Eio dependency in these modules
- `Entry.of_yojson` (not needed; tests validate via `to_yojson` output)
- `Value.t` list/array variant (deferred per Article IX)

---

## Options Considered

### Option A: PPX deriving for JSON (rejected)

`ppx_deriving_yojson` could auto-generate `to_yojson`/`of_yojson` for all
three types.

**Rejected**: Adds a PPX dependency not in the spec. Hand-written converters
are trivial for 3 small types, give full control over output format (e.g.,
ISO 8601 timestamps via `Ptime.to_rfc3339`), and avoid PPX compile-time
overhead. Article IX — YAGNI.

### Option B: Polymorphic variants for Level.t (rejected)

`` `Trace | `Debug | ... `` would allow open extensibility, letting
downstream libraries add custom levels without modifying the type.

**Rejected**: Exhaustive matching (Article X.3) is harder with polymorphic
variants — the compiler cannot enforce completeness across modules. Nominal
variants give us the compiler-guided exhaustiveness guarantee we need. When
adding a variant, the compiler guides all necessary changes.

### Option C: Map for Entry.fields instead of association list (rejected)

`Map.Make(String).t` would give O(log n) lookup and automatic deduplication
by key.

**Rejected**: Log fields are typically fewer than 10 entries. An association
list is simpler, preserves insertion order for debugging, and upsert
deduplication is a one-pass `List.rev` + filter. A Map adds complexity for
no measurable gain at this scale. Article VII — prefer reversible, simple
approaches first.

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| `Ptime.to_rfc3339` requires a `tz_offset_s` argument that could produce non-UTC output | Wrong timestamp format in JSON | Always pass `~tz_offset_s:0` explicitly; test verifies trailing `Z` |
| `Yojson.Safe.t` uses polymorphic variants which can silently accept wrong types | Type confusion in JSON conversion | Exhaustive match in `of_yojson` functions; test invalid inputs |
| OCaml `int` is 63-bit on 64-bit platforms; `Yojson.Safe.t` uses `int` for `` `Int `` | Potential overflow on 32-bit platforms | Document 63-bit limitation; not a practical concern for log field values |
| `opam-dune-lint` may flag `eio`/`eio_main` in opam deps but not in `lib/dune` libraries | Lint failure | Keep deps aligned; handle as known deviation until Eio modules arrive |

---

## Resolved Questions

1. **Src_pos placement** — inlined in `Entry`, no separate module.
2. **Value.t extensibility** — deferred per Article IX. 5 variants only.
3. **Entry.of_yojson** — omitted. Tests validate via `to_yojson` output
   against expected `Yojson.Safe.t` values.
4. **Field ordering** — ordering not significant. Upsert semantics: duplicate
   keys resolved by keeping the last occurrence (deeper context wins).
