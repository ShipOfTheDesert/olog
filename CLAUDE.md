# olog

Production-grade structured async logging for Eio-based OCaml 5 applications.
See CONTRIBUTING.md for the coding principles (Articles I–X) and PR workflow,
and ROADMAP.md for the tiered plan.

## Current State

- Active PRD: docs/prds/0012-logger-lifecycle-and-accounting-correctness.md
- Active RFC: docs/rfcs/0013-logger-lifecycle-and-accounting-correctness.md
- Current Focus: Implementing Logger Lifecycle and Accounting Correctness - Task 6/6
- Queued: docs/prds/0014-formatter-output-correctness.md (sequenced after PRD 0012)

## Conventions

- docs/prds/, docs/rfcs/, and docs/adrs/ share one numbering sequence: the
  next document number is the highest existing number across all three
  directories plus one. A PRD additionally reserves the number immediately
  after its own for its RFC, so a PRD and its RFC are always adjacent
  (PRD 0012 → RFC 0013, PRD 0014 → RFC 0015).
- Each PRD maps to exactly one RFC, which maps to roughly one PR.
- ANALYSIS.md (root) is the 2026-06-11 architecture and implementation
  analysis that PRDs 0012 and 0014 address.
