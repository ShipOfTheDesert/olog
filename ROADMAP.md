# olog Roadmap

Planned features in priority order. Each tier represents a cohesive phase of
work; all items in a tier should be completed before the next tier begins.

Planning now uses a single feature doc per item (docs/features/NNNN-*.md); the
legacy PRD/RFC pointers below are historical. See
docs/adrs/0015-workflow-migration-to-feature-docs.md.

---

## Tier 1

Core correctness and robustness. The library is not suitable for any production
use until these are complete.

---

### Remove HTTP Output Destination

Implemented: docs/rfcs/0006-remove-http-output.md

### PPX Test Coverage: Float, Null, and Compile-Error Negative Tests

Implemented: docs/rfcs/0007-ppx-test-coverage.md

---

### Structured Error and Exception Capture

Implemented: docs/rfcs/0008-structured-error-and-exception-capture.md

---

### Context Wiring in Logger

Implemented: docs/rfcs/0009-context-wiring-in-logger.md

---

### Log Rotation and File Sink Lifecycle

File output destination was removed: docs/rfcs/0010-remove-file-output-destination.md

---

### Graceful Shutdown and Drain

Implemented: docs/rfcs/0011-graceful-shutdown-and-drain.md

---

### Logger Lifecycle and Accounting Correctness

PRD: docs/prds/0012-logger-lifecycle-and-accounting-correctness.md
RFC: docs/rfcs/0013-logger-lifecycle-and-accounting-correctness.md

Fixes the liveness and accounting bugs documented in ANALYSIS.md: flush and
shutdown deadlocks after switch cancellation, the concurrent-shutdown race,
swallowed cancellation in sink dispatch, unvalidated configuration, uncounted
entry loss, and the silent epoch timestamp fallback.

---

### Formatter Output Correctness

Legacy PRD (to be replanned as a feature doc in docs/features/):
docs/prds/0014-formatter-output-correctness.md

Fixes the output-correctness bugs documented in ANALYSIS.md: duplicate JSON
keys, log-line forging via unescaped newlines in logfmt and text output, and
float precision loss. Changes observable output, so it must land before the
first tagged release. Sequenced after PRD 0012.

---

## Tier 2

Operator ergonomics and ecosystem. Complete after Tier 1 is stable.

---

### README, CHANGES, and opam Release

`dune-project` uses placeholder values (`yourhandle/olog`, `Your Name`). There
is no README, no CHANGES.md, and no tagged release. The library cannot be
installed via `opam install olog` by anyone outside the repository. This work
unlocks external contributors and real-world testing.

**Tradeoffs and things to consider:**
- README should include: one-paragraph pitch, quick-start code block (matching
  `examples/basic.ml`), dependency list, build instructions, and a link to the
  generated odoc HTML.
- CHANGES.md format: choose between Keep a Changelog and a free-form format
  before writing the first entry, as changing it later is disruptive.
- The opam submission requires a public GitHub repository, a tagged release
  (`git tag v0.1.0`), and a PR to `ocaml/opam-repository`. The `:version`
  constraint in `olog_ppx` means both packages must be released together and
  tagged identically.
- Replace placeholder values in `dune-project` (`yourhandle`, `Your Name`,
  `you@example.com`) with real values before tagging.
- Remove the `bin/` scaffold executable: it is "Hello, World!" with
  `(public_name olog)`, so the package currently installs a junk `olog`
  binary.
- The README is stale (calls implemented features "planned", wrong test
  count, `Entry`-level quick start instead of the `Logger`/PPX API) — rewrite
  against the actual API as part of this work.

---

### Dynamic Level Filtering

`Logger.Config.min_level` is set at creation time and never changes. There is
no way to raise or lower verbosity at runtime without recreating the logger and
losing the queue. Hot-reloading log levels — enabling `Debug` temporarily to
diagnose a live issue without a restart — is a basic production requirement.

**Tradeoffs and things to consider:**
- Store `min_level` as an `Atomic.t` in `Logger.t` (currently it is a plain
  field in an immutable config). Add `Logger.set_level : t -> Level.t -> unit`.
- The `is_enabled` guard already reads `min_level` on every call; switching to
  `Atomic.get` adds one atomic load per guarded call — negligible overhead.
- Consider whether the level should be settable per-sink (a sink that only
  accepts `Error` and above) or only globally on the logger. Global is simpler;
  per-sink is more flexible but requires the worker to re-check level against
  each sink on each entry.
- A signal-based trigger (e.g. SIGUSR1 cycles through levels) is useful but out
  of scope for this feature — note it as a `(* FUTURE *)`.

---

### Sampling and Rate Limiting

A `[%log.debug]` call in a hot path (tight loop, per-request trace) can emit
millions of entries per second, saturating the bounded queue and causing mass
drops for all other fibers sharing the logger. Without per-site rate limiting,
a single misconfigured log call degrades the entire logging pipeline.

