# PRD 0014 — Formatter Output Correctness

**Status:** Approved
**Author:** Miguel (miguellova@gmail.com)
**Date:** 2026-06-12
**Source:** [ANALYSIS.md](../../ANALYSIS.md) (findings 4–6)
**Companion:** PRD 0012 (logger lifecycle and accounting correctness) covers
ANALYSIS findings 1–3 and the smaller findings, and is sequenced before this
PRD.

## 1. Problem statement

ANALYSIS.md documents that every formatter can produce malformed or misleading
output. `Formatter.json` splices user fields at the top level of the JSON
object, so a field named `"level"`, `"message"`, `"timestamp"`, or `"src_pos"`
produces duplicate keys — and its shape contradicts both `Entry.to_yojson` and
the README's documented output. The logfmt and text formatters emit
user-controlled newlines raw, letting a single entry forge additional log
lines for any line-oriented consumer, and their quoting is ambiguous for
values containing backslashes. Float values are formatted with `%g`, silently
truncating to 6 significant digits. These are breaking changes to observable
output the moment anyone depends on the current format, so they must land in
the pre-release window.

## 2. Goal

Every formatter produces well-formed, unambiguous, lossless output for
arbitrary entry content, demonstrated by format→parse round-trip property
tests that would have caught the original findings. Concretely: one
syntactically valid record per entry with no duplicate keys, exactly one line
per entry regardless of message or field content, and floats that survive a
round trip unchanged.

## 3. Scenarios

- **Log-pipeline consumer (Loki/Elasticsearch/SIEM):** a request handler logs
  a user-supplied string containing a newline. Today that forges a second,
  attacker-controlled log line in logfmt/text output; after this work every
  entry is exactly one well-formed record.
- **Engineer correlating latency data:** a `duration_ms` of `12.3456789`
  currently logs as `12.3457` in logfmt/text, corrupting any downstream
  percentile computation. After this work the value round-trips exactly.

## 4. Requirements

### Functional

- **FR1 — Valid JSON with a single envelope.** `Formatter.json` must produce
  one JSON object per entry with no duplicate keys regardless of user-chosen
  field names, and its shape must be identical to `Entry.to_yojson` and the
  README's documented output. *(ANALYSIS finding 4)*
- **FR2 — One unambiguous line per entry.** The logfmt and text formatters
  must emit exactly one line per entry and remain unambiguously parseable for
  arbitrary message and field strings, including newlines, quotes, and
  backslashes. This closes the log-forging vector; the exact escaping scheme
  is an RFC decision. *(ANALYSIS finding 5)*
- **FR3 — Lossless float rendering.** Float field values must render without
  precision loss in every output format: formatting then parsing a float
  yields the original value. *(ANALYSIS finding 6)*

### Non-functional

- **NFR1 — Contracts protected by tests.** Each formatter ships with a
  format→parse round-trip property test over generated entries (arbitrary
  messages, field names, and values) in the same change. These are the tests
  ANALYSIS.md identifies as the ones that would have caught the findings.
- **NFR2 — No new runtime dependencies.** Test-only dependencies (e.g., a
  property-testing library) are acceptable; the core library's dependency set
  is unchanged.
- **NFR3 — Land before any tagged release.** All three requirements change
  observable output; they must merge before the first opam release so the
  format break has no external consumers.

## 5. Scope

**IN:**
- Output correctness for the three existing formatters: json, logfmt, text
  (FR1–FR3)
- Reconciling `Formatter.json` with `Entry.to_yojson` so there is a single
  JSON shape (see D1)
- The round-trip property tests in NFR1

**OUT OF SCOPE:**
- Logger lifecycle, accounting, and validation fixes — PRD 0012 (RFC 0013)
- User-defined formatter extensibility (`Formatter.make`) — Tier 3 roadmap
  entry
- Worker batching and the `Output.write` signature question — folded into the
  Tier 2 metrics roadmap entry

## 6. Product decisions

**D1 — JSON envelope: nested `fields` object (chosen) vs. flattened top-level
keys.**
Flattened output (current `Formatter.json`) is what some aggregators index
most easily, but it requires a reserved-key policy and collision-renaming
rules to be correct. Nesting under `"fields"` is collision-free by
construction, matches both `Entry.to_yojson` and the README's documented
output, and is the shape users were already told to expect. Chosen: nested.

## 7. Open questions

None.
