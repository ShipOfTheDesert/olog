# RFC 0013: Logger Lifecycle and Accounting Correctness

**Status:** Accepted
**Date:** 2026-06-12
**PRD:** [docs/prds/0012-logger-lifecycle-and-accounting-correctness.md](../prds/0012-logger-lifecycle-and-accounting-correctness.md)
**Epic/planning reference:** None — standalone; tracked under ROADMAP Tier 1.
**ADRs touched:** amends ADR 0003 (clock closure), ADR 0007 (continue-on-failure);
preserves ADR 0004 (single queue), ADR 0006 (eprintf fallback, relocated).

## Problem

Six contracts documented in `lib/logger.mli` are not true in the
implementation (ANALYSIS.md findings 1–3 and the smaller findings):
`flush`/`shutdown` hang forever after switch cancellation kills the worker;
concurrent `shutdown` calls can deadlock despite documented idempotence; sink
error handling swallows `Eio.Cancel.Cancelled`; `queue_depth` is unvalidated;
entries can be lost without incrementing `drop_count`; and a failing clock
silently stamps entries with the 1970 epoch. The root cause of the lifecycle
bugs is that the logger's state is a `bool Atomic.t` plus an implicit "worker
alive iff not closed" invariant that two code paths can break independently.

## Scope

**In scope:**
- Lifecycle state machine; shutdown/flush liveness
- Sink contract redesign (errors as values)
- Config validation via smart constructor
- Entry-accounting conservation
- Timestamp fallback policy
- Tests for each of the above

**Out of scope:**
- Formatter changes (PRD 0014 / RFC 0015)
- Worker batching
- `drop_count` split by cause
- New public metrics counters

## Requirements

### Functional

| # | Requirement | PRD |
|---|---|---|
| F1 | `flush` and `shutdown` return promptly when the worker has terminated for any reason, including switch cancellation | FR1 |
| F2 | `shutdown` is safe and idempotent under concurrent invocation from any number of fibers or domains; every caller returns once shutdown completes | FR2 |
| F3 | Sinks report expected failures as `result` values; the worker never catches `Eio.Cancel.Cancelled`; a contract-violating (raising) sink does not stop the worker | FR3 |
| F4 | `Config.make` rejects `queue_depth < 1`; `Config.t` cannot be constructed unvalidated | FR4 |
| F5 | Every entry accepted by `log`/`log_exn` is either dispatched to the sinks or counted in `drop_count`, under concurrent load and under cancellation | FR5 |
| F6 | Timestamp conversion failure follows a per-logger `timestamp_fallback` mode: `Fail` (probe clock at create, reject broken clocks) or `Mark_invalid` (stamp epoch + reserved marker field; the default) | FR6 |

### Non-Functional

- OCaml: >= 5.2.0
- Eio: >= 1.0; no new runtime dependencies (PRD NFR3)
- `log`/`log_exn` never suspend waiting for queue space or the worker
  (PRD NFR1); see Risks R1 for the mutex caveat
- All breaking changes land before the first tagged release (PRD NFR4)

## Module breakdown

No new top-level modules (Article V respected). Modified files:

| File | Change |
|---|---|
| `lib/logger.mli` / `lib/logger.ml` | state machine, `Config.make`, sink contract, timestamp policy, accounting |
| `lib/output.mli` / `lib/output.ml` | `write` returns `result`; `protect` deleted; exception→value conversion at the flow boundary |
| `test/test_logger.ml`, `test/test_output.ml` | new tests (see Test plan) |
| `examples/*.ml` | mechanical updates to the new `Config.make`/sink API |

## Data model

Internal to `logger.ml`:

```ocaml
type state = Running | Stopping | Stopped
(* held in state : state Atomic.t; written ONLY via compare_and_set under
   the producer mutex, except the worker's terminal set to Stopped *)

type msg =
  | Log of Entry.t
  | Flush of unit Eio.Promise.u
  | Shutdown
(* Shutdown carries no resolver: all shutdown callers await [stopped] *)

type t = {
  name : string;
  config : Config.t;
  queue : msg Eio.Stream.t;
  mutex : Eio.Mutex.t;            (* guards: state transition + queue add *)
  state : state Atomic.t;
  stopped : unit Eio.Promise.t;   (* resolved by worker's finally, all exit paths *)
  stopped_r : unit Eio.Promise.u;
  drop_count : int Atomic.t;
  now : unit -> Ptime.t option;   (* None = unrepresentable; policy applied by caller *)
}
```

The invariant the mutex enforces: a queue `add` and the state check that
authorizes it are atomic with respect to state transitions. Takes remain
lock-free. The worker never holds the mutex while performing sink I/O.

