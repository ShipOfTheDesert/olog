# olog — Architecture and Implementation Analysis

Date: 2026-06-11
Scope: full read of `lib/` (~900 lines), `ppx/ppx_olog.ml`, ADRs, RFCs, ROADMAP.
Build state at time of analysis: `dune build` clean, all test suites pass
(Level, Value, Entry, Context, Formatter, Output, Logger, PPX — 60+ tests).

## Overall verdict

The architecture is sound and unusually well-documented for a young project
(11 RFCs, 7 ADRs; decisions like the single-queue flush ordering and the `now`
closure are written down and correct). The data model (`Level`/`Value`/`Entry`)
is clean and pure. The real problems cluster in two places: **liveness hazards
in the logger's shutdown/flush paths** and **output-format correctness in the
formatters**. Findings below are ordered by severity.

## Bugs — liveness (highest priority)

### 1. `flush` and `shutdown` hang forever if the worker dies via switch cancellation

`t.closed` is only ever set by `shutdown` (`lib/logger.ml:184`). When the
enclosing switch is cancelled instead, the worker drains and exits
(`lib/logger.ml:106-108`) but never marks the logger closed. A subsequent
`flush` passes the `closed` check, enqueues a `Flush` message that no one will
ever take (`lib/logger.ml:177`), and `Promise.await` suspends the calling fiber
permanently. `drain_on_cancel` only resolves promises already in the queue at
cancel time. The comment points at "RFC 0003 §Risks" so this is a known gap,
but it is a real deadlock, not just a risk note.

**Fix:** set `t.closed` in the worker's `Fun.protect ~finally`
(`lib/logger.ml:103`), so post-mortem `flush`/`shutdown` become the documented
no-ops.

### 2. Concurrent `shutdown` calls can deadlock the loser

`shutdown` is check-then-set (`Atomic.get` at `lib/logger.ml:182`, `Atomic.set`
at `lib/logger.ml:184`), not `compare_and_set`. Two fibers on different domains
can both pass the check; the worker processes the first `Shutdown`, runs
`drain_trailing`, and exits — if the second caller's `Eio.Stream.add` lands
after the drain finishes, its promise is never resolved and it suspends
forever. Narrow window (multi-domain only), but the mli promises "shutdown is
idempotent: the second and subsequent calls return immediately"
(`lib/logger.mli:174-175`), which this violates.

**Fix:** `Atomic.compare_and_set` plus storing the shutdown promise so losers
await the winner's completion.

### 3. The worker swallows `Eio.Cancel.Cancelled` raised by sinks

`Output.protect` deliberately re-raises cancellation "so the worker can shut
down" (`lib/output.ml:14-17`), but the worker's `emit_to_sinks` then catches it
with `try sink.emit entry with _ -> ()` (`lib/logger.ml:49`). The two layers
contradict each other. In practice shutdown still happens because the next
`Stream.take` raises `Cancelled`, but the entry being written when cancellation
hit is silently lost and not counted in `drop_count`.

**Fix:** match `Eio.Cancel.Cancelled` explicitly in
`emit_to_sinks`/`flush_sinks` and re-raise it.

## Bugs — output correctness

### 4. `Formatter.json` can emit duplicate JSON keys

It splices user fields at the top level: `` `Assoc (base @ fields @ src) ``
(`lib/formatter.ml:26`). A field named `"level"`, `"message"`, `"timestamp"`,
or `"src_pos"` produces a JSON object with two keys of the same name — most
consumers (Loki, Elasticsearch, `jq`) will keep an arbitrary one. It is also
inconsistent with `Entry.to_yojson`, which nests fields under a `"fields"`
object (`lib/entry.ml:41`), and with the README's documented output shape.

**Fix:** pick one envelope (nesting is the safer one) and use it in both
places.

### 5. Log injection through `logfmt` and `text` formatters

`logfmt_quote` quotes a value containing `\n` but emits the raw newline inside
the quotes (`lib/formatter.ml:32-48`), so one entry becomes two lines for any
line-oriented consumer — classic log forging via user-controlled field values.
It also escapes `"` but not `\`, so a value ending in `\` produces an ambiguous
`\"` sequence. The `text` formatter (`lib/formatter.ml:73-79`) does no escaping
at all, including in `message`.

**Fix:** escape `\n`, `\`, and `"` in logfmt; at minimum strip/escape newlines
in `text`.

### 6. `%g` float formatting silently truncates to 6 significant digits

`Value.to_string` (`lib/value.ml:7`) and `logfmt_value`
(`lib/formatter.ml:53`) use `%g`, so `duration_ms=12.3456789` logs as
`12.3457` and a nanosecond-precision epoch float is destroyed. JSON output is
unaffected (Yojson does its own printing).

**Fix:** use `%.17g` or `Float.to_string` for round-trippable output.

## Bugs — smaller

- **`queue_depth` is unvalidated.** The mli says "must be a positive integer"
  (`lib/logger.mli:35-38`) but `create` accepts anything. `queue_depth = 0`
  creates a rendezvous stream and the `length < 0` guard (`lib/logger.ml:139`)
  then drops *every* entry silently. Validate in `create` and raise
  `Invalid_argument`.
