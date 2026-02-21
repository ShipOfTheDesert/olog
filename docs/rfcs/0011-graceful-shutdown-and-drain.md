# RFC 0011: Graceful Shutdown and Drain

| Field       | Value                              |
|-------------|------------------------------------|
| **RFC**     | 0011                               |
| **Title**   | Graceful Shutdown and Drain        |
| **Status**  | Draft                              |
| **Created** | 2026-02-20                         |
| **Session** | 11                                 |

---

## Problem

When a switch is cancelled (process shutdown, SIGTERM, test teardown), the
worker daemon fiber terminates immediately via `Eio.Cancel.Cancelled`
propagating through `Eio.Stream.take`. The `Fun.protect ~finally:close_all`
block calls `sink.close ()` on each sink, but any entries already enqueued
and not yet emitted are silently dropped.

For a production logger, silent drop on shutdown is unacceptable. The last
entries before a crash or restart are often the most diagnostic — they
describe the error condition, the state at the moment of failure, or the
reason for the shutdown. Losing them undermines the primary value of
structured logging.

RFC 0003 explicitly scoped out "Explicit `Logger.close` / `Logger.stop`",
choosing `fork_daemon` for its simplicity. That was the right call for the
initial implementation, but production use requires a shutdown contract
that guarantees delivery of enqueued entries.

The current workaround — calling `Logger.flush` before the switch closes —
is fragile. It requires callers to know the shutdown sequence and to place
`flush` at the right point. If cancellation arrives unexpectedly (SIGTERM,
unhandled exception), the `flush` call is never reached and entries are
lost. The library should provide a first-class shutdown mechanism that
handles both the deliberate and the unexpected cases.

---

## Scope

**In scope:**

- Write red-phase integration tests (per Article III) that exercise the
  expected shutdown and drain behaviors, and confirm they fail against
  the current implementation before any production code changes.
- Extend the internal `msg` type with a `Shutdown` sentinel variant
  (analogous to the existing `Flush` variant).
- Add `Logger.shutdown : t -> unit` that sends a `Shutdown` sentinel to
  the queue and suspends the calling fiber until the worker has drained
  all preceding entries, flushed all sinks, and closed all sinks.
- After `shutdown` completes, `Logger.log` and `Logger.log_exn` calls
  are no-ops (entries are dropped and the drop counter is incremented).
- After `shutdown` completes, `Logger.flush` returns immediately without
  blocking.
- Add best-effort drain on unexpected cancellation: the worker catches
  `Eio.Cancel.Cancelled`, drains remaining queue entries via
  `Eio.Stream.take_nonblocking` under `Eio.Cancel.protect`, emits them
  to sinks, then allows the `finally` block to close sinks.
- Add `is_shutdown : bool` field to `Logger.diagnostics`.
- Update `logger.mli` doc comments to reflect the new shutdown contract.
- Update examples if they use patterns affected by the change.
- Record an ADR documenting the decision to continue draining after
  `sink.emit` failures during drain-on-cancel, its tradeoffs, and
  future work.
- Verify the full quality gate passes.

**Out of scope:**

- Shutdown timeout. If a sink's `flush` or `close` hangs indefinitely,
  `shutdown` blocks indefinitely. A timeout mechanism is a separate
  concern; callers can use `Eio.Time.with_timeout` externally.
- Graceful degradation under sustained load after shutdown (e.g.,
  accepting entries into a secondary buffer while draining).
- SIGTERM signal handling. The library provides `shutdown`; wiring it to
  SIGTERM is the caller's responsibility via `Eio_unix` or similar.
