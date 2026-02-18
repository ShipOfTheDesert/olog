# ADR 0004: Single `Log | Flush` Queue for FIFO Flush Ordering

**Status:** Accepted
**Date:** 2026-02-18
**RFC:** docs/rfcs/0003-logger-async-worker.md

## Context

`Logger.flush` must guarantee that when it returns, all `Entry.t` values
enqueued *before* the flush call have been processed by the worker and each
sink's `flush` function has been called (RFC F14). The worker must also
process log entries and flush barriers in strict arrival order.

Two categories of message must flow from callers to the worker: log entries
(`Entry.t`) and flush barriers (a promise resolver to be signalled when
processing is complete). A design decision is required: share one queue or
use separate channels.

## Decision

We use a single bounded `Eio.Stream.t` carrying a sum type:

```ocaml
type msg =
  | Log   of Entry.t
  | Flush of unit Eio.Promise.u
```

`Logger.log` enqueues `Log entry`; `Logger.flush` enqueues `Flush resolver`.
The worker dequeues messages in arrival order and dispatches on the variant.

## Rationale

One queue is the only design that trivially preserves strict FIFO ordering
between log entries and flush barriers without additional synchronisation.
F14 requires that a flush barrier sees *all preceding entries*, which means
the barrier must be processed *after* every entry enqueued before it — exactly
what a single FIFO queue guarantees by construction.

## Alternatives Rejected

- **Two separate streams with `Eio.Fiber.first` (race select):**
  The worker would select whichever stream has a message ready. A `Flush`
  message enqueued after five `Log` entries could be dequeued first if the log
  stream is momentarily drained when the select runs. This violates F14. The
  race is non-deterministic and would cause intermittent test failures.
  Rejected.

- **Two separate streams with a sequencing mutex or counter:**
  Would preserve order but requires a shared mutex (prohibited by NF5, which
  mandates `Atomic` with no lock) or a non-trivial sequence-number protocol.
  Either approach is substantially more complex than the sum-type queue with
  no correctness benefit over the single-queue design.

## Consequences

**Easier:**
- FIFO ordering between entries and flush barriers is guaranteed by the
  `Eio.Stream.t` implementation without any additional synchronisation.
- The worker loop is a simple `match msg with Log _ -> ... | Flush _ -> ...`
  — exhaustive, compiler-checked, one function.
- The queue bound applies uniformly to all messages, so queue-depth
  configuration and drop counting remain simple.

**Harder:**
- `Logger.flush` enqueues a `Flush` message using blocking `Eio.Stream.add`
  (not the non-blocking try-enqueue used for `Log`). If the queue is full,
  `flush` suspends the caller until space is available. This is intentional
  — flush is a deliberate synchronisation point and suspension is acceptable —
  but it is a behavioural asymmetry between `log` and `flush` that callers
  must understand.
- The single queue means a flood of `Log` messages can delay a `Flush` barrier
  if new entries arrive faster than the worker drains them. This is expected
  behaviour for a drop-model logger; `diagnostics.drop_count` is the signal
  to act on.
