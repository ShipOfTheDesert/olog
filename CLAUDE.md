# olog

Production-grade structured async logging for Eio-based OCaml 5 applications.
See CONTRIBUTING.md for the coding principles (Articles I–X) and PR workflow,
and ROADMAP.md for the tiered plan.

## Mandatory Reading

- CONTRIBUTING.md — coding principles (Articles I–X) and PR workflow.
- ROADMAP.md — the tiered plan.
- docs/adrs/0015-workflow-migration-to-feature-docs.md — the active planning
  workflow: one feature doc in docs/features/, not a PRD+RFC pair.

## Current State

- Active feature doc: docs/features/ (the single planning + design document;
  none open yet — the lifecycle/accounting work is the last under the legacy
  PRD/RFC workflow). See docs/adrs/0015-workflow-migration-to-feature-docs.md.
- Legacy in-flight: docs/prds/0012 + docs/rfcs/0013 (Logger Lifecycle and
  Accounting Correctness, Task 6/6) — historical context, not the active doc.
- Queued: docs/prds/0014-formatter-output-correctness.md — to be replanned as a
  feature doc under docs/features/ when picked up.

## Conventions

- The active planning/design document is a single feature doc at
  docs/features/NNNN-*.md (Part 1 requirements, frozen after approval; Part 2
  implementation plan, amendable). It replaces the legacy split PRD
  (docs/prds/) + RFC (docs/rfcs/) workflow. See
  docs/adrs/0015-workflow-migration-to-feature-docs.md. docs/prds/ and
  docs/rfcs/ are historical — read for context, never as the active document.
- docs/features/, docs/prds/, docs/rfcs/, and docs/adrs/ share one numbering
  sequence: the next document number is the highest existing number across all
  four directories plus one.
- ANALYSIS.md (root) is the 2026-06-11 architecture and implementation
  analysis that the lifecycle/accounting and formatter-output work address.
