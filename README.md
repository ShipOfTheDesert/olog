# olog

Structured async logging for OCaml 5 applications built on
[Eio](https://github.com/ocaml-multicore/eio).

Log calls attach typed key-value fields, never raise, and never block on
I/O: entries go onto a bounded queue and a dedicated worker fiber delivers
them to sinks in batches. Output is machine-parseable by construction —
JSON Lines, logfmt, or human-readable text — and an optional PPX injects
source locations and wraps literal field values.

## Features

- **Structured logging** — every entry carries typed key-value fields
  (`Value.string`, `Value.int`, `Value.float`, `Value.bool`, `Value.null`).
  Non-finite floats are coerced to their string form at construction, so
  every value has a valid JSON representation.
- **Async, non-blocking, total** — `Logger.log` enqueues and returns
  immediately. When the queue is full, entries are dropped and counted
  rather than blocking the caller. Log calls never raise.
- **Batched sink writes** — the worker delivers consecutive queued entries
  to each sink in a single `emit` call, in enqueue order. `flush` is a FIFO
  barrier; `shutdown` drains the queue, then flushes and closes sinks, and
  is idempotent and safe from any fiber or domain.
- **Accounted delivery** — `Logger.diagnostics` exposes an emitted-entries
  counter and per-cause drop counters (queue-full, after-shutdown,
  cancellation loss) satisfying `submitted = emit_count + drop_count` and
  `drop_count = Σ causes`, so backpressure is distinguishable from
  lifecycle loss.
- **Explicitly scoped context** — `Context.with_context` merges fields into
  every entry logged within its callback. Scoping is explicit; see
  [Context semantics](#context-semantics) below.
- **Correct output** — every formatter emits exactly one line per entry,
  closing log-forging vectors. `json` nests user fields under `"fields"` so
  envelope keys cannot collide; `logfmt` escapes both keys and values under
  a single quote/escape grammar (user fields named `ts`/`level`/`msg` are
  deterministically renamed with an `olog.` prefix) and round-trips; floats
  render losslessly.
- **Pluggable outputs** — `stdout`, `stderr`, or any `Eio.Flow.sink` via
  `Output.make`; fully custom sinks implement the `Logger.sink` record
  directly. Sink failures are reported once per batch to stderr and never
  stop the worker.
- **PPX** — `[%log.info logger "msg" [("key", "value")]]` expands to a
  level-guarded `Logger.log` call with compile-time source location and
  automatic `Value` wrapping of literal fields.

## Requirements

Runtime dependencies of `olog`:

- OCaml >= 5.2.0
- dune >= 3.16
- eio >= 1.0
- ptime >= 1.1
- yojson >= 2.1

`olog_ppx` additionally requires ppxlib >= 0.32 and installs alongside
`olog` at the same version. Test-only dependencies: alcotest, qcheck-core,
qcheck-alcotest, eio_main.

## Installation

olog is not yet published to opam. Pin both packages from source:

```bash
opam pin add olog.dev git+https://github.com/ShipOfTheDesert/olog.git
opam pin add olog_ppx.dev git+https://github.com/ShipOfTheDesert/olog.git
```

Then declare them in your `dune` stanza:

```
(library
 (name mylib)
 (libraries olog)
 (preprocess (pps olog_ppx)))  ; optional — only for [%log.LEVEL] syntax
```

### From source

```bash
git clone https://github.com/ShipOfTheDesert/olog.git
cd olog
opam install . --deps-only --with-test
dune build
```

## Quick Start

```ocaml
open Olog

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink =
    Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ())
  in
  let ( let* ) = Result.bind in
  let logger =
    let* config =
      Logger.Config.make ~min_level:Level.Info ~queue_depth:1024
        ~sinks:[ sink ] ()
    in
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "app"
  in
  match logger with
  | Error msg -> failwith msg
  | Ok logger ->
      Context.with_context
        ~fields:[ ("request_id", Value.string "abc") ]
        (fun () -> Logger.log logger ~level:Level.Info "server started");
      Logger.shutdown logger
```

The `shutdown` call drains the queue and flushes the sinks before the
switch closes — without it, entries still in flight when the switch tears
the worker down are not guaranteed to be written (`Logger.flush` inside the
program gives the same guarantee point-wise).

With the `olog_ppx` preprocessor the last call shortens to:

```ocaml
[%log.info logger "server started" [ ("request_id", "abc") ]]
```

Runnable programs covering the direct API, the PPX, context scoping,
exception capture, and custom outputs live in [`examples/`](examples/);
their output is pinned by a cram test.

## Context semantics

Context is explicitly scoped: `with_context` adds fields for the duration of
a callback, and a fiber forked inside that callback starts with an *empty*
context — fields are never silently inherited across `Fiber.fork`. To carry
fields into a forked fiber, capture them with `Context.current ()` *before*
the fork and re-apply them with `with_context` inside the fiber:

```ocaml
let fields = Context.current () in
Eio.Fiber.fork ~sw (fun () ->
    Context.with_context ~fields @@ fun () -> (* ... *) ())
```

This is a deliberate, stable contract (isolation between concurrent fibers
by default), recorded in ADR 0002 and affirmed by ADR 0019
(`docs/adrs/` in a development checkout). On key collision, call-site
`~fields` override context fields; in `Logger.log_exn`, exception fields
take highest precedence.

## API overview

| Module | Purpose |
|--------|---------|
| `Olog.Logger` | Async logger: `Config.make`, `create`, `log`, `log_exn`, `is_enabled`, `flush`, `shutdown`, `diagnostics` |
| `Olog.Context` | Fiber-local structured fields: `with_context`, `current` |
| `Olog.Formatter` | Pure `Entry.t -> string` formatters: `json`, `logfmt`, `text` |
| `Olog.Output` | Destinations: `stdout`, `stderr`, `make` (any `Eio.Flow.sink`), `to_sink` |
| `Olog.Level` | `Trace \| Debug \| Info \| Warn \| Error \| Fatal`, totally ordered |
| `Olog.Value` | Private structured field values with smart constructors |
| `Olog.Entry` | Immutable log entry records |

The authoritative contracts (batch and error semantics of sinks, formatter
grammars, drop accounting) are documented on the signatures in `lib/*.mli`
and rendered by odoc — see below.

## Documentation

```bash
dune build @doc --force
# open _build/default/_doc/_html/index.html
```

[`llms.txt`](llms.txt) carries an LLM-consumable summary of the public API,
kept in sync with the `.mli` files.

## Development

```bash
dune build              # compile
dune test               # unit, property, and cram tests
dune build @fmt         # ocamlformat compliance
dune build @doc --force # odoc generation
opam-dune-lint          # opam/dune dependency alignment
```

Every PR must pass all five checks (the quality gate). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the coding principles and PR
workflow, and [ROADMAP.md](ROADMAP.md) for planned work.

## License

ISC
