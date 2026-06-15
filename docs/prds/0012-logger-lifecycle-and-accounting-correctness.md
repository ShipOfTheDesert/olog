# PRD 0012 — Logger Lifecycle and Accounting Correctness

**Status:** Accepted
**Author:** Miguel (miguellova@gmail.com)
**Date:** 2026-06-12
**Source:** [ANALYSIS.md](../../ANALYSIS.md) (findings 1–3 and "smaller" findings)
**Companion:** PRD 0014 (formatter output correctness) covers ANALYSIS findings 4–6 and is sequenced after this PRD.

## 1. Problem statement

ANALYSIS.md documents that several lifecycle and accounting contracts promised
in the logger's `.mli` documentation are not true in the implementation. A
fiber calling `flush` or `shutdown` can suspend forever if the worker died via
switch cancellation; concurrent `shutdown` calls can deadlock despite a
documented idempotence guarantee; worker cancellation can be silently
swallowed by sink error handling; configuration constraints stated in the
documentation are not enforced; entries can be lost without being counted,
making `drop_count` untrustworthy; and a failing clock silently stamps entries
with the 1970 epoch. The library's stated purpose is *production-grade*
structured logging; hanging shutdown paths and untrustworthy diagnostics are
disqualifying for that claim.

## 2. Goal

Every lifecycle and accounting promise currently written in `lib/logger.mli`
is true, demonstrated by tests that would have caught the original findings.
Concretely: no caller of any public function can suspend indefinitely once the
worker has terminated; concurrent lifecycle calls are safe; invalid
configurations are rejected at creation; `submitted = emitted + dropped` holds
under concurrent load; and timestamp failures follow an explicit,
user-selectable policy instead of a silent fallback.

## 3. Scenarios

- **Operator shutting down a service:** a deploy cancels the application's
  root switch mid-traffic. Today a cleanup fiber calling `Logger.flush` can
  hang the shutdown sequence forever; after this work it returns promptly.
- **Engineer debugging with `diagnostics`:** today `drop_count` undercounts
  (several loss paths are uncounted), so "zero drops" doesn't mean zero loss.
  After this work the counter is trustworthy.

## 4. Requirements

### Functional

- **FR1 — No suspension on a dead worker.** `Logger.flush` and
  `Logger.shutdown` must return promptly when the logger's worker has
  terminated for any reason, including cancellation of the enclosing switch.
  This makes the documented post-shutdown no-op semantics true on all
  termination paths. *(ANALYSIS finding 1)*
- **FR2 — Concurrent-safe, idempotent shutdown.** `Logger.shutdown` must be
  safe under concurrent invocation from any number of fibers or domains, and
  every caller must return once shutdown completes. The `.mli` already
  promises idempotence; the implementation must honor it. *(ANALYSIS finding 2)*
- **FR3 — Sink failures as values; cancellation never swallowed.** The sink
  contract must report expected emission failures as values rather than
  exceptions (per Article X.2), so the worker has no reason to catch broadly.
  Worker cancellation must always reach the drain-and-close path rather than
  being discarded by sink error handling. This is a breaking change to the
  public sink contract, accepted pre-1.0. *(ANALYSIS finding 3)*
- **FR4 — Configuration validated at creation.** `Logger.create` must reject
  configurations that violate documented constraints (e.g., non-positive
  `queue_depth`) instead of accepting them and silently dropping every entry.
  The failure mechanism (exception vs. result) is an RFC decision.
  *(ANALYSIS smaller finding: queue_depth)*
- **FR5 — Every accepted entry is accounted for.** Every entry accepted by
  `log`/`log_exn` must either be emitted to the sinks or counted in
  `drop_count`; no code path may discard an entry without incrementing the
  counter. *(ANALYSIS smaller finding: silent loss; also covers the loss mode
  in finding 3)*
- **FR6 — Configurable timestamp-failure policy.** When the injected clock
  yields a value that cannot be represented as a timestamp, the behavior must
  follow a user-selectable fallback mode configured at logger creation,
  replacing today's silent 1970-epoch stamp. The minimum modes are: fail
  loudly (rejecting an already-broken clock at creation), and stamp the entry
  with a fallback timestamp that is explicitly marked as invalid. The default
  is the marked fallback. *(ANALYSIS smaller finding: clock failure; see D2)*

### Non-functional

- **NFR1 — Non-blocking guarantee preserved.** `log` and `log_exn` must
  remain non-suspending for callers under all fixes; the drop model is
  unchanged.
- **NFR2 — Contracts protected by tests.** Each repaired contract ships with
  a test in the same change: shutdown idempotence under concurrency and the
  conservation invariant (`submitted = emitted + dropped`) under concurrent
  load. These are the tests ANALYSIS.md identifies as the ones that would
  have caught the findings.
- **NFR3 — No new runtime dependencies.** Test-only dependencies are
  acceptable; the core library's dependency set is unchanged.
- **NFR4 — Land before any tagged release.** FR3 breaks the public sink
  contract; it must merge before the first opam release so the break has no
  external consumers.

## 5. Scope

**IN:**
- Logger lifecycle correctness (FR1–FR3)
- The sink contract redesign required by FR3 (breaking change, pre-1.0)
- Config validation (FR4), entry accounting (FR5), timestamp-failure policy (FR6)
- The tests in NFR2

**OUT OF SCOPE:**
- Formatter output correctness (duplicate JSON keys, escaping, float
  precision) — PRD 0014
- Worker batching and the `Output.write` signature question — folded into the
  Tier 2 metrics roadmap entry
- Splitting `drop_count` by cause (queue-full vs. post-shutdown) — Tier 2
  metrics roadmap entry
- The `docs/lessons/` process and CONTRIBUTING.md checklist changes proposed
  in ANALYSIS — separate roadmap entry

## 6. Product decisions

**D1 — Invalid configuration: reject loudly (chosen) vs. clamp to nearest
valid value.**
Clamping keeps applications running but turns a misconfiguration into silent,
surprising behavior (exactly the failure mode being fixed). Rejecting at
creation surfaces the error at startup where it is cheap to fix. Chosen:
reject loudly.

**D2 — Timestamp failure: configurable mode with marked-fallback default
(chosen) vs. a single hardcoded policy.**
Timestamp conversion can only fail for NaN/infinite clock values or dates
outside years 0–9999 — unreachable with a real system clock and realistic
mainly via injected/mock clocks, so no single policy fits all deployments. A
hardcoded fail-fast policy risks a logging library crashing its host
application; a hardcoded fallback denies strict deployments (and tests) the
loud failure they want. Chosen: a user-selectable mode at creation. Default is
the marked fallback rather than fail-loudly because a logger's worst failure
mode is becoming the reason the application is down; strict users opt into
failing. Dropping the entry was rejected as the default path: it loses data at
exactly the moment the log is most needed (the RFC may still include it as an
explicit opt-in mode if useful).

## 7. Open questions

None.
