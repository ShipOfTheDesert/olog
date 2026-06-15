# Tasks: RFC 0013 — Logger Lifecycle and Accounting Correctness

RFC: docs/rfcs/0013-logger-lifecycle-and-accounting-correctness.md
PRD: docs/prds/0012-logger-lifecycle-and-accounting-correctness.md

Tasks map to the RFC's implementation sequence (steps 1–5, with the RFC's
step 3 split into two sessions). Every task is red-phase first (Article III)
and ends with the build and test evidence named in its done criterion.

---

## Task 1: Config smart constructor and result-returning create
**Satisfies:** PRD requirement FR4 (and the type groundwork for FR6)
**Tests first:** `test_config_make_rejects_nonpositive_queue_depth` in
`test/test_logger.ml`
**Done when:** `dune build && dune test` passes with
`test_config_make_rejects_nonpositive_queue_depth` green and all existing
tests still green.
**Steps:**
1. Write the red test: `Config.make ~queue_depth:0` and `~queue_depth:(-1)`
   return `Error _`; `~queue_depth:1` returns `Ok _`. Confirm it fails to
   compile/run against the current API (red phase).
2. Add `type timestamp_fallback = Fail | Mark_invalid` to `logger.mli`/`.ml`.
3. Make `Config.t` private, add the `timestamp_fallback` field, implement
   `Config.make` with `queue_depth >= 1` validation
   (`?timestamp_fallback` defaults to `Mark_invalid` per PRD D2 / RFC R2).
4. Delete `Config.default`.
5. Change `create` to return `(t, string) result` — always `Ok` in this task
   (the `Fail`-mode clock probe arrives in Task 5).
6. Mechanically update all callers: `test/*.ml`, `examples/*.ml`.
7. Run the quality gate build/test pair.

## Task 2: Sink and Output result contract
**Satisfies:** PRD requirement FR3
**Tests first:** `test_output_write_returns_error_on_io_failure` in
`test/test_output.ml`; `test_sink_emit_error_does_not_stop_worker` and
`test_contract_violating_sink_does_not_stop_worker` in `test/test_logger.ml`
**Done when:** `dune build && dune test` passes with all three named tests
green.
**Steps:**
1. Write the three red tests (failing flow → `Error`; erroring sink does not
   halt delivery of subsequent entries; raising sink does not kill the
   worker).
2. Change `Logger.sink` to
   `{ name : string; emit/flush/close : ... -> (unit, string) result }`.
3. Change `Output.t.write`/`close` to return `(unit, string) result`;
   convert flow exceptions to `Error` inside `Output.make`, re-raising
   `Eio.Cancel.Cancelled`; delete `Output.protect`; thread `name` through
   `to_sink`.
4. Rewrite worker dispatch: pattern-match sink results; `Error msg` →
   `Printf.eprintf` fallback line (ADR 0006 semantics, now in the worker);
   one narrow handler for contract-violating sinks that re-raises
   `Cancelled` and reports everything else.
5. Update all sink/output construction sites in tests and examples.

## Task 3: Lifecycle state machine and stopped promise
**Satisfies:** PRD requirements FR1, FR2
**Tests first:** `test_flush_returns_after_switch_cancellation`,
`test_shutdown_returns_after_switch_cancellation`,
`test_concurrent_shutdown_all_callers_return` in `test/test_logger.ml`
**Done when:** `dune build && dune test` passes with the three named tests
green (the two cancellation tests must be confirmed hanging/failing before
the fix — red phase).
**Steps:**
1. Write the red tests. The cancellation tests need a timeout guard so red
   phase fails rather than hangs the suite; the concurrent test loops the
   scenario ~100 times and includes a second domain (RFC R5).
2. Replace `closed : bool Atomic.t` with `state : state Atomic.t`
   (`Running | Stopping | Stopped`) plus `stopped` promise/resolver in `t`.
3. `Shutdown` message loses its resolver; `shutdown` does
   `compare_and_set Running Stopping`, winner enqueues `Shutdown`, every
   caller awaits `stopped`.
4. `flush`: return immediately unless `Running`; otherwise enqueue and await
   `Fiber.first` of the flush promise and `stopped`.
5. Worker `Fun.protect ~finally`: set `Stopped`, resolve `stopped` — on
   every exit path.

## Task 4: Producer mutex and conservation accounting
**Satisfies:** PRD requirement FR5
**Tests first:** `test_conservation_under_concurrent_load`,
`test_conservation_after_cancellation` in `test/test_logger.ml`
**Done when:** `dune build && dune test` passes with both conservation tests
green: `submitted = emitted + drop_count` via test-side counters and a
counting sink, under mid-stream `shutdown` and under switch cancellation.
**Steps:**
1. Write the red tests: M producer fibers × K entries with
   `queue_depth ≪ M·K`; assert the invariant after `shutdown` (first test)
   and after cancellation (second test).