**Tradeoffs and things to consider:**
- Token-bucket rate limiting per log site (identified by `src_pos`) is the most
  precise approach but requires a concurrent hash map keyed by `(file, line)` —
  a new dependency or a custom implementation.
- A simpler approach: a global rate limit on the logger (`max_entries_per_sec`)
  with a single token bucket. Less precise but zero new data structures.
- The PPX can inject sampling at compile time: `[%log.debug ~sample:0.01 logger
  "msg"]` generates a `Random.float 1.0 < 0.01 &&` guard before `is_enabled`.
  This avoids runtime overhead for unsampled calls entirely. Consider whether
  the feature doc should make this a library feature, a PPX feature, or both.
- Rate limiting state is mutable and shared across fibers; justify with
  `(* mutable: rate limiter token bucket *)` per Article X.1.

---

### Metrics and Observability

`Logger.diagnostics` exposes `drop_count` and `queue_depth` as a point-in-time
snapshot with no hook for external metrics systems. A production deployment
needs monotonic counters (entries emitted, entries dropped, bytes written) and
latency histograms for `sink.emit` to integrate with Prometheus, statsd, or
OpenTelemetry.

**Tradeoffs and things to consider:**
- The simplest extension: add `emit_count : int Atomic.t` alongside `drop_count`
  in `Logger.t`; expose both in `diagnostics`. Zero new dependencies.
- For Prometheus integration, consider a `Logger.register_metrics` function that
  accepts a callback `(name:string -> labels:(string*string) list -> float -> unit)`
  and calls it on each metrics update. This decouples the library from any
  specific metrics client.
- Latency histograms for `sink.emit` require timestamps around each emit call in
  the worker loop — low overhead but non-trivial to bucket correctly.
- OpenTelemetry meter integration would be a separate optional package
  (`olog-otel`), not part of the core library, to avoid a mandatory OTLP
  dependency.
- Worker batching belongs with this work: `Output.t.write` already takes
  `Entry.t list` but is only ever called with single entries, so the worker
  performs one write syscall per entry. Greedily draining the queue into one
  `write` call per wake-up pairs naturally with emit-count and bytes-written
  counters (see ANALYSIS.md "dead generality").
- Splitting `drop_count` by cause (queue-full vs. post-shutdown vs.
  cancellation loss) also belongs here — a single counter conflates distinct
  operational signals (see ANALYSIS.md).

---

### HTTP Output Destination

Implement a correct, usable HTTP output sink as a separate `olog-http` package.
The previous `Output.http` implementation was removed in Tier 1 because it was
incomplete and added mandatory dependencies to the core library. A standalone
package can depend on `cohttp-eio` (or `piaf`, or raw `Eio.Net`) without
affecting users who only need file or stdout output.

**Tradeoffs and things to consider:**
- Package structure: `olog-http` as a separate opam package depending on `olog
  (= :version)` and a chosen HTTP client library. Mirrors the `olog_ppx`
  separation pattern.
- Minimum viable implementation: persistent connection, synchronous send per
  entry, basic error logging to stderr on failure. Robustness (retry, backoff,
  circuit breaker) is explicitly deferred — the feature doc should mark these as
  `(* FUTURE *)` items with a reference to a follow-up feature.
- HTTP target format: NDJSON (one JSON object per line, matching
  `Formatter.json` output) is the most broadly supported format for log
  aggregators (Loki, Elasticsearch, Datadog). Confirm the target format before
  designing the API.
- Authentication: API key via `Authorization` header is the common case. The
  feature doc should define how credentials are injected (function parameter, not
  environment variable, to keep the library pure).

---

### Failure-Pattern Lessons Library

ANALYSIS.md proposes a `docs/lessons/` library mirroring the ADR pattern but
for failure patterns: after each bug class is fixed, record the symptom, the
root cause, and the rule that prevents recurrence.

**Tradeoffs and things to consider:**
- Every lesson must state its enforcement rung (type system > test > lint/CI
  > review checklist > prose) and justify staying at "checklist" if nothing
  stronger exists.
- Checklist-rung rules feed CONTRIBUTING.md's Review Checklist so they are
  applied at every PR rather than relying on memory.
- Candidate first entries (from ANALYSIS.md): CAS-only atomics transitions,
  no catch-all exception handlers, one-serializer-per-type,
  mli-claims-need-tests, formatters-ship-round-trip-tests.

---

## Tier 3

Ecosystem integrations and long-term API stability. Complete before a 1.0
release commitment.

---

### Configuration from Environment

Loggers must currently be constructed in code with an explicit `Logger.Config`
record. There is no way to configure `min_level`, `queue_depth`, or sinks from
environment variables or a config file. Operators cannot change log verbosity
in a running container without recompiling.

**Tradeoffs and things to consider:**
- A `Logger.Config.from_env : unit -> Config.t` function that reads
  `OLOG_LEVEL`, `OLOG_QUEUE_DEPTH`, etc. and returns a config. Code-level
  config takes precedence when merged explicitly.