- Changes to `Output.t` or `Output.to_sink`.
- Changes to `Logger.sink` — no new fields are added.
- Changes to `Entry.t`, `Entry.create`, `Context`, or the PPX.
- Changes to `Formatter.t` or any formatter implementation.
- Dynamic level changes during shutdown.

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F0  | Before any production code changes, red-phase integration tests are written that exercise shutdown and drain behaviors. These tests must fail against the current implementation and pass after the changes are implemented. |
| F1  | The internal `msg` type is extended with `Shutdown of unit Eio.Promise.u`. |
| F2  | `Logger.shutdown : t -> unit` enqueues a `Shutdown` sentinel onto the queue (blocking until space is available, like `flush`). The calling fiber is suspended until the worker resolves the promise. |
| F3  | When the worker dequeues a `Shutdown` message, it has already processed all preceding `Log` and `Flush` messages in FIFO order (guaranteed by `Eio.Stream.t` ordering). The worker then calls `sink.flush ()` on each sink in list order, calls `sink.close ()` on each sink in list order, resolves the shutdown promise, and exits. |
| F4  | `Logger.t` gains an internal `closed : bool Atomic.t` field, initially `false`. `shutdown` sets it to `true` before enqueuing the `Shutdown` sentinel. |
| F5  | After `shutdown` sets `closed` to `true`, `Logger.log` and `Logger.log_exn` check `closed` first. If `true`, the entry is dropped and the drop counter is incremented — no `Entry.t` is constructed, no `Context.current` is called. |
| F6  | After `shutdown` completes, `Logger.flush` checks `closed`. If `true`, it returns immediately without enqueuing a `Flush` message or blocking. |
| F7  | `shutdown` is idempotent. The second and subsequent calls return immediately without blocking. Implementation: check `closed`; if already `true`, return. |
| F8  | When the worker's `Eio.Stream.take` raises `Eio.Cancel.Cancelled` (unexpected switch cancellation without a prior `shutdown` call), the worker catches the exception and drains remaining entries from the queue using `Eio.Stream.take_nonblocking` in a loop, emitting each `Log` entry to sinks and resolving each `Flush`/`Shutdown` promise. This drain runs under `Eio.Cancel.protect` so that sink I/O is not immediately cancelled. |
| F9  | During drain-on-cancel, if `sink.emit` raises for one entry, the worker catches the exception and continues draining subsequent entries. This is consistent with the existing error-isolation contract (RFC 0003 F13) and documented in ADR 0007. |
| F10 | After the drain-on-cancel loop completes, the worker calls `sink.flush ()` and then `sink.close ()` on each sink in list order (via the existing `Fun.protect ~finally` mechanism). |
| F11 | `sink.close ()` is called exactly once per sink regardless of shutdown path (explicit `shutdown`, unexpected cancellation, or switch close). The worker uses a local `closed_sinks` guard to ensure idempotent close. |
| F12 | `Logger.diagnostics` returns an `is_shutdown : bool` field reflecting the current value of the `closed` flag. |
| F13 | An integration test enqueues N entries, calls `Logger.shutdown`, and asserts that all N entries were emitted to the sink. |
| F14 | An integration test enqueues N entries, cancels the enclosing switch without calling `flush` or `shutdown`, and asserts that all N entries were emitted to the sink (drain-on-cancel). |
| F15 | An integration test calls `Logger.shutdown`, then calls `Logger.log`, and asserts that the entry is not emitted and the drop counter is incremented. |
| F16 | An integration test calls `Logger.shutdown` and verifies that `sink.flush ()` and `sink.close ()` were each called exactly once. |
| F17 | An integration test verifies that `Logger.flush` called after `Logger.shutdown` returns immediately without blocking. |
| F18 | An integration test verifies that calling `Logger.shutdown` twice does not block or raise. |
| F19 | An integration test verifies that `diagnostics.is_shutdown` is `false` before shutdown and `true` after. |
| F20 | All existing tests in `test/test_logger.ml`, `test/test_output.ml`, `test/test_context.ml`, `test/test_ppx.ml`, and `test/ppx_errors.t` continue to pass unchanged. |
| F21 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all exit 0 with zero warnings. |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | No new opam dependencies. |
| NF2 | OCaml >= 5.2, Eio >= 1.0. |
| NF3 | The `closed` flag is a `bool Atomic.t` — no mutex, no lock. Justification comment per Article X.1: `(* mutable: shutdown flag for post-shutdown drop guard *)`. |
| NF4 | `Logger.shutdown` completes in time proportional to the number of queued entries plus the latency of `sink.flush` and `sink.close` for each sink. No unbounded waits beyond sink I/O. |
| NF5 | The drain-on-cancel path is best-effort. Sinks may fail if their underlying resources (e.g., file handles, network connections) have already been released by the switch's cancellation. Errors from sinks during drain-on-cancel are caught and ignored, consistent with the existing error-isolation contract. |
| NF6 | The `fork_daemon` model is preserved. The worker fiber does not keep the switch alive. `shutdown` is an explicit opt-in; callers who do not call `shutdown` get the existing behavior (entries dropped on switch close) plus the new best-effort drain. |
| NF7 | `opam-dune-lint` reports `olog.opam: OK`. |
| NF8 | Zero overhead on the hot path: the `Atomic.get t.closed` check in `Logger.log` is a single atomic load — no allocation, no syscall. |