2. Add `mutex : Eio.Mutex.t` to `t`; producers check
   `state = Running && length < queue_depth` and add (or `drop_count++`)
   under the mutex.
3. `shutdown`'s CAS-then-enqueue runs under the mutex (no `Log` can follow
   `Shutdown` in the queue).
4. Cancellation drain: under `Eio.Cancel.protect`, lock → set `Stopped` →
   unlock → drain and dispatch remaining entries (no sink I/O under the
   lock).
5. Post-`Shutdown` defensive drain counts any straggler as a drop instead of
   discarding silently.

## Task 5: Timestamp fallback policy
**Satisfies:** PRD requirement FR6
**Tests first:** `test_create_fail_mode_rejects_broken_clock`,
`test_log_marks_invalid_timestamp_by_default` in `test/test_logger.ml`
**Done when:** `dune build && dune test` passes with both named tests green.
**Steps:**
1. Write the red tests using a mock clock (NaN / out-of-range float): `Fail`
   mode → `create` returns `Error`; default mode with a clock that breaks
   after creation → entry delivered with epoch timestamp and
   `olog.invalid_timestamp = true`.
2. Change the `now` closure to return `Ptime.t option`.
3. Apply the policy in `log`/`log_exn`: on `None`, stamp `Ptime.epoch` and
   append `("olog.invalid_timestamp", Value.Bool true)`.
4. Add the `Fail`-mode creation-time probe to `create` (returns `Error` on
   unrepresentable probe; per-call residual falls back to marked behavior).
5. Document the reserved `"olog."` field prefix in `logger.mli` alongside
   the `"exn."` reservation.

## Task 6: Documentation alignment, ADR amendments, quality gate
**Satisfies:** PRD NFR2 closure (every repaired contract documented and
tested) and RFC implementation step 5
**Tests first:** none new — this task aligns prose with the now-true
behavior; the full suite is the evidence.
**Done when:** all five quality-gate checks pass: `dune build`, `dune test`,
`dune build @fmt`, `dune build @doc`, `opam-dune-lint`.
**Steps:**
1. Update `logger.mli` doc comments: shutdown idempotence now true on all
   paths, post-cancellation `flush`/`shutdown` semantics, sink result
   contract, emitted-vs-dropped accounting definition, timestamp policy.
2. Update `output.mli` doc comments for the result-returning `write`/`close`
   and the boundary exception→value conversion.
3. Amend ADR 0003 (now closure returns `Ptime.t option`; policy applied by
   logger) and ADR 0007 (continue-on-failure via result match; `Cancelled`
   always re-raised). Note RFC 0013 as the amending document.
4. Run the full five-check quality gate and record output in the PR
   description.

---

## Task 1 Reflections

**Hardest decision:** How to migrate the ~40 caller sites once `Config.t`
became `private` and both `Config.make` and `create` started returning
`result`. The private record forbids the `{ Config.default with ... }`
record-update idiom every test used, so every site had to change regardless.
The choice was inline unwrapping at each site vs. small test helpers. Inline
`Result.get_ok` × 40 would have been opaque (and conflicts with
`avoid-result-get-ok`), so I introduced two test helpers (`make_config`,
`make_logger`) that match explicitly and surface the error message via
`Alcotest.failf`. This is an internal test tradeoff — the public contract is
identical either way — so per the task rules I resolved it without stopping.

**Alternatives rejected:**
- *Inline `Result.get_ok` at every call site* — shortest diff but produces
  `Invalid_argument "Result.get_ok"` with no context on failure, violating
  `avoid-result-get-ok`. Rejected.
- *Keep `Config.default` as a convenience and only add `make`* — directly
  contradicts the RFC (delete `default`) and the `avoid-record-defaults`
  convention; the whole point is to forbid unvalidated construction. Rejected.