## Public Interface

```ocaml
(* logger.mli — breaking changes marked NEW/CHANGED *)

type sink = {
  name : string;                            (* NEW: identifies sink in fallback error reports *)
  emit : Entry.t -> (unit, string) result;  (* CHANGED: was Entry.t -> unit *)
  flush : unit -> (unit, string) result;    (* CHANGED *)
  close : unit -> (unit, string) result;    (* CHANGED *)
}

type timestamp_fallback =                   (* NEW *)
  | Fail          (* probe the clock at [create]; reject an already-broken clock *)
  | Mark_invalid  (* stamp Ptime.epoch and append ("olog.invalid_timestamp", Bool true) *)

module Config : sig
  type t = private {
    min_level : Level.t;
    queue_depth : int;
    sinks : sink list;
    timestamp_fallback : timestamp_fallback;
  }
  (* CHANGED: private; Config.default REMOVED *)

  val make :
    min_level:Level.t ->
    queue_depth:int ->
    sinks:sink list ->
    ?timestamp_fallback:timestamp_fallback ->  (* default Mark_invalid, per PRD D2 *)
    unit ->
    (t, string) result
  (* Error if queue_depth < 1 *)
end

val create :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> Config.t -> string ->
  (t, string) result
(* CHANGED: result. Error only when timestamp_fallback = Fail and the
   creation-time clock probe yields an unrepresentable timestamp. *)

(* log, log_exn, is_enabled, flush, shutdown, diagnostics: signatures unchanged *)
```

```ocaml
(* output.mli — breaking changes *)
type t = {
  name : string;
  write : Entry.t list -> (unit, string) result;  (* CHANGED: was -> unit *)
  close : unit -> (unit, string) result;          (* CHANGED *)
}
(* Output.make converts flow exceptions to Error at this boundary,
   re-raising Eio.Cancel.Cancelled. Output.protect is deleted. *)
```

The `"olog."` field-name prefix becomes reserved (documented alongside the
existing `"exn."` reservation from RFC 0008).

## Design

**Lifecycle (F1, F2).** `shutdown`: `compare_and_set state Running Stopping`
under the mutex; the winning caller then enqueues `Shutdown` *outside* the
mutex (the `add` may block on a full queue, and holding the lock across that
block could deadlock the cancellation drain, which also needs the mutex — see
Accounting); *every* caller — winner, losers, and post-mortem callers — then
awaits `stopped`. The worker's
`Fun.protect ~finally` sets `state` to `Stopped` and resolves `stopped` on
every exit path (normal `Shutdown` processing, cancellation, unexpected
exception), so no caller can await a promise that never resolves. `flush`: if
state ≠ `Running`, return immediately; otherwise enqueue `Flush resolver` and
await `Fiber.first (await flush_promise) (await stopped)` — the `stopped` arm
guarantees F1 even if the worker dies between the check and the take.

**Dead-worker enqueue safety.** An enqueue cannot block forever on a dead
worker: the worker's exit paths drain the queue before resolving `stopped`,
and after `Stopped` is published no producer passes the state check, so the
queue cannot refill to capacity.

**Accounting (F5).** Producers do `Mutex.use_rw`: check `state = Running` and
`length < queue_depth`; add or `drop_count++`. `shutdown`'s CAS runs under the
same mutex (only the CAS — the `Shutdown` enqueue itself is deliberately
outside it, per Lifecycle), so once the winner publishes `Stopping` every
producer that next takes the mutex observes a non-`Running` state and drops:
no `Log` message can ever be enqueued after the `Shutdown` message, regardless
of where `Shutdown` is added. The worker's post-`Shutdown` drain (kept as a
defensive loop) counts any unexpected straggler as a drop rather than
discarding it silently. On cancellation, the worker (under
`Eio.Cancel.protect`): locks, sets `Stopped`, unlocks, then drains and
dispatches remaining entries — emitted, not lost. Conservation is verifiable
entirely from outside: test-side submission counters + a counting sink +
`diagnostics.drop_count`; no new public counters (deferred to Tier 2 metrics).

**Sink dispatch (F3).** The worker matches `sink.emit entry` results:
`Ok () → ()`, `Error msg → eprintf fallback line` (ADR 0006 semantics,
relocated from `Output.protect` to the worker). There is no blanket `try`.
One narrow handler defends against contract-violating sinks:
`with Eio.Cancel.Cancelled _ as c -> raise c | exn -> fallback exn` — named
intent, cancellation always propagates, ADR 0007's continue-on-failure
preserved. An entry counts as **emitted** once dispatched to the sinks;
per-sink failures are reported, not re-queued (defined in the `.mli`).

