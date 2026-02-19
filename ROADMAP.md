# olog Roadmap

Planned RFCs in priority order. Each tier represents a cohesive phase of work;
all items in a tier should be completed before the next tier begins.

---

## Tier 1

Core correctness and robustness. The library is not suitable for any production
use until these are complete.

---

### Remove HTTP Output Destination

The current `Output.http` implementation is incomplete: it opens a new TCP
connection per write with no pooling, no retry, no backoff, and no circuit
breaker. It also makes `cohttp-eio` a mandatory runtime dependency of the core
`olog` package, inflating the dependency footprint for users who only need
stdout or file output. Removing it now, before any public release, is cheaper
than supporting it.

**Tradeoffs and things to consider:**
- Remove `Output.http`, `Output.Http_config`, and all references in `lib/output.ml` and `lib/output.mli`.
- Remove `cohttp-eio` from `lib/dune`, the `olog` package `depends` in `dune-project`, and `olog.opam`.
- Remove the corresponding test cases in `test/test_output.ml`.
- A proper HTTP sink belongs in a separate `olog-http` package (Tier 2), keeping
  the core library dependency-light. Users who need HTTP output can opt in.
- Consider whether the `sink` record-of-functions interface is sufficient for a
  future `olog-http` package, or whether a richer lifecycle API is needed first
  (see Graceful Shutdown below).

---

### PPX Test Coverage: Float, Null, and Compile-Error Negative Tests

`Value.Float` literal auto-wrapping and the `` `Null `` backtick shorthand are
implemented in `ppx/ppx_olog.ml` but have no test cases. Additionally, there
are no negative tests verifying that malformed PPX payloads (wrong arity,
non-string message literal) produce a clear, actionable compile error rather
than a cryptic location error from ppxlib's internals.

**Tradeoffs and things to consider:**
- Float wrapping: straightforward to add alongside the existing `test_literal_*`
  pattern; the main subtlety is that `Value.Float 3.14` equality must use
  `Float.equal` or `Alcotest.float` rather than structural `=` to avoid
  floating-point comparison surprises.
- `` `Null `` wrapping: unlike other backtick forms, `Null` takes no argument;
  the test must verify that the field `("k", Value.Null)` is emitted.
- Negative compile-error tests require a different mechanism — ppxlib error
  expansion cannot be tested via `Alcotest` at runtime. Options: use `dune`'s
  `(rule (action (run ocamlfind ...)) (expected ...))` to snapshot expected
  compiler output, or use `ppxlib`'s own test infrastructure
  (`ppxlib.metaquot`, `ppx_expect`). Decide which approach fits the project's
  existing test discipline before writing.
- Keep negative tests in a separate file (`test/test_ppx_errors.ml`) so they
  can be excluded from normal `dune test` if the snapshotting approach requires
  a separate driver.

---

### Structured Error and Exception Capture

There is no `Logger.error_exn` or equivalent that captures an OCaml exception's
backtrace and attaches it as structured fields. The current workaround,
`~fields:[("exn", Value.String (Printexc.to_string e))]`, loses the backtrace
and produces an unindexed string blob that cannot be queried or alerted on. For
a logging library to be useful in practice, exception logging must be a
first-class operation.

**Tradeoffs and things to consider:**
- Decide on the structured field schema: at minimum `exn_type` (module path of
  the exception), `exn_msg` (human message), and `backtrace` (raw string or
  array of frames). Adding backtrace as an array aligns with JSON log aggregators
  (Loki, Elasticsearch) but requires a new `Value.Array` constructor — a
  breaking change to `Value.t`.
- Alternatively, `backtrace` as a newline-separated `Value.String` avoids
  extending `Value.t` but is harder to query. Document this trade-off
  explicitly in the RFC.
- A PPX extension `[%log.error_exn logger e "msg"]` would be the ergonomic
  entry point; the PPX expansion should call `Printexc.get_backtrace ()` at the
  call site (in the calling fiber, before the exception is re-raised or the
  stack unwinds) — not inside the worker.
- `Printexc.get_backtrace ()` returns an empty string unless `OCAMLRUNPARAM=b`
  is set. The implementation should document this and consider calling
  `Printexc.record_backtrace true` at library init, or requiring the user to
  set it explicitly.

---

### Context Wiring in Logger

`Logger.log` never reads `Context.current ()`. The fiber-local context
propagation module is completely inert — fields set via `Context.with_context`
do not appear in any emitted log entry. This is the most visible correctness gap
in the library; the `examples/structured.ml` already carries a `(* FUTURE *)`
comment marking it.

