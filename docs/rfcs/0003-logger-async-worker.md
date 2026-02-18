# RFC 0003: Logger and Async Worker

| Field       | Value                              |
|-------------|------------------------------------|
| **RFC**     | 0003                               |
| **Title**   | Logger and Async Worker            |
| **Status**  | Draft                              |
| **Created** | 2026-02-18                         |
| **Session** | 3                                  |

---

## Summary

Introduce `Logger`, the async emission core of olog. `Logger.t` is an opaque handle over a name, configuration, a bounded `Eio.Stream.t` queue, and an atomic drop counter. `Logger.create` forks a worker daemon fiber under a caller-supplied switch; the worker drains the queue, dispatching each `Entry.t` to a list of output sinks in order. `Logger.log` guards `Entry.t` construction behind a synchronous level check — zero allocation when the level is below the filter — stamps the entry from the injected clock, and enqueues it non-blocking (dropping if the queue is full). Drops are counted atomically. `Logger.diagnostics` exposes queue depth, capacity, and drop count as a structured value.

**Implementation note:** The `clock` parameter in the shipped `.mli` uses `_ Eio.Time.clock` rather than the `[> Eio.Time.clock_ty] Eio.Resource.t` form shown in §Public Interface below; these are type-equivalent in Eio. The clock is stored internally as a `unit -> Ptime.t` closure — see ADR 0003.

---

## Motivation

RFC 0001 established the pure data model (`Level`, `Value`, `Entry`). RFC 0002 added fiber-local context propagation (`Context`). olog now needs its async emission layer: a component that decouples log callers from I/O, absorbs bursts via a bounded queue, and fans out to one or more output sinks.

Existing OCaml logging libraries offer no equivalent:

- `logs` is synchronous. Every log call blocks the caller until output completes. In a high-throughput Eio server, this serialises all log calls through a single writer — introducing latency spikes and preventing burst absorption.
- Lwt-based loggers require monadic code. Direct-style Eio callers cannot use them without monad transformers.
- No standard OCaml logging library provides a bounded async queue, configurable output sinks, and an atomic drop counter with zero overhead when logging is disabled.

Eio's `Fiber.fork_daemon` provides a clean pattern for this: the worker fiber is tied to a switch's lifetime, requiring no explicit teardown. The switch-based lifecycle eliminates a class of resource-leak bugs that require manual `stop`/`close` calls in other designs.

---

## Scope

### In Scope

- `Logger.sink` — output destination type: a concrete record of three functions (`emit`, `flush`, `close`)
- `Logger.Config.t` — logger configuration (min_level, queue_depth, sinks)
- `Logger.Config.default` — sensible defaults
- `Logger.diagnostics` — structured metrics snapshot type
- `Logger.t` — opaque logger handle
- `Logger.create ~sw ~clock config name` — create logger, fork worker daemon
- `Logger.is_enabled : t -> Level.t -> bool` — hot-path level guard
- `Logger.log` — enqueue an entry; zero `Entry.t` allocation when level is disabled
- `Logger.flush : t -> unit` — block caller until queued entries are processed
- `Logger.diagnostics : t -> diagnostics` — point-in-time metrics snapshot
- Worker: `Eio.Fiber.fork_daemon ~sw`, drains queue FIFO, calls sinks, catches sink errors
- Non-blocking enqueue: drop and increment atomic counter if queue is at capacity
- `.mli` file and Alcotest integration tests using `Eio_main.run`

### Out of Scope