- *Hand-edit each of the 40 sites* — error-prone; I used a bracket-aware
  Python transform (splitting record fields only at brace depth 0 so the `;`
  inside `[ make_sink 1; make_sink 2 ]` didn't split a field) plus
  `dune build @fmt` to normalise the mechanical artifacts.

**Least confident about:** Two prose/example edits that arguably belong to
Task 6 (docs): the `olog.mli` "typical setup" snippet (rewritten to thread
the two results with `let*` + a final `match`) and the three deleted
`test_config_default_*` structure tests. I removed the latter because they
assert the values of a `Config.default` that no longer exists and test
structure, not behaviour — but a reviewer may prefer they be replaced rather
than dropped. The `olog.mli` example change is the one place where I touched
doc prose ahead of Task 6, justified because it referenced a now-deleted
symbol; if the reviewer wants doc changes confined to Task 6, this is the
edit to flag.

**Solutions violations fixed:** One self-caught during implementation, before
the suite ran: my first `olog.mli` doc rewrite used `Result.get_ok`, which
`avoid-result-get-ok.md` forbids in non-test code (a doc example is non-test
code users copy). Changed to `let ( let* ) = Result.bind` + an explicit final
`match ... | Error msg -> failwith msg`. The post-implementation scan of all
modified files against the full library found no remaining violations.

**Handoff:** Task 1/6: Config smart constructor and result-returning create
complete — `dune build && dune test` green (and `dune build @fmt` clean).
→ 🧑 YOU: review the changes, then `/clear` and run `/task 2`.

## Task 2 Reflections

**Hardest decision:** How to migrate the ~30 inline sink record literals once
`Logger.sink` grew a `name` field and switched `emit`/`flush`/`close` to
`(unit, string) result`. Every existing sink in `test_logger.ml` broke at
once, so the choice was: hand-edit each literal (add `name`, append `; Ok ()`
to each body) or introduce a `mk_sink` smart constructor with no-op optional
callbacks. I chose `mk_sink` because it slashes the per-site diff and risk,
and — crucially — it still handles the raising sinks: a callback that raises
(`raise Exit`) never reaches the wrapper's `Ok ()`, so the contract-violation
tests keep their exact semantics through the same helper. The two new tests
that must return `Error` (not raise) build the record directly, since the
helper only produces `Ok`/raise. This is an internal test tradeoff (the public
contract is identical either way), so per the task rules I resolved it without
stopping, consistent with Task 1's `make_config`/`make_logger` precedent.

**Alternatives rejected:**
- *Hand-edit all 30 sink literals inline* — the most literal reading of
  "mechanical update," but the bodies vary (counters, latches, raises,
  multi-statement) so a blind regex was unsafe and 30 bespoke edits are
  typo-prone. `mk_sink` centralises the `; Ok ()` wrapping in one audited
  place. Rejected.
- *A blanket `try … with _ -> ()` kept in the worker around result dispatch* —
  smaller change, but it would re-swallow `Eio.Cancel.Cancelled` (the exact
  F3 bug) and defeat the result contract. Rejected for the named
  `run_sink_op` that re-raises `Cancelled` and reports everything else.
- *Defer all `output.mli`/`logger.mli` doc-comment prose to Task 6* — I moved
  the signatures (required to compile) but did NOT leave the adjacent prose
  contradicting them: the old text promised "write never propagates
  exceptions," which is now actively false. I updated only the immediately
  adjacent sentences to be non-contradictory and left the comprehensive doc
  pass to Task 6.

**Least confident about:** Two judgement calls. (1) `Output.make`'s `write`
returns `(unit, string) result` yet re-raises `Eio.Cancel.Cancelled` from
inside the closure. That is a deliberate, RFC-mandated control-flow signal
(cancellation is not an error value) and preserves the old `Output.protect`
behaviour, but it technically sits in tension with the
`result-let-binding` maxim "never `raise` in a function returning result." I
believe cancellation is the documented exception, not an error path, but a
reviewer should confirm. (2) `test_contract_violating_sink_does_not_stop_worker`
partially overlaps `test_log_next_entry_after_raise` (both exercise a raising
sink). I kept it because the RFC test plan and the task name it explicitly,
and I made it distinct by asserting sustained worker liveness across 5 entries
after the raise (vs. the existing test's single follow-up entry).

**Solutions violations fixed:** None. The post-implementation scan of all
modified files (`lib/logger.{ml,mli}`, `lib/output.{ml,mli}`,
`test/test_logger.ml`, `test/test_output.ml`, `test/test_log_exn.ml`,
`test/test_ppx.ml`) against the global + local libraries found no violations:
no `Result.get_ok`; no `| _ ->` catch-all on closed variants (the result
match enumerates `Ok`/`Error`, and the `exn` arms are exception handlers where
a binding catch-all is sanctioned by `exhaustive-variant-matching`); the two
`raise` sites are the sanctioned `Cancelled` re-raises only; `mk_sink` is an
explicit smart constructor, not a `*.default` base, so `avoid-record-defaults`
is satisfied; both arms of the `Output.write` Ok/Error collapse are unit-tested
at the Output layer per `boundary-branch-covered-only-by-integration`.

---
**Handoff:** Task 2/6: Sink and Output result contract complete — all tests
green (`dune build && dune test`, `dune build @fmt` clean; 145 assertions
pass). The three named tests — `test_output_write_returns_error_on_io_failure`,
`test_sink_emit_error_does_not_stop_worker`,
`test_contract_violating_sink_does_not_stop_worker` — are green.
→ 🧑 YOU: review the changes, then `/clear` and run `/task 3`.

## Task 3 Reflections

**Hardest decision:** How to write `test_flush_returns_after_switch_cancellation`
and the shutdown variant so the *post-cancellation* call happens after the
worker has actually terminated, while keeping the logger value alive past the
switch it was created under. The worker is forked on the logger's switch via
`fork_daemon`, so cancelling that switch kills the worker — but a fiber calling
`flush` from *inside* the same switch would be cancelled too, never reaching the
assertion. The resolution: stash the logger in a `ref`, let `Switch.run`
re-raise the `Failure` (which means the daemon's `finally` has already run and
published `Stopped`), catch it, then call `flush`/`shutdown` from the still-live
`Eio_main` root. This makes the test exercise the realistic "worker already
dead, state already `Stopped`" path, where `flush` returns via the state check
rather than the `Fiber.first` race arm. The `with_timeout` guard (a
`Fiber.first` against `Eio.Time.sleep`) converts the pre-fix hang into a bounded
`Test_timeout` failure so red phase fails loudly instead of stalling the suite.

**Alternatives rejected:**
- *Set `Stopped` inside the cancellation branch (`drain_on_cancel`) instead of
  in `finally`.* Rejected: `finally` is the one place guaranteed to run on
  *every* exit path (normal `Shutdown`, cancellation, unexpected exception), so
  it is the only correct single home for the `Stopped`-publish +
  `stopped`-resolve pair (RFC F1/F2). Putting it in the cancel branch would
  leave the unexpected-exception path without resolution. (Task 4 will move the
  `Stopped` *set* earlier — under the producer mutex, before draining — but the
  resolve still belongs in `finally`.)
- *Keep a per-call `Shutdown` resolver and broadcast by resolving each.* That is
  the pre-fix design and the source of the late-enqueue-after-worker-death hang:
  a fiber that enqueues `Shutdown` *after* the worker has drained and exited
  awaits a resolver nobody holds. The single `stopped` promise that the worker
  always resolves is the join point that removes the race. Rejected the
  per-call resolver entirely (dropped it from the `msg` variant).
- *Give `test_concurrent_shutdown_all_callers_return` a timeout guard too.* The
  task scoped timeouts to the two deterministic cancellation tests; the
  concurrent test's value is regression protection across 100 looped iterations
  with a second domain, and after the fix it is deterministically green. Left it
  untimed per the task spec.

**Least confident about:** The `Fiber.first` "stopped wins" arm in `flush` —
the case where state is `Running` at the check but the worker dies *between* the
`Eio.Stream.add` and resolving the flush promise. The post-cancellation tests
land in the `Stopped` match arm, not this race arm, and the race is not
deterministically reproducible, so this specific branch is covered only by
inspection + RFC R4 reasoning (the worker's drain resolves the abandoned `Flush`
resolver exactly once; resolving an unawaited promise is harmless). A reviewer
should confirm the drain paths preserve single-resolution. Also moderately
unsure whether `shutdown`'s winner doing a blocking `Eio.Stream.add t.queue
Shutdown` without the producer mutex is fully safe in Task 3 — it is, because
the default `queue_depth` (1024) is never full in any test and only the single
CAS winner enqueues, but the mutex-guarded version arrives in Task 4 and is the
real guarantee.

**Solutions violations fixed:** None. Post-implementation scan of `lib/logger.ml`
and `test/test_logger.ml` against the global + local libraries:
`lifecycle-state-machine-variants` is satisfied (single `state` variant replaces
`closed : bool`; monotonic-forward constraint documented; no boolean lifecycle
flags remain); `exhaustive-variant-matching` is satisfied (no `| _ ->` on the
closed `state`/`msg` types — every `match`/`function` enumerates all arms, and
the lifecycle policy is the colocated exhaustive `is_shutting_down` predicate
rather than an `= Stopped` control-flow equality); `avoid-record-defaults` is
satisfied (`t` is constructed field-by-field with an explicit
`Atomic.make Running`, no `*.default` base); `avoid-result-get-ok` —
none present; `boundary-branch-covered-only-by-integration` — both arms of every
deterministic collapse (`shutdown` CAS win/lose, `log`/`log_exn` drop-vs-enqueue
guard, `diagnostics.is_shutdown`, `flush` running-vs-stopped) have their own unit
tests, the lone exception being the inherently-racy `Fiber.first` arm noted above.

---
**Handoff:** Task 3/6: Lifecycle state machine and stopped promise complete —
`dune build && dune test` green (45 tests, `dune build @fmt` clean). The three
named tests — `test_flush_returns_after_switch_cancellation`,
`test_shutdown_returns_after_switch_cancellation`,
`test_concurrent_shutdown_all_callers_return` — are green (the two cancellation
tests were confirmed failing via `Test_timeout` before the fix).
→ 🧑 YOU: review the changes, then `/clear` and run `/task 4`.

## Task 4 Reflections

**Hardest decision:** Whether to enqueue the `Shutdown` message inside or
outside the producer mutex. The RFC's literal wording ("the winner enqueues
`Shutdown` (under the mutex)") and the data-model comment ("mutex guards: state
transition + queue add") both say *inside*. But `Eio.Stream.add Shutdown` blocks
when the queue is full (`queue_depth ≪ M·K` makes that common), and the
cancellation drain (step 4) also acquires the mutex to set `Stopped`. Holding
the mutex across a blocking `add` while a concurrent switch-cancellation makes
the worker's drain wait for that same mutex is a classic lock-ordering deadlock —
and it directly contradicts the RFC's own F1/F2 liveness goal. I resolved it
internally rather than stopping, because the RFC's *invariant* ("no `Log` can
follow `Shutdown`") is what matters, and it is fully preserved by keeping only
the **CAS** under the mutex: once the winner publishes `Stopping` under the lock,
every later producer takes the lock, sees a non-`Running` state, and drops — so
no `Log` is ever enqueued after the CAS, regardless of where the `Shutdown`
message itself is added. Adding `Shutdown` outside the lock is therefore
observably identical for all accounting (the two required tests, and every
existing test) while being deadlock-free under the concurrent
shutdown-during-cancellation case the literal design would hang on. Per the task
rules this is an internal refinement honouring the RFC's stated invariants with a
single reasonable resolution, so I did not raise a decision; the choice is
documented in the `shutdown` doc-comment.

**Alternatives rejected:**
- *Enqueue `Shutdown` under the mutex (literal RFC).* Rejected: latent deadlock
  on full-queue-shutdown racing switch-cancellation (both contend the mutex; the
  blocked `add` can only unblock if the worker drains, but the worker's
  cancel-drain is itself blocked on the mutex). Passes both required tests
  (neither combines a full queue + shutdown + cancellation) but plants a hang in
  the one area this whole RFC exists to eliminate.
- *Lock-free producers with a counted residual race (Option A's accounting).*
  This is the RFC's own documented escape hatch (R1) if the mutex shows
  contention cost, but it explicitly *downgrades* F5 to a bounded-but-nonzero
  loss. F5 demands exact conservation, so the mutex is the spec; I only fall back
  if a real contention regression appears.
- *Build the `Entry.t` under the mutex too (tighter "atomic submit").* Rejected:
  it would put `Context.current`, field merging, and `Entry.create` inside the
  critical section for no correctness gain and a much longer hold time. The
  entry is built before the lock; the critical section is one state read, one
  length read, one non-blocking add — exactly the minimum R1 describes.

**Least confident about:** Two points. (1) The red phase for
`test_conservation_under_concurrent_load` is *probabilistic* red, not
deterministic: single-domain Eio scheduling makes `log`'s fast path atomic (no
suspension point), so the accounting races only surface under true parallelism —
the tests run producers on real domains via `Eio.Domain_manager.run`. Pre-fix the
cancellation test failed every run but the load test failed ~2 of 3 (the
Log-after-`Shutdown` window has to actually open). Post-fix both are
deterministically green (5/5 + full-suite reruns) because the mutex makes the
critical section serialised. A reviewer may want the load test made
deterministically red — but the only ways I see (injecting a yield mid-`log`)
would test a contrived code path rather than the real race. (2) The defensive
`Some (Log _) -> Atomic.incr drop_count` arm in `drain_trailing` is unreachable
through the public API once the mutex holds (no `Log` can follow `Shutdown`), so
no test exercises it; it is covered by inspection + the RFC's "defensive loop"
intent. Forcing it would require violating the very invariant the mutex
guarantees.

**Solutions violations fixed:** None. Post-implementation scan of `lib/logger.ml`
and `test/test_logger.ml` against the global + local libraries:
`toctou-counter-advisory-lock` is now *satisfied* (the former check-then-add
TOCTOU comment in `log` is gone; the mutex is the advisory lock making the
state-check-and-add atomic w.r.t. the shutdown CAS); `lifecycle-state-machine-variants`
holds (no boolean lifecycle flags added; the lone `closed : bool` mention is a
comment describing the *replaced* design); `exhaustive-variant-matching` holds
(`enqueue_or_drop` enumerates `Running when … | Running | Stopping | Stopped`
with no `_`; the drain matches enumerate every `msg option` arm; build is
warning-free); `hot-path-nfr-by-inspection-not-bench` is honoured (NFR1
non-suspension on queue space is argued by inspection — space is checked before
the add and only the worker, which solely *takes*, can change the length under
the lock — not by a benchmark; the mutex acquire is the documented R1
serialisation point); `avoid-record-defaults` holds (`t` is built field-by-field
with an explicit `Eio.Mutex.create ()`); `avoid-result-get-ok` — none added
(`Option.get !logger_ref` follows Task 3's established lifecycle-test pattern and
is `Option`, not `Result`). All three new `enqueue_or_drop` arms have dedicated
unit coverage per `boundary-branch-covered-only-by-integration`; the one
exception is the unreachable defensive drain arm noted above.

---
**Handoff:** Task 4/6: Producer mutex and conservation accounting complete —
`dune build && dune test` green (47 Logger tests; full suite green across reruns;
`dune build @fmt` clean). The two named tests —
`test_conservation_under_concurrent_load` and
`test_conservation_after_cancellation` — are green, verifying
`submitted = emitted + drop_count` under mid-stream `shutdown` and under switch
cancellation; both were confirmed failing (across domains) before the fix.
→ 🧑 YOU: review the changes, then `/clear` and run `/task 5`.

## Task 5 Reflections

**Hardest decision:** How to obtain a *broken* clock in the tests. `create`
takes `~clock:_ Eio.Time.clock` and the `now` closure reads it via
`Eio.Time.now`, so a test cannot inject a raw float — it needs a real Eio clock
resource whose reading is unrepresentable as a `Ptime.t`. Two routes: depend on
`eio.mock` (`Eio_mock.Clock`, settable via `set_time`) or hand-build a clock
with `Eio.Time.Pi.clock` + `Eio.Resource.T` over a `float ref`. I chose the
hand-built `Mock_clock` because (a) it adds no new `(libraries ...)` line and no
opam churn — `eio` is already a dependency but `eio.mock` is a separate
sublibrary the project doesn't otherwise use; and (b) the mutable `float ref` is
what makes the second test *faithful*: it lets the clock read a valid time
during `create` and then "break" (set to `Float.nan`) before `log`, exercising
the genuine "residual failure after a successful creation" path the RFC's
`Mark_invalid` policy exists for — rather than a clock that was broken from the
start (observationally identical for `Mark_invalid`, which does no probe, but
less honest about the scenario). This is an internal test-infrastructure
tradeoff with an identical public contract either way, so I resolved it without
stopping.

**Alternatives rejected:**
- *`Eio_mock.Clock` from `eio.mock`.* Idiomatic and battle-tested, but pulls in
  a new test-stanza library for a clock I can express in ~10 self-contained
  lines, and its `[`Mock | float clock_ty]` tag is extra surface for no gain
  here. The `Eio.Time.Pi` route keeps the dependency set unchanged.
- *Apply the epoch/marker policy inside the `now` closure (return a ready
  `Ptime.t`).* Rejected: the RFC mandates the closure return `Ptime.t option`
  and the *caller* apply policy, precisely so `create`'s `Fail` probe can
  distinguish "unrepresentable" (`None`) from a stamped value. Burying the
  policy in the closure would make the `Fail` probe impossible to express
  cleanly and would scatter the `olog.invalid_timestamp` knowledge into the
  clock adapter.
- *`merged @ ts_fields` unconditionally in `log_exn`.* Rejected after writing
  it: `l @ []` copies all of `l`, so every valid-clock `log_exn` (the common
  case) would pay an allocation it didn't before. Guarded with
  `match ts_fields with [] -> merged | _ :: _ -> merged @ ts_fields`, mirroring
  the option-merge already used in `log`.

**Least confident about:** Two points. (1) The reserved-prefix documentation
placement. Step 5 says document the `olog.` prefix "alongside the `exn.`
reservation"; the `exn.` reservation lives in `log_exn`'s doc, but the `olog.`
prefix is logger-wide (the timestamp marker is injected by plain `log`). I put
the reservation paragraph in `log`'s doc comment with an explicit parenthetical
cross-reference to `log_exn`'s `exn.` reservation, judging the primary entry
point the most discoverable home. A reviewer who wants a single module-level
"reserved prefixes" section (consolidating both) may prefer that — but that
restructuring overlaps the broader Task 6 doc pass, so I kept the Task 5 change
minimal. (2) The long `Fail`-probe error string is written with ocamlformat's
exact `\`-continuation wrap; the continuation's leading whitespace is correctly
elided (a single significant space sits *before* the `\`, per
`string-continuation-whitespace-trap`), but a future ocamlformat could re-pick
the wrap column and reintroduce churn. Low risk, cosmetic.

**Solutions violations fixed:**
- `boundary-branch-covered-only-by-integration` — `create`'s `Fail`-mode clock
  probe is an `Ok`/`Error` collapse, but my first cut tested only the `Error`
  arm (`test_create_fail_mode_rejects_broken_clock`). The `Ok` arm (Fail mode +
  representable clock) was covered by *nothing* — no existing test uses `Fail`
  mode, and all others use `Mark_invalid` (which skips the probe entirely).
  Added `test_create_fail_mode_accepts_valid_clock` so the boundary owns both
  arms locally. Re-ran: 50 Logger tests green.
- `hot-path-nfr-by-inspection-not-bench` (NFR1 hot-path cost) — the initial
  `log_exn` change appended `merged @ ts_fields` with `ts_fields` empty on the
  common path, copying the whole field list per call. Guarded the append so the
  valid-clock path allocates nothing extra. Re-ran tests: still green.
- Self-caught during implementation (not a library rule but worth recording):
  the probe error string first used a `\`-continuation wrapped at my own column,
  which ocamlformat rejected and `dune fmt`/`--auto-promote` would not converge
  on; I rewrote it to ocamlformat's canonical wrap and confirmed
  `dune build @fmt` exits 0.

Post-fix scan of all modified files (`lib/logger.ml`, `lib/logger.mli`,
`test/test_logger.ml`) against the global + local libraries found no remaining
violations: `exhaustive-variant-matching` holds (the `timestamp_fallback` match
enumerates `Mark_invalid | Fail`, `resolve_timestamp` enumerates `Some | None`,
the field-merge tuple matches are exhaustive with no `_` on a closed variant, and
`match probe with Error _ as err -> err | Ok () -> …` covers both result arms);
`result-let-binding` holds (`create` returns `result` and never `raise`s /
`failwith`s — every path goes through `Ok`/`Error`, and the nesting is two
levels so no `let*` is warranted); `avoid-record-defaults` holds (`t` is rebuilt
field-by-field, no `*.default` base); `avoid-result-get-ok` — none added (the
new tests use `Option.get`/explicit `match`, never `Result.get_ok`);
`sentinel-propagation-numerical-pipelines` is honoured (the unrepresentable
timestamp is carried as an explicit `Ptime.t option`/`None`, not a silent epoch
sentinel — policy is applied visibly at the call site); the timestamp assertion
uses `Ptime.equal … Ptime.epoch` (exact), so `nan-aware-tolerance-comparator`
does not apply (no float tolerance comparison); `olog-eio-test-boilerplate` is
satisfied (both tests run under `Eio_main.run` + `Eio.Switch.run`).

---
**Handoff:** Task 5/6: Timestamp fallback policy complete — `dune build &&
dune test` green (50 Logger tests; full suite green; `dune build @fmt` and
`dune build @doc` both exit 0). The two named tests —
`test_create_fail_mode_rejects_broken_clock` and
`test_log_marks_invalid_timestamp_by_default` — are green (both confirmed
failing before the fix), plus a boundary `Ok`-arm test
(`test_create_fail_mode_accepts_valid_clock`) added per
`boundary-branch-covered-only-by-integration`.
→ 🧑 YOU: review the changes, then `/clear` and run `/task 6`.

## Task 6 Reflections

**Hardest decision:** Whether to pull `llms.txt` into this task. The four
enumerated steps named only `logger.mli`, `output.mli`, and ADRs 0003/0007 — and
the `.mli` doc comments turned out to be almost entirely aligned already (kept
current incrementally during Tasks 1–5), so the prose pass itself was small. The
real work surfaced only because the compliance scan led me to check the repo's
*other* documentation: `llms.txt` still showed the deleted `Config.default`, a
non-`result` `create`, and the pre-result sink shape. That put the task's
literal scope ("these four files") in direct conflict with the `llm-docs-api-sync`
convention (LLM docs are a public contract; code generated from the stale file
would not compile) and with PRD NFR2 ("every repaired contract documented"). It
was hard because both "do exactly what the task says, nothing more" and "don't
ship a known convention violation" are explicit standing rules, and they pointed
opposite ways. I treated it as a Criterion-D decision, surfaced it, and the
developer chose to fix `llms.txt` in Task 6; I recorded that as RFC 0013
Implementation Decision 1.

**Alternatives rejected:**
- *Silently expand scope and rewrite `llms.txt` without asking.* It's the
  "right" technical outcome, but it materially grows the task's diff beyond its
  written steps — a scope call that belongs to the developer, not me. Rejected in
  favour of surfacing the decision.
- *Defer `llms.txt` to `/prereview` or a separate docs PR.* Smaller, literal-to-
  spec Task 6, but it lets the branch reach `/prereview` with broken LLM docs and
  a live `llm-docs-api-sync` violation — exactly the drift this documentation
  task exists to close. Rejected once the developer chose Option 1.
- *Verify the `llms.txt` snippets by eyeballing them against `basic.ml`.* The
  idiom is character-identical to the proven examples, so inspection felt
  sufficient — but the whole point of `llm-docs-api-sync` is that generated code
  *compiles*, so I compiled the Quick Start as a throwaway `examples/llms_check.ml`
  (added to the `executables` stanza, built, then removed; `examples/dune` has
  zero net diff). Belief is not verification.
- *Retroactively rewrite the older RFCs (0003/0004/0005) that still mention
  `Config.default`.* Rejected: those are frozen point-in-time design records;
  RFC 0013 is the amending document, and the ADR amendments + status lines are
  the sanctioned way to mark superseded decisions, not edits to historical RFCs.

**Least confident about:** Two judgement calls. (1) The breadth of the `llms.txt`
rewrite. Beyond the strictly-stale `Config.default`/signature fixes, I also
enriched a few adjacent lines (the conservation note in Core Concepts, the
`flush`/`shutdown` liveness comments, the "Errors as values" design bullet) so
the file is internally consistent with the now-true contracts rather than merely
non-broken. That edges toward "more than the minimum"; a reviewer who wants the
`llms.txt` change confined to only the compile-breaking lines may prefer those
trimmed. (2) The ADR amendment style. There was no prior amendment convention in
`docs/adrs/`, so I invented one: an `## Amendment (RFC 0013, …)` section plus a
status-line annotation (`Accepted (amended by RFC 0013, …)`) rather than flipping
the status to `Superseded` (the core decisions still stand — only details change).
A reviewer may prefer a different convention; if so it should be applied uniformly
to both ADRs.

**Solutions violations fixed:**
- `llm-docs-api-sync` — `llms.txt` (an LLM-facing API reference) had drifted from
  the post-RFC-0013 public API: it showed the deleted `Logger.Config.default`
  record-update idiom (4 sites), `Logger.create : … -> Logger.t` (now returns
  `(Logger.t, string) result`), and the pre-result `sink`/`Output.t` shapes, with
  no `Config.make`, `timestamp_fallback`, or `olog.invalid_timestamp` marker.
  Rewrote the Quick Start, the Logger/Output API reference, and the multi-output /
  graceful-shutdown patterns to the current API (using the project's documented
  `let ( let* ) = Result.bind` threading idiom), updated the Core Concepts and
  Key-Design-Decisions prose to match, and compile-checked the Quick Start
  snippet against the real library. The drift predated Task 6 (it accumulated as
  the API changed across Tasks 1–5 without `llms.txt` being updated alongside);
  Task 6 is the documentation-alignment task and the last before `/prereview`, so
  it is the correct place to close it. Fix was authorised as RFC 0013
  Implementation Decision 1.

Post-fix scan of all modified files (`lib/logger.mli`, `docs/adrs/0003-*.md`,
`docs/adrs/0007-*.md`, `docs/rfcs/0013-*.md`, `llms.txt`, `CLAUDE.md`) against the
global + local libraries found no remaining violations:
`markdown-emphasis-breaks-doc-comment` is satisfied (the `.mli` additions use
`{e emitted}`, never a raw `*…*` span before `)`; the `*raises*` emphasis lives
only in a `.md` ADR, which the convention does not cover);
`odoc-doc-comment-attaches-to-preceding-item` holds (no new `val`s; only existing
trailing doc comments were edited); `result-let-binding`/`avoid-result-get-ok`
hold (the `llms.txt` snippets use `let*`-threading and explicit `match`, never
`Result.get_ok`); and `rfc-post-implementation-verification-section` does not
apply (RFC 0013 makes no empirical tolerance/performance claim — its
conservation and liveness guarantees are carried by durable tests in the suite,
not a one-time measurement).

---
**Handoff:** Task 6/6: Documentation alignment, ADR amendments, quality gate
complete — all tasks done. The five-check quality gate is green: `dune build`
(exit 0), `dune test` (exit 0; 50 Logger tests + the full suite pass),
`dune build @fmt` (exit 0), `dune build @doc` (exit 0), `opam-dune-lint`
(exit 0; `olog.opam` / `olog_ppx.opam` OK). `logger.mli` and `output.mli` doc
comments now describe the now-true contracts; ADR 0003 (clock closure returns
`Ptime.t option`; policy applied by the logger) and ADR 0007 (continue-on-failure
via result match; `Eio.Cancel.Cancelled` always re-raised) are amended with
RFC 0013 noted as the amending document; `llms.txt` is synced to the post-0013
API (RFC 0013 Implementation Decision 1).
→ 🧑 YOU: review the changes, then run `/prereview`.