**Tradeoffs and things to consider:**
- Context must be captured at call-site time in the calling fiber, not inside
  the async worker. The worker runs in its own fiber where
  `Context.current ()` would return the empty context. The `Entry.t` must
  therefore be constructed (including context snapshot) before the entry is
  enqueued, not after.
- Merging strategy: when a field key appears in both `~fields` and
  `Context.current ()`, which wins? Explicit call-site fields should override
  context fields (call-site is more specific), but this must be documented.
- Context snapshot is a `(string * Value.t) list` copy. For hot paths with large
  contexts this is an allocation per log call. Consider whether the context
  should be stored by reference (unsafe if the context mutates) or always
  snapshotted (safe, current approach of `Context`).
- Add regression tests: log inside `Context.with_context`, verify context fields
  appear in the emitted entry; log outside, verify they don't.

---

### Log Rotation and File Sink Lifecycle

`Output.file` reopens the file descriptor on every write using
`Eio.Path.with_open_out`. This is correct for correctness (no persistent handle
to leak) but unacceptably slow for high-throughput logging and incompatible with
log rotation tools (logrotate sends SIGHUP expecting the process to reopen the
file). There is also no max-size rollover or date-based rotation.

**Tradeoffs and things to consider:**
- A persistent file handle (opened once in `Output.make`, closed in
  `sink.close`) requires the caller to pass a `Eio.Switch.t` into
  `Output.file`, which changes the public API. Evaluate whether this is the
  right moment to introduce a more explicit lifecycle model.
- SIGHUP-based reopen: Eio has no built-in POSIX signal handling; wiring signal
  delivery requires `Eio_unix.signal` or a dedicated signal fiber. Document
  whether this is in scope for the initial rotation RFC or deferred.
- Max-size rollover is simpler to implement without signal handling: track bytes
  written, reopen when a threshold is crossed. But it requires the file sink to
  maintain mutable state — justified here (`(* mutable: rotation counter *)`).
- Consider whether rotation belongs in the `sink` or as a wrapper sink
  (a `rotating_file` sink that delegates to an inner file sink). The wrapper
  approach composes better but requires the `sink` interface to support
  `reopen` or similar lifecycle events.

---

### Graceful Shutdown and Drain

When a switch is cancelled (process shutdown, SIGTERM, test teardown), the
worker daemon fiber terminates immediately via `Eio.Cancel.Cancelled`
propagating through `Eio.Stream.take`. Any entries already enqueued but not yet
emitted are silently dropped. For a production logger, silent drop on shutdown
is unacceptable — the last entries before a crash or restart are often the most
important.

**Tradeoffs and things to consider:**
- One approach: replace `Fiber.fork_daemon` with `Fiber.fork`; the worker fiber
  then keeps the switch alive until it finishes draining. The caller must
  explicitly signal shutdown (e.g. by sending a `Shutdown` sentinel onto the
  queue, analogous to `Flush`). This changes the lifetime model — the logger
  no longer terminates automatically when the surrounding switch closes.
- Another approach: keep the daemon model but register a `Fiber.on_cancel` hook
  that drains the queue synchronously before allowing cancellation to proceed.
  This is simpler but blocks cancellation propagation, which may surprise callers.
- `Logger.flush` already provides a synchronous drain point; the RFC should
  define whether calling `Logger.flush` before closing the switch is the
  documented contract (user responsibility) or whether the library guarantees
  drain on its own.
- The RFC should include a test: enqueue N entries, cancel the switch without
  calling `flush`, and assert all N entries are delivered to the sink.

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
  of scope for this RFC — note it as a `(* FUTURE *)`.

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
  the RFC should be a library feature, a PPX feature, or both.
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
  circuit breaker) is explicitly deferred — the RFC should mark these as
  `(* FUTURE *)` items with a reference to a follow-up RFC.
- HTTP target format: NDJSON (one JSON object per line, matching
  `Formatter.json` output) is the most broadly supported format for log
  aggregators (Loki, Elasticsearch, Datadog). Confirm the target format before
  designing the API.
- Authentication: API key via `Authorization` header is the common case. The
  RFC should define how credentials are injected (function parameter, not
  environment variable, to keep the library pure).

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
  requires a parsing dependency. Decide whether this RFC covers file-based
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
- The RFC should decide whether `trace_id` and `span_id` are `Value.String`
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