---

## Public Interface

### `Logger` module changes (`lib/logger.mli`)

All existing signatures (`create`, `log`, `log_exn`, `flush`, `is_enabled`,
`Config`, `sink`) are unchanged. The `diagnostics` type gains one field.
One function is added.

```ocaml
type diagnostics = {
  name : string;  (** Human-readable logger identifier. *)
  queue_depth : int;
      (** Current number of entries in the queue at snapshot time. *)
  queue_capacity : int;  (** Configured maximum queue size. *)
  drop_count : int;
      (** Total number of entries dropped since the logger was created. *)
  is_shutdown : bool;
      (** [true] after {!shutdown} has been called. When [true], {!log} and
          {!log_exn} are no-ops and {!flush} returns immediately. *)
}
(** A point-in-time snapshot of a logger's internal metrics. *)

val shutdown : t -> unit
(** [shutdown logger] initiates a graceful shutdown of the logger.

    The calling fiber is suspended until:
    1. All entries currently in the queue have been emitted to every sink.
    2. [sink.flush ()] has been called on every configured sink.
    3. [sink.close ()] has been called on every configured sink.

    After [shutdown] returns, subsequent calls to {!log} and {!log_exn} are
    no-ops — entries are dropped and the drop counter is incremented.
    Subsequent calls to {!flush} return immediately without blocking.
    {!diagnostics} reports [is_shutdown = true].

    [shutdown] is idempotent: the second and subsequent calls return
    immediately.

    {b Best-effort drain on unexpected cancellation.} If the enclosing switch
    is cancelled without a prior [shutdown] call, the worker makes a
    best-effort attempt to drain remaining queue entries under
    [Eio.Cancel.protect] before closing sinks. This is not guaranteed to
    succeed if sink resources have already been released by cancellation.
    For guaranteed delivery, call [shutdown] before the switch closes.

    Safe to call concurrently with {!log}. *)
```

Updated doc comment for the module preamble:

```ocaml
(** Asynchronous structured logger backed by a bounded queue and a dedicated
    worker fiber.

    ...existing text...

    The worker's lifetime is tied to the [Eio.Switch.t] passed to {!create};
    it terminates when {!shutdown} is called or when the switch closes. Call
    {!shutdown} before the switch closes to guarantee that all enqueued entries
    are delivered. If the switch closes without a prior {!shutdown}, the worker
    makes a best-effort attempt to drain remaining entries. *)
```

---

## Options Considered

### Option A: Explicit shutdown sentinel with best-effort drain on cancel — chosen

Add a `Shutdown of unit Eio.Promise.u` variant to the internal `msg` type.
`Logger.shutdown` enqueues it and awaits the promise. The worker processes
all preceding entries (FIFO ordering guarantees this), flushes all sinks,
closes all sinks, resolves the promise, and exits the daemon loop. A
`bool Atomic.t` flag prevents post-shutdown enqueue.

For unexpected cancellation (switch closes without `shutdown`), the worker
catches `Eio.Cancel.Cancelled`, drains remaining entries from the queue
via `take_nonblocking` under `Eio.Cancel.protect`, and emits them before
closing sinks.

**Pros:**
- Preserves the `fork_daemon` model — no change to the logger's lifetime
  semantics. Callers who don't need graceful shutdown get the existing
  behavior, enhanced with best-effort drain.
- `shutdown` provides a guaranteed, synchronous drain point. Callers know
  exactly when all entries have been delivered and sinks are closed.
- The `Shutdown` sentinel is the same pattern as the existing `Flush`
  sentinel — minimal conceptual overhead for a reader of the codebase.
- Post-shutdown `log` calls are cheap no-ops (single atomic load).
- `shutdown` is idempotent — safe to call in both normal and error-handling
  paths without tracking state externally.
- Best-effort drain on cancel is a safety net, not a guarantee — this is
  honest about the limitations of draining after cancellation and does not
  promise more than it can deliver.
- No new fields on `Logger.sink` or `Output.t`.

**Cons:**
- Adds an internal `bool Atomic.t` field to `Logger.t`. Minimal cost.
- Callers must remember to call `shutdown` for guaranteed drain. If they
  forget, they get best-effort drain (better than the status quo of zero
  drain) but not a guarantee.
- TOCTOU window: a concurrent `log` call may check `closed = false`, then
  `shutdown` sets `closed = true` and enqueues `Shutdown`. The `log` call
  enqueues its entry after the sentinel. That entry is lost on the explicit
  shutdown path (but drained on the cancel path). This is analogous to the
  existing capacity-check TOCTOU and is documented as a known approximation.

