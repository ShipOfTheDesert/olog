# ADR 0003: `now : unit -> Ptime.t` Closure for Clock Injection

**Status:** Accepted
**Date:** 2026-02-18
**RFC:** docs/rfcs/0003-logger-async-worker.md

## Context

`Logger.t` must timestamp each `Entry.t` at the moment `Logger.log` is called.
The clock is supplied by the caller as an Eio resource so that tests can inject a
controlled clock rather than reading wall time.

The natural representation for an Eio clock is
`[> Eio.Time.clock_ty] Eio.Resource.t` (equivalently, `_ Eio.Time.clock`).
This type carries a covariant polymorphic type bound (`[> clock_ty]`). OCaml
cannot store a value with an existential polymorphic bound in a concrete record
field without either an explicit existential wrapper (`type t = T : _ Eio.Time.clock -> t`)
or making `Logger.t` itself a functor over the clock type. Both approaches add
non-trivial complexity to every call site that constructs or uses a `Logger.t`.

## Decision

We store the clock as a captured closure: `now : unit -> Ptime.t`.

In `Logger.create`, a single closure is constructed once:

```ocaml
let now () =
  Eio.Time.now clock |> Ptime.of_float_s
  |> Option.value ~default:Ptime.epoch
in
```

The concrete clock type is resolved at `create` call time. `Logger.t` stores
only the plain `unit -> Ptime.t` function, which has no polymorphic bound and
can be stored in a normal record field. All subsequent calls to `t.now ()` go
through this closure.

## Rationale

The closure pattern is the minimal change that solves the type-storage problem:
one extra heap allocation at logger creation (not on the hot log path), zero
change to any caller's type signature, and trivial test injection (`fun () ->
fixed_time` suffices).

## Alternatives Rejected

- **Existential wrapper** (`type clock_box = Box : _ Eio.Time.clock -> clock_box`):
  Rejected because it requires unwrapping at every `now` call and leaks an
  internal type into every module that touches `Logger.t`. Adds complexity
  with no benefit over the closure.

- **Functor over clock type** (`module Make (C : Eio.Time.Clock) : S`):
  Rejected because it multiplies every Logger type (`Logger.t`, `Logger.Config.t`,
  `Logger.sink`) into a functor output, makes the public API significantly more
  complex, and conflicts with Article V (maximum 3 top-level public modules;
  YAGNI). The RFC does not specify a functor interface.

- **Store `_ Eio.Time.clock` directly with a GADT or first-class module:**
  Both require more OCaml machinery than the closure and offer no observable
  benefit for library users.

## Consequences

**Easier:**
- `Logger.t` is a plain concrete record with no polymorphic fields — it can be
  stored, passed, and pattern-matched without any type-system ceremony.
- Test injection is trivial: pass `fun () -> my_fixed_ptime` without needing
  a mock Eio environment.
- `Eio.Time.now` is called in exactly one place (`create`); any future API
  change to `Eio.Time` only requires updating that site.

**Harder:**
- The clock is captured at `create` time. If the Eio clock resource is
  invalidated after `create` (e.g., the environment is shut down), `t.now ()`
  will raise inside the worker. This is not a realistic scenario — `Logger.t`
  must be used within the same `Eio_main.run` scope as the clock — but it
  removes the ability to swap clocks on a live logger.
- `Ptime.of_float_s` can return `None` for timestamps outside the valid range
  (year 0–9999). The fallback to `Ptime.epoch` is silent. Valid Eio clocks
  never produce such values; the fallback is unreachable in practice.