- **Silent, uncounted entry loss in two drain paths.** `drain_trailing`
  discards racing `Log` entries without touching `drop_count`
  (`lib/logger.ml:58`), and the `log` closed-check race (check at
  `lib/logger.ml:122`, add at `lib/logger.ml:140`) can enqueue an entry after
  the worker exits — lost with no accounting. Low frequency, but it undermines
  `diagnostics.drop_count` as a trustworthy metric. Relatedly, `drop_count`
  conflates "queue full" with "logged after shutdown" — worth splitting during
  the Tier 2 metrics work.
- **Clock failure maps to epoch.** `Ptime.of_float_s` failure silently yields
  `Ptime.epoch` (`lib/logger.ml:112`), so a broken clock produces
  plausible-looking 1970 timestamps instead of failing loudly.

## Architecture observations

**The effects-based context is elegant but is on a collision course with the
roadmap.** ADR 0002's choice — a deep effect handler with deliberate
*non-inheritance* to forked fibers — is internally consistent and the
implementation (`lib/context.ml`) is correct, including handler capture across
Eio suspensions. But the README advertises "correlation IDs and metadata
propagate automatically to child fibers" as a feature, which is the opposite
of what the code does, and Tier 3's OpenTelemetry trace propagation almost
always *wants* inheritance (a request's `trace_id` should follow `Fiber.both`
branches). Decide now whether F7 isolation survives, because retrofitting
inheritance onto raw effects means switching to `Fiber.with_binding` or
threading context explicitly — an API break.

**The batch write API is dead generality.** `Output.t.write` takes
`Entry.t list` (`lib/output.ml:1`) but `to_sink` always calls it with a single
entry (`lib/output.ml:43`), and the worker emits one entry per queue take —
one `Eio.Flow.copy_string` (i.e., one write syscall) per log line. Either
implement actual batching in the worker (drain the queue greedily into one
`write` call — also the natural performance win) or simplify the signature to
`Entry.t -> unit`.

**Single-queue control messages are the right call.** Routing
`Flush`/`Shutdown` through the same FIFO as entries (ADR 0004) gives flush its
happens-after ordering for free, and the cancel-drain under
`Eio.Cancel.protect` is correct. The TOCTOU on `Stream.length` before `add` is
acknowledged and acceptable for a drop-model logger.

**The PPX is solid but narrow.** Literal auto-wrapping, the bound `__olog_l`
(single evaluation of the logger expression), the `is_enabled` guard making
field construction lazy, and the conditional backtrace capture are all
correct. Limitations worth knowing: messages must be string literals (no
dynamic messages through the PPX at all), and auto-wrapping only applies to
syntactic list literals — a `fields` variable passes through untouched. Both
are fine as documented constraints; neither is documented in the README.

**Packaging leftovers.** `bin/main.ml` is scaffold "Hello, World!" with
`(public_name olog)` — it would install a junk `olog` binary with the package;
delete `bin/` or repurpose it. `dune-project` still has `yourhandle`/`Your
Name` placeholders (known, Tier 2). The README is stale: it calls context,
async emission, and the PPX "planned" when all three are implemented, claims
25 tests (there are 60+), and shows the `Entry`-level quick start rather than
the actual `Logger`/PPX API.

## Future work — suggested reprioritization

The roadmap's Tier 2/3 content is reasonable, but the bugs above belong in
Tier 1, which is otherwise marked complete. Suggested order:

1. **Liveness fixes** (findings 1-3): worker sets `closed` on exit, CAS in
   `shutdown`, cancellation not swallowed in emit. Small, contained diffs in
   `lib/logger.ml`.
2. **Formatter correctness** (findings 4-5): decide the JSON envelope, add
   logfmt/text escaping. These change observable output, so do them before
   anyone depends on the current format — exactly the "before 1.0" window.
3. **Worker batching**: justify the existing batch `write` API and collapse
   per-entry syscalls. Pairs naturally with the Tier 2 metrics RFC (emit
   counts, bytes written).
4. **Resolve the context-inheritance question** before starting the OTel RFC,
   since it determines whether ADR 0002 gets superseded.
5. **README/packaging** (Tier 2 first item) is the cheapest credibility win
   and currently contains factually wrong feature claims.

Dynamic level filtering, sampling, and the registry (Tier 2/3) are correctly
sequenced after these — none is blocked by the fixes above, and the `Atomic.t`
min-level design sketched in the roadmap is right.

## Preventing these bug classes from recurring

Every bug above maps to a known pattern with a known prevention. The
enforcement ladder, strongest first: **type system > test > lint/CI > review
checklist > prose**. Each prevention below should land on the highest rung it
can reach; a lesson that only exists as prose will be violated again.

### Leverage the type system: make the illegal states unrepresentable