### Option B: Non-daemon worker with required shutdown

Replace `Eio.Fiber.fork_daemon` with `Eio.Fiber.fork`. The worker fiber
keeps the switch alive until it receives a `Shutdown` sentinel. Callers
must call `Logger.shutdown` before the switch can close.

**Pros:**
- Guarantees drain without a separate cancel-path mechanism — the worker
  simply runs until told to stop.
- No best-effort ambiguity — all entries are drained or the switch hangs.

**Cons:**
- Fundamentally changes the logger's lifetime model. A non-daemon fiber
  prevents the switch from closing. If `shutdown` is never called (e.g.,
  an exception bypasses the shutdown path), the switch hangs indefinitely.
  This is the exact problem `fork_daemon` was chosen to avoid in RFC 0003.
- Requires `shutdown` in all teardown paths, including error handlers. Easy
  to forget, causing hangs in production. The daemon model is safer by
  default.
- Every existing test that uses `Eio.Switch.run` without calling `shutdown`
  would hang. All tests must be updated.
- **Rejected.** The lifetime model change introduces a class of hang bugs
  that `fork_daemon` was specifically chosen to prevent.

### Option C: Drain on cancel only — no new API

Keep `fork_daemon` as-is. Modify only the worker's exception handler:
when `Eio.Cancel.Cancelled` is caught, drain remaining entries via
`take_nonblocking` under `Eio.Cancel.protect`, emit them, then close
sinks. No new public API. Document `flush` before switch close as the
recommended practice for guaranteed delivery.

**Pros:**
- Zero API surface change. No migration cost for callers.
- Improves the status quo (zero drain) with best-effort drain.

**Cons:**
- No guaranteed drain. The drain runs under `Cancel.protect`, but sinks may
  use resources tied to the cancelled switch. If those resources are already
  released, sink I/O fails silently. Callers cannot distinguish "all entries
  delivered" from "some entries lost due to cancelled resources."
- The recommended practice ("call `flush` before the switch closes") is
  fragile. It works for deliberate shutdown but not for unexpected
  cancellation — the very scenario where drain matters most.
- No post-shutdown guard. `log` calls after the switch starts closing may
  enqueue entries that are partially drained, partially lost.
- **Rejected.** Best-effort drain is a useful safety net but insufficient as
  the sole mechanism. Production users need a guaranteed drain point.

---

## Decision

We choose **Option A**. `Logger.shutdown` provides a guaranteed synchronous
drain point via the `Shutdown` sentinel, preserving the `fork_daemon`
lifetime model. Best-effort drain on unexpected cancellation is a safety net
that improves the status quo without overpromising. The `bool Atomic.t`
flag prevents post-shutdown enqueue at near-zero cost.

This approach layers graceful shutdown onto the existing architecture with
minimal disruption: one new public function, one new internal message
variant, and one new atomic flag.

---

## Open Questions

None — all questions resolved during review.

| Question | Resolution |
|----------|------------|
| `diagnostics` after `shutdown` | Add `is_shutdown : bool` to `diagnostics`. Source-level breaking change for exhaustive pattern matches on `diagnostics` is acceptable pre-1.0. See F12. |
| `sink.emit` failures during drain-on-cancel | Continue draining subsequent entries, consistent with the existing error-isolation contract (RFC 0003 F13). Document the decision, tradeoffs, and future work in an ADR. See F9. |

---

## Future Work

- **Shutdown timeout:** A `Logger.shutdown_timeout : timeout:float -> t ->
  (unit, [`Timeout]) result` variant that returns `Error `Timeout` if
  draining takes longer than the specified duration. Useful for hard
  shutdown deadlines (e.g., Kubernetes `terminationGracePeriodSeconds`).
- **Drain metrics:** Expose a `drain_count` field in `diagnostics` reporting
  the number of entries drained during shutdown (as distinct from normal
  emission). Useful for alerting on "did we lose entries?"
- **Pre-shutdown hook:** A callback `on_shutdown : unit -> unit` invoked
  before the drain begins. Enables custom actions like logging a "shutting
  down" entry or flushing external buffers.
- **Selective sink abort on repeated failure:** During drain-on-cancel, if a
  sink fails N consecutive times, skip it for remaining entries rather than
  retrying on every entry. Tracked as future work in ADR 0007.
