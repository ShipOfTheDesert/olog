# ADR 0007: Continue draining after `sink.emit` failure during drain-on-cancel

**Status:** Accepted (amended by RFC 0013, 2026-06-13 — continue-on-failure via
result match; `Eio.Cancel.Cancelled` always re-raised)
**Date:** 2026-02-20
**RFC:** docs/rfcs/0011-graceful-shutdown-and-drain.md

## Context

RFC 0011 introduces a best-effort drain-on-cancel path: when the enclosing
switch is cancelled without a prior `Logger.shutdown` call, the worker catches
`Eio.Cancel.Cancelled`, then drains remaining queue entries via
`Eio.Stream.take_nonblocking` under `Eio.Cancel.protect`, emitting each entry
to the configured sinks.

During this drain, `sink.emit` may raise. The sink's underlying resources
(file handles, network connections) may have already been released by the
switch's cancellation. The question is: should the worker continue draining
subsequent entries after a `sink.emit` failure, or should it abort the drain
entirely?

RFC 0003 F13 established the error-isolation contract for normal operation:
"If `sink.emit` raises, the worker catches the exception and continues with
the next sink and entry — the worker never terminates due to a sink error."
The drain-on-cancel path faces the same design choice in a more hostile
environment (resources potentially released, cancellation context active).

## Decision

The worker continues draining all remaining queue entries after a `sink.emit`
failure during drain-on-cancel. Each `sink.emit` call is wrapped in the same
`try … with` guard used during normal operation. Exceptions are caught and
ignored (consistent with the existing `write_fallback_error` pattern from
ADR 0006). The drain loop proceeds to the next entry regardless of failure.

```
(* Pseudocode — illustrative, not normative *)
let rec drain () =
  match Eio.Stream.take_nonblocking queue with
  | Some (Log entry) ->
      List.iter (fun sink -> try sink.emit entry with _ -> ()) sinks;
      drain ()
  | Some (Flush resolver | Shutdown resolver) ->
      Eio.Promise.resolve resolver ();
      drain ()
  | None -> ()
```

## Rationale

- **Consistency with RFC 0003 F13.** The error-isolation contract was
  established for normal operation and should extend to the drain path.
  Changing behavior during drain introduces a special case that callers
  cannot predict or test easily.
- **Maximise delivery.** In a multi-sink configuration, one sink may have
  lost its resources while another (e.g., stdout, which is always available)
  remains functional. Aborting the drain on the first failure would prevent
  the healthy sink from receiving any subsequent entries.
- **Entry independence.** Log entries are independent events. A failure to
  emit entry N says nothing about whether entry N+1 can be emitted. The
  failed sink may recover (e.g., a transient I/O error) or a different sink
  may handle the next entry.
- **Drain-on-cancel is best-effort by definition.** The RFC documents this
  path as "not guaranteed to succeed if sink resources have already been
  released." Continuing through failures is consistent with best-effort
  semantics — deliver as many entries as possible, accept that some may
  be lost.
- **Bounded cost.** The drain loop processes at most `queue_depth` entries
  (the bounded queue capacity). Even if every `sink.emit` call fails, the
  loop terminates in O(queue_depth * num_sinks) exception catches — not
  unbounded.

## Alternatives Rejected

- **Abort drain on first `sink.emit` failure.** Limits blast radius if a
  sink is in a fundamentally broken state (e.g., segfaulting, corrupting
  memory). Rejected because: (a) such failures are not recoverable by
  aborting — they affect the entire process; (b) OCaml exceptions from I/O
  failures are safe to catch; (c) aborting penalises healthy sinks in a
  multi-sink configuration.
- **Abort drain after N consecutive failures from the same sink.** A
  threshold-based approach: if sink S fails N times in a row, skip it for
  remaining entries. This is a reasonable refinement but adds complexity
  (per-sink failure counters, configurable threshold) for a path that is
  already best-effort. Deferred to future work.
- **Remove the failing sink from the drain loop.** After one failure, stop
  calling `sink.emit` on that specific sink for remaining entries. Simpler
  than the threshold approach but still introduces per-sink state tracking.
  Deferred to future work.

## Consequences

**Easier:**
- The drain-on-cancel path uses identical error handling to the normal
  operation path. No special cases to reason about or test.
- Multi-sink configurations benefit: a healthy sink continues to receive
  entries even when a sibling sink fails.

**Harder:**
- If a sink is in a broken state that causes expensive failure (e.g., a
  network sink with a long timeout before each connection failure), the
  drain loop may be slow. This is bounded by `queue_depth * num_sinks *
  sink_failure_latency`. For the common case (stdout sink, fast I/O
  failure), the cost is negligible.
- No visibility into per-sink failure counts during drain. Operators cannot
  distinguish "all entries delivered to all sinks" from "entries delivered
  to sink A but not sink B." The existing `write_fallback_error` mechanism
  (ADR 0006) writes a line to process stderr for each failure, which
  provides some visibility.

**Monitoring:**
- If operators report that drain-on-cancel is unacceptably slow due to a
  failing sink with high per-failure latency, revisit this decision and
  consider the per-sink failure threshold or removal approach described in
  Alternatives Rejected.

**Future work:**
- Per-sink failure threshold: after N consecutive failures, skip the sink
  for remaining drain entries. Reduces worst-case drain latency from
  `queue_depth * sink_failure_latency` to `N * sink_failure_latency` per
  failing sink.
- Drain metrics: expose the number of entries drained and the number of
  sink failures during drain in `Logger.diagnostics`. Enables operators to
  answer "did we lose entries during shutdown?"

## Amendment (RFC 0013, 2026-06-13)

RFC 0013 redesigns the sink contract: `emit`/`flush`/`close` now return
`(unit, string) result` instead of raising on expected failures. The
continue-on-failure decision recorded here stands — the worker still drains and
dispatches every remaining entry after a sink failure, on both the normal and
the drain-on-cancel paths — but the mechanism and two details change:

- **Continue-on-failure is now driven by a result match, not a blanket
  `try … with _ -> ()`.** On `Ok ()` the worker proceeds; on `Error msg` it
  writes a fallback line to process stderr (the ADR 0006 semantics, relocated
  from `Output.protect` into the worker) and proceeds to the next entry. A sink
  that *raises* rather than returning `Error` is a contract violation; the
  worker still tolerates it and continues, but through one narrow handler rather
  than a catch-all.
- **`Eio.Cancel.Cancelled` is always re-raised, never swallowed.** The old
  `with _ -> ()` guard caught cancellation too, which broke switch-cancellation
  liveness (ANALYSIS finding F3, RFC 0013 F1/F3). The replacement handler matches
  `Eio.Cancel.Cancelled _ as c -> raise c` and reports every other exception, so
  cancellation propagates and lets the worker shut down while all other failures
  are isolated.

The illustrative pseudocode under **Decision** is superseded: the `try … with _`
guard is gone, and `Shutdown` no longer carries a resolver (every shutdown
caller awaits the worker's `stopped` promise). Because the same result-matching
dispatch runs on both the normal and the drain-on-cancel paths, the
consistency-with-normal-operation argument under **Rationale** is preserved. See
RFC 0013 §Design (Sink dispatch, F3).
