# ADR 0002: Raw OCaml Effects for Fiber-Local Context Over Eio.Fiber.with_binding

**Status:** Accepted
**Date:** 2026-02-17
**RFC:** docs/rfcs/0002-fiber-local-context.md

## Context

RFC 0002 (Fiber-Local Context Propagation) specified `Eio.Fiber.create_key` /
`Eio.Fiber.get` / `Eio.Fiber.with_binding` as the mechanism for storing and
retrieving fiber-local logging context. Requirement F7 mandates that a fiber
forked inside `with_context` starts with an empty context — isolation must be
the default.

During the quality-gate phase (Task 4), `lib/context.ml` was rewritten to use
`Eio.Fiber.with_binding` and the fiber isolation test (`test_fiber_isolation`)
failed immediately: the child fiber received the parent's fields rather than an
empty context. Inspection of the Eio source confirmed the behaviour —
`Eio.Fiber.with_binding` stores bindings in a per-fiber-context map that Eio
propagates to child fibers when they are forked. Isolation is not the default
for Eio fiber-local keys; inheritance is.

The implementation therefore diverges from the RFC's stated mechanism and uses
raw OCaml 5 effects instead.

## Decision

We use a module-level effect type (`type _ Effect.t += GetContext : t Effect.t`)
and `Effect.Deep.match_with` to implement `with_context`. `current ()` performs
`GetContext` and catches `Effect.Unhandled` to return `empty` when no handler
is installed.

Child fibers forked with `Eio.Fiber.fork` run from fresh Eio continuations that
do not include the parent fiber's effect handlers. `GetContext` performed inside
a child fiber is therefore unhandled, `current ()` returns `empty`, and F7 is
satisfied without any extra mechanism.

## Rationale

The only mechanism in OCaml 5 / Eio that provides **isolation by default** for
dynamic-scope state is the dynamic extent of an effect handler. A handler
installed via `Effect.Deep.match_with` is in scope exactly as long as its
callback is executing in the same continuation chain. Forked fibers are separate
chains. Eio's fiber-key storage is per-fiber-context but **shared across fork**;
effect handlers are not.

## Alternatives Rejected

- **`Eio.Fiber.with_binding` (RFC-specified):** Rejected because Eio propagates
  fiber-key bindings to child fibers at fork time. The `test_fiber_isolation`
  test confirmed the child received the parent's context, violating F7. The RFC
  Option A rationale was incorrect about the isolation property.

- **`Domain.DLS` (domain-local storage):** Rejected in the RFC (Option B) and
  confirmed invalid here. Multiple Eio fibers can be scheduled on a single
  domain; DLS would be shared across concurrent fibers, breaking isolation
  between requests.

- **Shallow effect handler (`Effect.Shallow.match_with`):** Rejected because a
  shallow handler only intercepts the first effect occurrence and then the
  continuation is suspended. Eio performs many scheduler effects (for I/O,
  yielding, forking) between log calls, so a shallow handler would be consumed
  by the first scheduler effect rather than by `GetContext`.

## Consequences

**Easier:**
- F7 (fiber isolation) is satisfied without any explicit "don't inherit"
  mechanism — isolation falls out naturally from the continuation model.
- `current ()` requires no Eio scheduler to be active — it works in any
  OCaml 5 context; `Effect.Unhandled` is caught locally.
- No dependency on `eio_main` or any Eio backend in `lib/context.ml` (NF3 still
  holds).

**Harder:**
- `lib/context.ml` now uses `Effect.Deep.match_with` with a universally
  quantified `effc` field, which requires a concrete type annotation on the
  `merged` parameter (`(merged : t)`) and an explicit `type c.` polymorphic
  annotation on `effc` to satisfy OCaml's type checker. This is not obvious and
  must be documented.
- `ocamlformat` ≤ 0.28.1 cannot parse the `| effect P, k ->` pattern syntax;
  `Effect.Deep.match_with` with record syntax is required instead.
- Future contributors must understand that any change to `with_context` must
  preserve the deep-handler structure — replacing with `Eio.Fiber.with_binding`
  would silently break F7 (the test suite does guard this).
- If Eio ever adds a "fork without inheriting fiber-local state" primitive,
  this ADR should be revisited.
