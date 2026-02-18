# RFC 0002: Fiber-Local Context Propagation

| Field       | Value                              |
|-------------|------------------------------------|
| **RFC**     | 0002                               |
| **Title**   | Fiber-Local Context Propagation    |
| **Status**  | Accepted                           |
| **Created** | 2026-02-17                         |
| **Session** | 2                                  |

---

## Summary

Introduce `Context`, a module that associates structured logging fields with the current fiber without requiring callers to thread context through every function argument. `with_context` installs a dynamic-scope OCaml 5 effect handler that binds additional fields for the duration of a callback; `current` retrieves the accumulated fields anywhere in that continuation. Context is isolated between fibers by default: forked fibers run fresh continuations that do not inherit the parent's effect handler.

> **Implementation note:** The RFC originally specified `Eio.Fiber.create_key` / `Eio.Fiber.with_binding` as the storage mechanism. During implementation, `Eio.Fiber.with_binding` was found to propagate bindings to child fibers at fork time, violating F7. The implementation therefore uses raw OCaml 5 effects instead. See ADR 0002 for the full rationale.

---

## Motivation

In direct-style concurrent code using Eio, log calls are made deep in call stacks where request-scoped metadata (correlation IDs, user IDs, trace spans) is not conveniently available at every call site. Passing these fields as explicit function arguments requires threading them through every intermediate function — a violation of separation of concerns and an obstacle to clean API design.

OCaml's standard library provides no fiber-local storage. The `logs` library addresses a similar need with thread-local reporters, but its design predates Eio's fiber model and does not compose cleanly with structured concurrent code. `Domain.DLS` (domain-local storage) is the wrong primitive: multiple Eio fibers can be scheduled on a single domain, so DLS would be shared across concurrent fibers — breaking isolation. `olog` needs a fiber-local context that:

- Automatically scopes fields to the current fiber with no explicit threading
- Is isolated between fibers by default (child fibers start empty)
- Supports nested scoping where inner (deeper) fields override outer ones on duplicate keys
- Is zero-cost to read when no context has been set

---

## Scope

### In Scope

- `Context.t` — the type for fiber-local context (`(string * Value.t) list`)
- `Context.empty` — the empty context value
- `Context.current` — read the current fiber's context fields
- `Context.with_context` — bind additional fields for the duration of a callback
- A single module-level `fiber_key : Context.t Eio.Fiber.key` created at module load time
- Upsert merge semantics: inner/deeper fields override outer fields on duplicate keys
- `.mli` file and Alcotest tests (including Eio integration tests using `Eio_main.run`)

### Out of Scope

- Automatic propagation of context to forked child fibers
- `Context.set` / `Context.clear` / mutable mutations outside `with_context`
- Thread-local or domain-local storage fallback
- Wiring `Context.current` fields automatically into `Entry.create` (deferred)
- `Context.to_yojson` / serialisation of the context type itself
- Removing individual keys from context
- Any form of context inheritance when forking fibers

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `Context.t` is `(string * Value.t) list` — a concrete, non-abstract type alias |
| F2  | `Context.empty` is the empty list `[]` |
| F3  | `Context.current ()` returns the fields bound to the current fiber via `fiber_key`, or `Context.empty` if no binding exists |
| F4  | `Context.with_context ~fields f` merges `fields` into the current context and runs `f` under the merged context; the previous context is restored when `f` returns or raises |
| F5  | Merge semantics: on duplicate keys, the value from `fields` (inner/deeper) wins over the existing context (outer). Implemented with upsert: `existing @ fields` deduplicated keeping the last occurrence |
| F6  | `fiber_key` is a single `Context.t Eio.Fiber.key` created once at module load time — not per `with_context` call |
| F7  | Context is isolated between fibers: a fiber forked inside `with_context` starts with an empty context |
| F8  | `with_context ~fields:[] f` runs `f ()` without modifying the stored fiber binding |
| F9  | Nested `with_context` calls accumulate fields; the deepest binding for any duplicate key wins |
| F10 | `with_context` takes a plain `unit -> 'a` callback — no Eio switch parameter |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | OCaml >= 5.2.0 |
| NF2 | Eio >= 1.0 (for `Eio.Fiber.create_key`, `Eio.Fiber.get`, `Eio.Fiber.with_binding`) |
| NF3 | `Context` may depend on `eio`; it must NOT depend on `eio_main` or any Unix backend |
| NF4 | `Context.current ()` allocates no new values when the context is empty (returns the existing `empty` constant) |
| NF5 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` must all pass |
| NF6 | Integration tests use real Eio fibers (`Eio_main.run`) — `Eio.Mock` is not used for fiber-local behavior |

---

## Public Interface

```ocaml
(** Context.mli *)