**Timestamps (F6).** The `now` closure returns `Ptime.t option`.
`Mark_invalid` (default): on `None`, stamp `Ptime.epoch` and append
`("olog.invalid_timestamp", Value.Bool true)` — entry kept, marker
machine-readable, no `Entry.t` type change needed. `Fail`: `create` probes
the clock once and returns `Error` if unrepresentable; residual per-call
failures (clock broke *after* creation) fall back to the `Mark_invalid`
behavior, because `log` must never raise (documented).

## Test plan

Red-phase first (Article III); each test names the behavior that would
regress without it. Grouped before the implementation step they precede.

**Before step 1 (config):**
- `test_config_make_rejects_nonpositive_queue_depth` — `make ~queue_depth:0`
  and `-1` return `Error`; `1` returns `Ok` (F4)

**Before step 2 (sink contract):**
- `test_output_write_returns_error_on_io_failure` — a failing flow yields
  `Error _`, no exception escapes (F3 boundary)
- `test_sink_emit_error_does_not_stop_worker` — sink errors on entry *k*;
  entries *k+1…n* still delivered (F3, ADR 0007)
- `test_contract_violating_sink_does_not_stop_worker` — a sink that *raises*
  doesn't kill the worker; later entries delivered (F3)

**Before step 3 (lifecycle):**
- `test_flush_returns_after_switch_cancellation` — cancel the logger's
  switch, call `flush`, it returns (F1; hangs today)
- `test_shutdown_returns_after_switch_cancellation` — same for `shutdown` (F1)
- `test_concurrent_shutdown_all_callers_return` — N fibers + a second domain
  call `shutdown` concurrently; all return; `close` called once per sink (F2)
- `test_conservation_under_concurrent_load` — M producer fibers × K entries,
  queue depth ≪ M·K, `shutdown` mid-stream:
  `submitted = emitted + drop_count` (F5)
- `test_conservation_after_cancellation` — same invariant when the switch is
  cancelled instead of `shutdown` (F5 + F1)

**Before step 4 (timestamps):**
- `test_create_fail_mode_rejects_broken_clock` — mock clock returning NaN,
  `Fail` mode: `create` returns `Error` (F6)
- `test_log_marks_invalid_timestamp_by_default` — `Mark_invalid` + clock that
  breaks after creation: entry is delivered with epoch timestamp and
  `olog.invalid_timestamp = true` (F6)

Excluded by the test-plan rules: no tests for `Config.t` field access,
`timestamp_fallback` construction, or signature compilation — the compiler
covers those.

## Implementation sequence

1. **Config smart constructor** — `Config.make`, private `t`,
   `timestamp_fallback` type, delete `Config.default`; mechanically update
   tests/examples. Builds green with old worker behavior intact.
2. **Sink/Output result contract** — new `sink` and `Output.t` shapes, worker
   result-matching dispatch, fallback reporting moved to worker,
   `Output.protect` deleted.
3. **Lifecycle state machine** — `state`/`stopped`/`mutex` replace `closed`;
   `shutdown` CAS + await-stopped; `flush` `Fiber.first`; cancellation drain
   sets `Stopped` before draining; defensive post-`Shutdown` drain counts
   drops.
4. **Timestamp policy** — `now` returns option; policy applied in
   `log`/`log_exn`; `Fail` probe in `create`.
5. **Docs alignment** — update `.mli` doc comments to the now-true contracts;
   amend ADR 0003 (closure returns option) and ADR 0007 (continue-on-failure
   via result match; Cancelled always re-raises); quality gate (build, test,
   fmt, doc, opam-dune-lint).

## Options Considered

### Option A: Minimal patches to the boolean flag
Worker's `finally` sets `closed`; `shutdown` uses CAS; explicit `Cancelled`
re-raise in `emit_to_sinks`.

**Pros:** smallest diff; no API breaks beyond PRD-mandated FR3.
**Cons:** keeps two implicit sources of truth (flag + worker liveness) — the
bug class the analysis traced both liveness findings to; F5's conservation
cannot be met (check-then-add race remains uncounted); `flush` still races
worker death between check and enqueue.

### Option B: State-machine variant + stopped promise + producer mutex *(chosen)*
As designed above.

**Pros:** illegal states unrepresentable; every F requirement met without
residual races; `stopped` promise gives F1/F2 a single, always-resolved join
point; keeps battle-tested `Eio.Stream` for the queue (ADR 0004 intact).
**Cons:** producers serialize on one mutex (see R1); ~3 new fields in `t`.