- Format for `OLOG_LEVEL`: case-insensitive string (`"debug"`, `"DEBUG"`).
  Invalid values should log a warning to stderr and fall back to `Info`.
- A file-based config (JSON or TOML) enables per-subsystem level overrides but
  requires a parsing dependency. Decide whether this feature covers file-based
  config or only environment variables.
- This feature interacts with Dynamic Level Filtering (Tier 2): if the level
  can be set from the environment at startup, the same mechanism should support
  runtime changes via a signal or reload endpoint.

---

### Multi-logger and Logger Registry

There is no global logger registry. Each subsystem must thread its `Logger.t`
through every function call. Library authors cannot log without receiving a
logger from the application, creating a coupling between library internals and
application logging configuration.

**Tradeoffs and things to consider:**
- A registry keyed by name string (`"app"`, `"app.db"`, `"app.http"`) with
  prefix-based level inheritance: `"app.db"` inherits `"app"`'s level unless
  overridden.
- Global mutable state: the registry is inherently global. In Eio, a process-wide
  registry stored in a `Mutex`-protected hash table is the straightforward
  approach; a fiber-local registry is possible but unusual and harder to reason
  about.
- Library authors calling `Olog.get "mylib"` before the application has
  registered a sink would get a no-op logger (drops all entries). This is safer
  than panicking but must be documented clearly.
- Interaction with `Eio.Switch`: registered loggers hold resources (worker
  fiber, file handles). The registry must track which switch each logger was
  created under and handle switch cancellation gracefully.

---

### Context Inheritance Decision

Must be resolved before OpenTelemetry Trace Context Propagation. ADR 0002
chose deliberate non-inheritance: forked fibers start with an empty context.
OTel trace propagation almost always wants inheritance (a request's
`trace_id` should follow `Fiber.both` branches), and the README currently
advertises automatic propagation to child fibers — the opposite of the
implementation. Retrofitting inheritance onto raw effects means switching to
`Eio.Fiber.with_binding` or threading context explicitly — an API break, so
this must be decided before the context API is considered stable (see
ANALYSIS.md).

---

### OpenTelemetry Trace Context Propagation

The `Context` module stores arbitrary `(string * Value.t)` pairs. There is no
convention for W3C `traceparent`/`tracestate` fields, so logs cannot be
correlated with distributed traces without ad hoc field-naming agreements.

**Tradeoffs and things to consider:**
- Define a convention: `Context.set_trace_context ~trace_id ~span_id ~flags`
  stores the W3C fields under reserved key names (`"trace_id"`, `"span_id"`,
  `"trace_flags"`). This is a naming convention, not a schema enforcement.
- A separate `olog-otel` package could provide a typed `Trace_context.t` that
  serialises to the W3C `traceparent` format and integrates with an OTLP
  exporter. This keeps OTLP off the core dependency graph.
- The feature doc should decide whether `trace_id` and `span_id` are `Value.String`
  (hex-encoded) or whether a new `Value.Bytes` constructor is needed. Hex
  strings are simpler; `Bytes` would require extending `Value.t`.

---

### Formatter Extensibility

`Formatter.t` is a closed type — only `json`, `logfmt`, and `text` are
available. Users cannot add a custom formatter (CEF for SIEM, GELF for
Graylog, logfmt variants) without forking the library or wrapping a sink.

**Tradeoffs and things to consider:**
- Expose `Formatter.make : (Entry.t -> string) -> t` to allow user-defined
  formatters without changing the `Output` API. The `Output` layer passes
  `Entry.t` through the formatter before writing, regardless of whether the
  formatter is built-in or user-defined.
- Alternatively, expose `Formatter.t` as an abstract record with one field
  (`format : Entry.t -> string`) so users can construct it directly without a
  smart constructor. This is simpler but exposes the internal representation.
- Consider whether formatters should support streaming output (writing to a
  `Buffer.t` directly rather than returning a `string`) for large entries.
  Streaming avoids one string allocation per entry at the cost of a more complex
  interface.

---

### Compatibility and Deprecation Policy

Before committing to a 1.0 release, every public value in `olog.mli` becomes
a long-term support commitment. Without an explicit stability policy, any
internal refactoring becomes a breaking change, and semver cannot be applied
mechanically.

**Tradeoffs and things to consider:**
- Define three stability tiers: **stable** (no breaking changes without a major
  version bump), **experimental** (may change in minor versions, marked with
  `[@alert experimental "..."]`), and **internal** (not exposed in `.mli`).
- Apply the tiers before 1.0: most of the current API can be marked stable;
  `diagnostics`, `sink`, and the PPX extension syntax are candidates for
  experimental until they have seen real-world use.
- `[@alert deprecated "use X instead"]` should be the migration path for any
  value removed between minor versions; removal happens only at major versions.
- Consider adopting `dune`'s `(deprecated_library_name ...)` stanza for any
  future module renames to preserve backward compatibility during transitions.