**Lifecycle as a state machine, not a boolean (prevents findings 1 and 2).**
The root cause of both liveness bugs is that the logger's lifecycle is encoded
as `closed : bool Atomic.t` plus an *implicit* invariant ("worker is alive iff
not closed") that two code paths can break independently. Replace it with one
atomic state variant:

```ocaml
type state =
  | Running
  | Stopping of unit Eio.Promise.t  (* shutdown in flight; await this *)
  | Stopped
```

and expose only a CAS-based transition function — never `Atomic.set`. Then:
check-then-set is unwritable (CAS forces you to handle the lost race, and the
compiler forces you to handle every state in every match per Article X.3); a
second concurrent `shutdown` caller finds `Stopping p` and awaits the same
promise instead of enqueueing a second message; and the worker's exit is
itself a transition to `Stopped`, so a post-mortem `flush` pattern-matches
into the no-op branch instead of suspending forever. Rule of thumb worth
adding to the review checklist: *an `Atomic.get` followed by a dependent
`Atomic.set` is a race until proven otherwise — atomics may only be written
through `compare_and_set` transition helpers.*

**Errors as values at the sink boundary (prevents finding 3).** OCaml
exceptions are untyped, so the compiler cannot stop `with _ -> ()` from
swallowing `Cancelled`. The fix is to remove the reason to catch anything:
make the sink contract `emit : Entry.t -> (unit, emit_error) result` — which
Article X.2 already mandates and the current `sink` record violates. Once
expected failures travel as values, the only exceptions crossing the worker
boundary are genuinely exceptional (cancellation), and the worker has no
`try` at all. Until that refactor: extend Article X.3 to exception handlers —
*catch-all `with _ ->` is forbidden; handlers name the exceptions they
expect, and `Eio.Cancel.Cancelled` always re-raises.* This is grep-able and
belongs in CI.

**One serializer per type (prevents finding 4).** The duplicate-key bug
exists because `Entry.to_yojson` and `Formatter.json` are two parallel
reimplementations of "Entry as JSON" that drifted. Derive one from the other:
`Formatter.json` should be `fun e -> Yojson.Safe.to_string (Entry.to_yojson e)
^ "\n"` and nothing else. If top-level field splicing is genuinely wanted,
make field keys an abstract `Key.t` whose smart constructor rejects the
reserved names — then the collision is unrepresentable rather than unlikely.

**Parse, don't validate — escaping by construction (prevents finding 5).**
Raw `string` should not be able to reach an output buffer. Give each
formatter a private escaped-string type whose only constructor performs the
escaping; the compiler then guarantees no code path forgets it. The same
pattern, applied at the config layer, prevents the `queue_depth` hole: make
`Config.t` `private` (or abstract) with `Config.make : ... -> (t, string)
result` so the unvalidated record literal stops being constructible.

**Documented invariants must be executable.** Findings 2, 6, and the
`queue_depth` hole are all cases where the `.mli` makes a promise
("idempotent", "must be a positive integer") that nothing checks. New rule:
*every quantitative or behavioural claim in an `.mli` doc comment ships a
test asserting it, in the same PR.* Article III covers test-first for
behaviour; this extends it to documentation, which is also spec.

### Test what the type system cannot reach

- **Round-trip property tests** (qcheck): for each formatter,
  `parse (format entry) = entry` over generated entries — arbitrary strings
  in messages and field values would have caught the newline injection and
  the `%g` precision loss immediately. New formatter ⇒ new round-trip test,
  as a standing rule.
- **Interleaving tests for the concurrent core**: the shutdown race is
  invisible to single-domain Alcotest runs. Use DSCheck to model-check the
  atomic transitions, or at minimum a multi-domain stress test
  (`Eio.Domain_manager`) hammering `log`/`flush`/`shutdown` concurrently.
- **A conservation invariant test**: `entries submitted = entries emitted +
  drop_count` after shutdown, under concurrent load. This single property
  catches every silent-loss path found above (drain discards, the
  closed-check race, the swallowed-cancellation loss) without knowing about
  any of them specifically.

### Compound the learnings (process)

The project already writes ADRs for *decisions*; do the same for *failure
patterns*. After each bug class is fixed, add a short entry to a
`docs/lessons/` library — symptom, root cause, and the rule that prevents
recurrence — exactly the `/compound` model. Two constraints keep it from
becoming a graveyard of prose:

1. **Every lesson states its enforcement rung.** "Encoded in types"
   (state-machine variant), "encoded in a test" (round-trip property),
   "encoded in CI" (grep for `with _ ->`), or — only when nothing stronger
   exists — "review checklist item". If the rung is "checklist", the entry
   must say why it could not be a type or a test.
2. **Lessons feed the existing gates.** The checklist-rung rules go into
   CONTRIBUTING.md's Review Checklist (which `/prereview` already checks
   against), so they are applied automatically at every PR rather than
   relying on memory.

Candidate first entries, from this analysis: the CAS-only atomics rule, the
no-catch-all-handlers rule, one-serializer-per-type, mli-claims-need-tests,
and formatters-ship-round-trip-tests.
