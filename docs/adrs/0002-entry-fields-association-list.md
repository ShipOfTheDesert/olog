# ADR 0002: Use association list for Entry.fields

**Status:** Accepted
**Date:** 2026-02-17
**RFC:** docs/rfcs/0001-core-types.md

## Context

`Entry.t` carries a `fields` list of `(string * Value.t)` pairs representing
structured key-value metadata attached to a log event. A data structure must
be chosen to hold these pairs. The choice affects insertion order, deduplication
semantics, lookup complexity, and implementation simplicity. The RFC requires
upsert semantics: when the same key appears more than once, the last occurrence
wins (F15).

Log field lists in practice are small — typically fewer than 10 entries per
event. Fields are assembled once at call-site and then serialised; random-access
lookup by key is not a primary operation.

## Decision

We will represent `Entry.fields` as `(string * Value.t) list` — a standard
OCaml association list.

## Rationale

An association list is the simplest correct representation for this workload:

- **Insertion order is preserved.** Structured log consumers and human readers
  benefit from fields appearing in the order they were attached, which aids
  debugging.
- **Upsert deduplication is trivial.** A single reverse-filter-reverse pass
  removes earlier occurrences of duplicate keys in O(n) time, with no extra
  dependency.
- **No additional dependency.** `List` is in the standard library.
- **Reversible.** Changing to a `Map` in a future session is a localised
  change to `Entry` internals — the `.mli` type does not need to change if
  we keep the public type as `(string * Value.t) list`.
- **At < 10 entries the asymptotic advantage of a tree is irrelevant.** The
  constant factors of `Map.Make(String)` allocation dominate at small n.

## Alternatives Rejected

- **`Map.Make(String).t`:** O(log n) lookup and structural deduplication by
  key come for free, but insertion order is lost (the map is sorted by key),
  allocation per operation is higher, and the public type would change from a
  plain list to an abstract map type — a larger surface-area change. Rejected
  per Article VII (prefer simple, reversible approaches) and Article IX (YAGNI
  at n < 10).

- **`Hashtbl.t`:** O(1) amortised lookup and mutable upsert. Rejected because
  `Entry.t` is required to be immutable (Article X.1) and `Hashtbl` is a
  mutable structure. Exposing a `Hashtbl` in the public record type would
  violate the immutability guarantee and complicate equality checks and
  serialisation.

## Consequences

**Easier:**
- `Entry.to_yojson` uses `List.map` directly — no conversion step from map
  to list.
- Tests can pattern-match on the list literally, making assertions readable.
- Consumers can iterate fields in declaration order.

**Harder:**
- Lookup by key is O(n) via `List.assoc`. Acceptable now; if a future use
  case requires frequent key lookup, migrate to `Map` at that point.
- Duplicate-key deduplication requires an explicit pass (`dedup_fields`);
  a Map would deduplicate automatically on insertion.

**Monitoring:**
- If field counts grow significantly beyond 10 (e.g. from context propagation
  accumulating many fields), revisit this decision and file a migration ADR.
