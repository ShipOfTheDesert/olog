# ADR 0006: `Output.make` and `Output.file` use `Printf.eprintf` for fallback error reporting

**Status:** Accepted
**Date:** 2026-02-18
**RFC:** docs/rfcs/0004-output-destinations-and-formatters.md

## Context

RFC 0004 F6 requires that `Output.t.write` never propagates exceptions to the
caller. When an I/O exception occurs, "the implementation catches it and writes
one line `[olog error] <output.name>: <Printexc.to_string exn>` to the raw Eio
stderr flow, then returns."

RFC NF4 prohibits `Stdlib.open_out` and `Stdlib.out_channel` I/O for log data,
requiring `Eio.Path` / `Eio.Flow` instead. The fallback error line is not log
data — it is an internal diagnostic written to process stderr when the primary
I/O path fails.

The RFC's public interface for `Output.make` is:

```ocaml
val make : name:string -> formatter:Formatter.t -> _ Eio.Flow.sink -> t
```

There is no `env` parameter. Without `env`, there is no access to the Eio stderr
flow (`Eio.Stdenv.stderr env`).

`Output.file` similarly has no `env` that carries a usable Eio stderr flow (the
`env:_` parameter is accepted for API compatibility but is discarded — see ADR 0005).

## Decision

`Output.make` and `Output.file` use `Printf.eprintf` for the fallback error line.
The call is wrapped in `try … with _ -> ()` to prevent cascade if `eprintf` itself
fails (e.g. if fd 2 has been closed externally):

```ocaml
let write_fallback_error name exn =
  try Printf.eprintf "[olog error] %s: %s\n%!" name (Printexc.to_string exn)
  with _ -> ()
```

`Output.stdout` and `Output.stderr` — which do receive `env` — could in principle
use `Eio.Stdenv.stderr env` for the fallback. They do not do so currently; they
delegate to `Output.make`, which uses `eprintf`. This asymmetry is accepted.

## Rationale

- **`Printf.eprintf` writes to fd 2 directly.** Fd 2 (process stderr) is always
  open for the lifetime of the process in normal operation. A single short write
  to a character device is atomic on Linux (POSIX guarantees atomicity for writes
  ≤ `PIPE_BUF`). The error line is well under `PIPE_BUF` (4096 bytes).
- **No `env` threading.** Adding an `env` parameter to `Output.make` would
  complicate every call site (including `Output.stdout` and `Output.stderr`, which
  already have `env` for a different reason). The added verbosity is unjustified
  for an error-reporting side channel.
- **NF4 prohibition targets log data, not diagnostics.** NF4 exists because
  `Stdlib.out_channel` is unsafe in Eio contexts for log output — it blocks the
  OS thread and is not fiber-safe. A single short `eprintf` to fd 2 from within
  the Eio worker fiber is safe: it is not a repeated or unbounded write, and the
  OCaml runtime does not suspend between `Printf.eprintf` and the kernel write.
- **`%!` flushes immediately.** The `%!` format specifier flushes the `stderr`
  buffer to fd 2 before returning, ensuring the error line is visible even if the
  process exits immediately after.

## Alternatives Rejected

- **Add `env` to `Output.make`.** The RFC interface does not include `env`. Adding
  it is an API change that propagates to all callers. Rejected.
- **Use a global Eio stderr flow captured at library init.** Requires a module-level
  `ref` that is set before any `Output.t` is constructed — fragile and untestable.
  Rejected.
- **Swallow the error silently (no fallback).** Removes operator visibility into
  output failures entirely. Rejected: F6 explicitly requires the error line.
- **Expose a `fallback_sink` parameter on `make`.** Composable but adds complexity
  to a constructor that is already used as a building block for `stdout`/`stderr`/
  `file`. Rejected for this RFC; could be added in a future RFC without breaking
  the current interface.

## Consequences

**Easier:**
- `Output.make` signature stays minimal: name, formatter, flow. No env.
- Fallback is unconditionally available: no nil-check on an optional flow.

**Harder:**
- The fallback bypasses the Eio I/O model. In unusual process configurations
  where fd 2 is redirected to a file on a slow filesystem, `eprintf` could
  block the logger worker fiber briefly. This is an edge case with negligible
  practical impact.
- Asymmetry: `Output.stdout`/`stderr` have `env` but still use `eprintf` for
  their fallback (via `make`). A future refactor could thread the Eio stderr
  flow through `make` if this asymmetry becomes a problem.

**Monitoring:**
- If operators report missing error lines (e.g. because fd 2 was closed before
  the logger worker wrote to it), revisit this decision and consider an
  alternative fallback mechanism.