- Formatters (JSON, logfmt text) — concern of the sink implementation
- Concrete sink implementations (stdout, stderr, file) — examples, not core library
- PPX for source location capture at call sites
- Wiring `Context.current` into `Logger.log` (deferred to a later session)
- Dynamic (runtime) level changes on an active logger
- Log sampling, rate limiting, or per-sink level filters
- Multi-logger hierarchies or logger inheritance
- Explicit `Logger.close` / `Logger.stop` (switch cancellation is the shutdown mechanism)
- `Logger.t` as a shared/global singleton

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `Logger.sink` is a record type: `{ emit : Entry.t -> unit; flush : unit -> unit; close : unit -> unit }` |
| F2  | `Logger.Config.t` is a record: `{ min_level : Level.t; queue_depth : int; sinks : Logger.sink list }` |
| F3  | `Logger.Config.default` is `{ min_level = Info; queue_depth = 1024; sinks = [] }` |
| F4  | `Logger.t` is abstract — its representation is not part of the public interface |
| F5  | `Logger.create ~sw ~clock config name` initialises a bounded `Eio.Stream.t` of capacity `config.queue_depth`, an `int Atomic.t` drop counter at 0, and forks exactly one worker daemon fiber under `sw` |
| F6  | The worker fiber is created with `Eio.Fiber.fork_daemon ~sw`; it terminates automatically when `sw` is cancelled — no explicit shutdown API is exposed |
| F7  | When the worker terminates (switch closes), it calls `sink.close ()` for each sink in `config.sinks` in list order; exceptions from `close` are caught and ignored |
| F8  | `Logger.is_enabled logger level` returns `true` iff `Level.compare level config.min_level >= 0` |
| F9  | `Logger.log logger ~level ~fields ~src_pos message` returns immediately without constructing any heap-allocated `Entry.t` when `is_enabled logger level` is `false` |
| F10 | When `is_enabled logger level` is `true`, `Logger.log` reads the current time from the stored clock, constructs an `Entry.t`, and attempts to enqueue it |
| F11 | Enqueue is non-blocking: if the queue is at capacity, the entry is dropped and the atomic drop counter is incremented by 1; the calling fiber is never suspended |
| F12 | The worker dequeues `Entry.t` values in FIFO order and calls `sink.emit entry` for each sink in `config.sinks` in list order |
| F13 | If `sink.emit` raises, the worker catches the exception and continues with the next sink and entry — the worker never terminates due to a sink error |
| F14 | `Logger.flush logger` places a flush barrier in the queue; it suspends the calling fiber until the worker has processed all entries enqueued before the barrier; it then calls `sink.flush ()` for each sink in list order |
| F15 | `Logger.diagnostics logger` returns a `diagnostics` record with `name` (string), `queue_depth` (current queue length snapshot), `queue_capacity` (configured bound), and `drop_count` (current atomic value) |
| F16 | All public functions on `Logger.t` are safe to call concurrently from multiple Eio fibers |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | OCaml >= 5.2.0 |
| NF2 | Eio >= 1.0 (`Eio.Stream.t`, `Eio.Fiber.fork_daemon`, `Eio.Time`) |
| NF3 | The `Logger` library module may depend on `eio`; it must not depend on `eio_main` or any Unix backend |
| NF4 | `Logger.log` when `is_enabled` returns `false`: zero heap allocation after the level comparison |
| NF5 | The drop counter is an `int Atomic.t` — no mutex, no lock |
| NF6 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` must all pass |
| NF7 | Integration tests use real Eio environments (`Eio_main.run`) — `Eio.Mock` is not used for queue or worker behaviour |

---

## Public Interface

```ocaml
(** Logger.mli *)

(** Asynchronous structured logger backed by a bounded queue and a dedicated
    worker fiber.

    A logger decouples log callers from I/O: {!log} enqueues an {!Entry.t}
    and returns immediately. A worker daemon fiber drains the queue and
    dispatches entries to {!sink} implementations in the order they appear in
    {!Config.t}. If the queue is full, entries are dropped and counted —
    callers are never suspended.

    The worker's lifetime is tied to the {!Eio.Switch.t} passed to {!create};
    it terminates automatically when the switch closes. *)

type sink = {
  emit  : Entry.t -> unit;
  (** Called by the worker fiber for each log entry. May perform I/O.
      If this raises, the worker catches the exception and continues. *)
  flush : unit -> unit;
  (** Flush any buffered output. Called after all preceding entries have been
      emitted when {!flush} is invoked on the logger. *)
  close : unit -> unit;
  (** Release resources. Called once when the switch closes.
      Exceptions are caught and ignored. *)
}
(** An output destination — a record of three functions handling emission,
    flushing, and teardown. Compose multiple sinks via {!Config.sinks}. *)

module Config : sig
  type t = {
    min_level   : Level.t;
    (** Minimum level accepted. Entries below this level are discarded
        before any queue allocation. *)
    queue_depth : int;
    (** Maximum number of entries in the async queue. When full, new
        entries are dropped and the drop counter is incremented.
        Must be a positive integer. *)
    sinks       : sink list;
    (** Output destinations, called in list order for each emitted entry. *)
  }

  val default : t
  (** [default] is [{min_level = Info; queue_depth = 1024; sinks = []}]. *)
end