### Option C: Hand-rolled closeable bounded queue (`lib/internal/`)
A Mutex+Condition queue whose `add` returns `Ok | Full | Closed` and whose
`close_and_drain` is atomic.

**Pros:** cleanest semantics; no separate state atomic.
**Cons:** re-implements `Eio.Stream`'s fiber-aware blocking take — the
highest-risk kind of code to hand-roll, contradicting the project's "boring
and verified" direction; strictly more code than B for the same guarantees.

### Sink errors: exceptions kept (rejected) vs. result contract (chosen)
Keeping exceptions with a careful `Cancelled` re-raise is smaller but
violates Article X.2 and PRD FR3, and leaves "what may a sink raise?"
undocumented forever. Result contract chosen; the PRD already accepted the
break.

### `create` failure: exception vs. `result` (chosen: `result`)
`Invalid_argument` matches stdlib convention for programmer errors, but a
broken clock is an environment condition, not a programming bug, and Article
X.2 mandates values for expected failures. `result` also matches
`Config.make`, giving one consistent creation-path idiom.

## Decision

We choose Option B (state-machine variant + stopped promise + producer
mutex) because it is the only option that satisfies all six functional
requirements without residual races, while keeping the battle-tested
`Eio.Stream` queue and the single-queue FIFO design from ADR 0004. Option A
leaves the implicit-invariant bug class in place; Option C buys nothing over
B at materially higher concurrency-bug risk.

## Dependencies

None new at runtime. No new test dependencies: alcotest + eio_main cover
everything here (the property-testing dependency arrives with RFC 0015's
round-trip tests, not this RFC).

## Risks

- **R1 — Producer mutex contention.** `log` can micro-suspend on the mutex
  under multi-domain contention (critical section: one state read + one
  length check + one add; no I/O under lock). NFR1's intent — never suspended
  waiting on the worker or queue space — is preserved, but this is a real
  serialization point. *Detection:* the conservation stress test doubles as a
  contention canary; if hot-path cost shows up, the documented escape hatch
  is reverting producers to lock-free adds and accepting a bounded, counted
  residual race (Option A's accounting), recorded as an explicit downgrade of
  F5.
- **R2 — `timestamp_fallback` has a behavioural default** (`Mark_invalid`),
  deviating from the no-behavioural-defaults rule. Intentional: PRD D2
  explicitly decided a default exists; the field governs a near-unreachable
  failure path. All other behavioural fields (`min_level`, `queue_depth`,
  `sinks`) are required parameters of `Config.make`, and `Config.default` is
  deleted — the rule is otherwise enforced.
- **R3 — Breadth of breakage.** `Config.default` removal + sink record change
  touch every test and example. Mitigation: step 1 and step 2 are mechanical
  and land first; quality gate (Article VIII) on every step.
- **R4 — `Fiber.first` promise leak in `flush`.** If `stopped` wins the race,
  the worker's drain still resolves the abandoned `Flush` resolver exactly
  once (drain resolves all pending resolvers); resolving a promise nobody
  awaits is harmless. The drain paths must keep that single-resolution
  discipline — covered by `test_flush_returns_after_switch_cancellation`.
- **R5 — Multi-domain test flakiness.**
  `test_concurrent_shutdown_all_callers_return` uses a second domain;
  scheduling variance could mask the race it guards. Mitigation: loop the
  scenario (e.g., 100 iterations) inside the test.

## Open Questions

None.

## Implementation Decisions

### Decision 1 — Sync `llms.txt` during the docs-alignment task
**Task:** Task 6
**Criterion:** D (convention conflict)
**Question:** Task 6's enumerated steps name only `logger.mli`, `output.mli`,
and ADRs 0003/0007. The compliance scan found `llms.txt` (the LLM-facing API
reference) still showing the deleted `Logger.Config.default`, the old
`create : ... -> Logger.t` (now `result`), and the pre-result sink/`Output.t`
shapes. The `llm-docs-api-sync` convention treats LLM docs as a public
contract. Should fixing `llms.txt` be pulled into Task 6 or deferred?
**Decision:** Fix `llms.txt` as part of Task 6.
**Rationale:** Task 6 is the documentation-alignment task and the last task
before `/prereview`; PRD NFR2 requires every repaired contract to be
documented. `llms.txt` is documentation that directly contradicts the now-true
API, and code generated from it would not compile. The drift accumulated across
Tasks 1–5 (where `llms.txt` was never updated alongside the `.mli` changes);
Task 6 is the natural and final place to close it. Every rewritten signature is
checked against the shipped `.mli` files, and `dune build @doc` passes.
`README.md` carries no API usage examples and needs no change.
