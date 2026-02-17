# olog

Production-grade structured async logging for Eio-based OCaml applications.

`olog` provides structured JSON logging, fiber-local context propagation,
async non-blocking emission, and configurable output destinations for OCaml 5
applications built on the [Eio](https://github.com/ocaml-multicore/eio)
concurrency library.

## Status

**Work in progress.** The core data model (`Level`, `Value`, `Entry`) is
implemented. Context propagation, async emission, output destinations, and
the PPX are planned for future sessions.

## Features

- **Structured logging** — attach typed key-value fields to every log entry
- **Fiber-local context** — correlation IDs and metadata propagate
  automatically to child fibers (planned)
- **Async non-blocking emission** — log calls enqueue entries without blocking
  the caller; a dedicated worker fiber handles I/O (planned)
- **JSON output** — every entry serializes to valid `Yojson.Safe.t`
- **Pure data model** — `Level`, `Value`, and `Entry` types have zero I/O
  dependencies and are independently testable
- **Immutable by default** — all records are immutable; upsert semantics on
  structured fields (last writer wins)

## Requirements

- OCaml >= 5.2.0
- dune >= 3.16
- ptime >= 1.1
- yojson >= 2.1

## Installation

```bash
opam pin add olog .
```

Or add to your `dune-project`:

```
(depends (olog (>= 0.1)))
```

### From Source

```bash
git clone https://github.com/yourhandle/olog.git
cd olog
opam install . --deps-only --with-test
dune build
```

## Quick Start

```ocaml
let () =
  let timestamp =
    match Ptime.of_date_time ((2024, 1, 15), ((10, 30, 0), 0)) with
    | Some t -> t
    | None -> failwith "bad timestamp"
  in
  let entry =
    Olog.Entry.create
      ~level:Olog.Level.Info
      ~message:"request handled"
      ~fields:[
        ("method", Olog.Value.String "GET");
        ("path", Olog.Value.String "/api/users");
        ("status", Olog.Value.Int 200);
        ("duration_ms", Olog.Value.Float 12.5);
      ]
      ~timestamp
      ()
  in
  let json = Olog.Entry.to_yojson entry in
  print_endline (Yojson.Safe.pretty_to_string json)
```

Output:

```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "level": "info",
  "message": "request handled",
  "fields": {
    "method": "GET",
    "path": "/api/users",
    "status": 200,
    "duration_ms": 12.5
  }
}
```

## API Overview

### `Olog.Level`

Six severity levels with total ordering:

```
Trace < Debug < Info < Warn < Error < Fatal
```

Conversion to/from strings (case-insensitive) and JSON.

### `Olog.Value`

Structured field values: `String`, `Int`, `Float`, `Bool`, `Null`.
Round-trips through `Yojson.Safe.t`.

### `Olog.Entry`

Immutable log entry record with:
- `timestamp` — `Ptime.t` (UTC, ISO 8601)
- `level` — `Level.t`
- `message` — `string`
- `fields` — `(string * Value.t) list` with upsert deduplication
- `src_pos` — optional source location (`file`, `line`, `col`)

## Development

```bash
# Build
dune build

# Test (25 tests across Level, Value, Entry)
dune test

# Format check
dune build @fmt

# Auto-format
dune fmt

# Generate docs
dune build @doc

# Lint opam/dune alignment
opam-dune-lint
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for coding principles, conventions,
and the PR workflow.

## License

ISC