(** Fiber-local context for structured logging fields.

    A single fiber-local key stores an association list of [(string * Value.t)]
    pairs scoped to the current fiber. Use {!with_context} to add fields for
    the duration of a callback and {!current} to retrieve the accumulated
    fields in the current fiber.

    Context is isolated between fibers: a fiber forked inside [with_context]
    starts with an empty context. *)

type t = (string * Value.t) list
(** An association list of field name–value pairs representing the logging
    context for the current fiber. The list may contain duplicate keys;
    consumers should treat the last occurrence as authoritative. *)

val empty : t
(** The empty context — an empty association list. *)

val current : unit -> t
(** [current ()] returns the context fields bound in the current fiber, or
    {!empty} if no context has been set.

    Must be called within an Eio fiber (i.e., inside [Eio_main.run]). *)

val with_context : fields:(string * Value.t) list -> (unit -> 'a) -> 'a
(** [with_context ~fields f] runs [f] with [fields] merged into the current
    fiber-local context. Fields in [fields] override any existing fields with
    the same key (deeper context wins). The previous context is restored when
    [f] returns or raises.

    [with_context ~fields:[] f] is equivalent to [f ()]. *)
```

---

## Options Considered

### Option A: Module-level `fiber_key` — chosen

Create `let fiber_key : t Eio.Fiber.key = Eio.Fiber.create_key ()` once at module initialization.

**Pros:** No allocation per `with_context` call. Deterministic: all calls share one key. Simple to reason about. `Eio.Fiber.create_key` is a pure allocation requiring no active scheduler — safe at module init time.

**Cons:** Module initialization order matters in OCaml. In practice this is a non-issue: the key is a plain heap allocation and `Context` has no circular dependencies.

### Option B: Domain-local storage (`Domain.DLS`)

Use OCaml 5's `Domain.DLS.new_key` to store context per domain.

**Pros:** No Eio dependency for storage itself. Works outside Eio contexts.

**Cons:** Domains are not fibers. In Eio, multiple concurrent fibers can be scheduled on the same domain. DLS would be shared across those fibers, meaning two concurrent requests would contaminate each other's log context. Violates F7.

**Rejected.**

### Option C: Explicit context argument threading

Add a `~ctx:Context.t` parameter to every logging call site.

**Pros:** No hidden state. Explicit about which context is active. Works without Eio.

**Cons:** Requires threading context through every intermediate function — the entire problem this module exists to solve. Increases arity, couples all callers to `Context.t`.

**Rejected.**

### Option D: Automatic context inheritance in forked fibers

When Eio forks a child fiber, copy the parent's context bindings automatically.

**Pros:** Convenient for fan-out patterns where child fibers should share the parent's correlation ID.

**Cons:** Requires hooking into Eio's fiber fork mechanism, which has no stable public API for this. Implicit inheritance makes it unclear at a `Fiber.fork` call site whether context will be propagated. Explicit `with_context` inside the fork is clearer and preserves Article VII (prefer reversible, simple approaches). The spec explicitly requires isolation by default.

**Rejected.**

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| `Eio.Fiber` API changes between versions | Compilation failure | Pin `eio >= 1.0`; isolate Eio calls in `Context` implementation only |
| `current ()` called outside any `with_context` scope (including from a forked fiber or outside any scheduler) | Returns `empty` | `Effect.Unhandled` is caught internally; `test_current_outside_eio` verifies this is safe |
| Upsert merge on large field lists is O(n²) | Slow for pathological inputs | Log context fields are bounded in practice (< 20 entries); acceptable per NF4 |

---

## Open Questions

None — requirements are fully specified.