type diagnostics = {
  name           : string;
  (** Human-readable logger identifier. *)
  queue_depth    : int;
  (** Current number of entries in the queue at snapshot time. *)
  queue_capacity : int;
  (** Configured maximum queue size. *)
  drop_count     : int;
  (** Total number of entries dropped since the logger was created. *)
}
(** A point-in-time snapshot of a logger's internal metrics. *)

type t
(** An asynchronous structured logger. Opaque — use {!create} to construct. *)

val create :
  sw:Eio.Switch.t ->
  clock:[> Eio.Time.clock_ty] Eio.Resource.t ->
  Config.t ->
  string ->
  t
(** [create ~sw ~clock config name] creates a new logger named [name].
    Initialises a bounded queue of [config.queue_depth] entries, an atomic
    drop counter at zero, and forks a worker daemon fiber under [sw]. The
    worker drains the queue, calling each sink in [config.sinks] for every
    entry. When [sw] closes, the worker calls [sink.close ()] on each sink
    before terminating.

    @param sw     The enclosing switch. The worker is tied to this lifetime.
    @param clock  Eio realtime clock used to timestamp each entry at call time.
    @param config Logger configuration (level, queue depth, sinks).
    @param name   Human-readable identifier, used in {!diagnostics}. *)

val is_enabled : t -> Level.t -> bool
(** [is_enabled logger level] returns [true] iff [level] is at or above the
    logger's configured minimum level.

    Use this to guard expensive field construction at call sites when callers
    build field lists before passing them to {!log}. *)

val log :
  t ->
  level:Level.t ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log logger ~level ~fields ~src_pos message] enqueues an {!Entry.t} for
    async emission.

    If [level] is below the logger's minimum level, returns immediately
    without allocating an [Entry.t]. If the queue is full, the entry is
    dropped and the drop counter is incremented — the calling fiber is never
    suspended.

    @param level   Log severity.
    @param fields  Structured key-value pairs (default [[]]).
    @param src_pos Source location, typically injected by a PPX (default [None]).
    @param message Human-readable log message. *)

val flush : t -> unit
(** [flush logger] suspends the calling fiber until all entries currently in
    the queue have been processed by the worker and each sink's [flush]
    function has been called.

    Safe to call concurrently with {!log}. *)

val diagnostics : t -> diagnostics
(** [diagnostics logger] returns a point-in-time snapshot of the logger's
    internal metrics. Safe to call from any fiber at any time. *)
```

---

## Options Considered

### Option A: `fork_daemon` for worker lifetime — chosen

Tie the worker fiber's lifetime to the switch using `Eio.Fiber.fork_daemon ~sw`.

**Pros:** No explicit `Logger.stop` / `Logger.close` API needed. Aligns with Eio's structured concurrency model: all fibers under a switch are cancelled together. Prevents resource leaks — the worker cannot outlive its switch. Callers already hold a switch for their Eio code; no new handle to manage.

**Cons:** Callers must pass a `Switch.t` to `Logger.create`, which is slightly unusual for a library-style API. `fork_daemon` runs until the switch is cancelled; the worker loop must never return `` `Stop_daemon `` prematurely.

### Option B: `fork` with explicit stop channel

Use `Eio.Fiber.fork ~sw` and send a stop signal — a sentinel value in the queue or a separate `Eio.Stream.t`.

**Pros:** Logger could implement its own `Logger.stop : t -> unit`. Slightly more explicit about when the worker stops.

**Cons:** Requires a `Logger.stop` call in all teardown paths — easy to forget, causing the worker to run indefinitely until the switch cancels. The stop signal must be sequenced before switch close. `fork_daemon` exists precisely to eliminate this pattern. **Rejected.**

### Option C: Synchronous emission (no worker fiber)

Remove the async queue entirely. `Logger.log` calls `sink.emit` directly in the caller's fiber.

**Pros:** Simpler implementation — no queue, no worker, no drop counting.

**Cons:** Blocking I/O in any sink propagates to the caller's fiber. No burst absorption. Slow sinks starve concurrent fibers. Logging would couple request-handling latency to sink throughput — the core problem async queues solve. **Rejected.**

### Option D: Block caller when queue is full (backpressure model)

Suspend the calling fiber until space is available (`Eio.Stream.add` blocks by default when the stream is at capacity).

**Pros:** No entries are ever silently dropped.

**Cons:** Logging must never slow down the application. Blocking a request-handling fiber on a full log queue allows a slow sink to stall all application progress. Drop-with-count is the established pattern in production log pipelines (Logstash, Vector, Fluentd) — visibility via `diagnostics.drop_count` is the correct remedy. **Rejected.**

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| `sink.emit` blocks indefinitely | Worker stalls; queue fills; drops accumulate | Document that sinks must not block indefinitely; `diagnostics.drop_count` is the alert signal |
| TOCTOU race in capacity check (stream length snapshot vs add) | Occasional slight overfill by one or two entries | Acceptable for a drop-model logger; document as a known approximation |
| `Logger.flush` racing with switch cancellation | `flush` blocks forever if worker has stopped | Document that `flush` must be called before the switch closes; a flush timeout is out of scope for this RFC |
| Calling `Logger.log` outside an Eio scheduler | `Eio.Time.now` raises `Effect.Unhandled` | Document that all Logger functions must be called inside `Eio_main.run`; integration tests verify this |
| `Eio.Time.clock_ty` API changes between Eio versions | Compilation failure | Pin `eio >= 1.0`; isolate clock call to one function in the implementation |

---

## Open Questions

None — requirements are fully specified.
