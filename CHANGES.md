# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Initial feature set. Nothing has been tagged yet; everything below lands in
the first release.

### Added

- Core types: `Level` (six severities, `Trace` through `Fatal`), `Value`
  (private structured field values with smart constructors; non-finite floats
  are coerced to their string form so every value is representable), and
  `Entry` (immutable log records with timestamp, level, message, and
  structured fields).
- `Formatter`: pure `Entry.t -> string` formatters — `json` (one JSON
  envelope per entry; user fields that collide with envelope keys are nested,
  never dropped), `logfmt`, and `text`. Every formatter emits exactly one
  line per entry; logfmt escapes both keys and values under a single
  quote/escape grammar, user fields named `ts`/`level`/`msg` are
  deterministically renamed with an `olog.` prefix, floats render losslessly,
  and the grammars are pinned by round-trip property tests.
- `Context`: fiber-local structured fields via OCaml effects, merged into
  every entry logged inside `with_context`. Forked fibers deliberately start
  with an empty context (ADR 0002, affirmed as the stable contract by
  ADR 0019); no Eio dependency and no scheduler required.
- `Logger`: asynchronous logger backed by a bounded queue and a worker fiber.
  Log calls never raise and never block on I/O; when the queue is full,
  entries are dropped and counted rather than blocking the caller. The worker
  delivers consecutive entries to each sink as one batch, `flush` is a FIFO
  barrier, and `shutdown` drains the queue before closing sinks. Sink
  failures are reported once per batch to stderr and never stop the worker
  (ADR 0007).
- `Logger.diagnostics`: queue depth/capacity, an emitted-entries counter, and
  per-cause drop counters (queue-full, after-shutdown, cancellation loss)
  satisfying `submitted = emit_count + drop_count` and
  `drop_count = Σ causes`.
- `Output`: stdout and stderr destinations with a pluggable formatter, plus
  `to_sink` for attaching custom batch-shaped sinks.
- `log_exn`: structured exception capture with the exception's printed form
  and raw backtrace as fields.
- `olog_ppx`: `[%log.LEVEL]` extension points expanding to level-guarded
  `Logger.log` calls with compile-time source location and automatic `Value`
  wrapping of literal fields.
- Runnable examples under `examples/` pinned by a cram test, and generated
  odoc API documentation.
