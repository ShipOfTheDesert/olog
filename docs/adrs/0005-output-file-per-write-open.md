# ADR 0005: Output.file uses per-write `with_open_out` (no persistent handle)

**Status:** Superseded by RFC 0010
**Date:** 2026-02-18
**RFC:** docs/rfcs/0004-output-destinations-and-formatters.md

## Context

RFC 0004 F10 describes `Output.file` as a constructor that "opens the file at
`path` in append mode … using `Eio.Path.open_out ~append:true`". F12 states
"`close ()` closes the current file handle." Both requirements imply a persistent
file handle stored inside the `Output.t` closure.

In Eio 1.x, `Eio.Path.open_out` has this signature:

```ocaml
val open_out :
  ?append:bool ->
  create:[`Never | `If_missing of Unix.file_perm | `Or_truncate of Unix.file_perm | `Exclusive of Unix.file_perm] ->
  sw:Eio.Switch.t ->
  _ Eio.Path.t ->
  Eio.File.rw_ty Eio.Resource.t
```

The `~sw:Eio.Switch.t` parameter binds the file handle's lifetime to a switch.
Any code that holds an open file resource must do so within an active switch scope.

The RFC `Output.file` signature is:

```ocaml
val file :
  env:_ ->
  formatter:Formatter.t ->
  path:_ Eio.Path.t ->
  max_bytes:int ->
  unit ->
  t
```

There is no `~sw` parameter. Introducing one would change the public API from what
the RFC specifies and would require callers to supply a switch at construction time,
binding the output's lifetime to that switch. This conflicts with the intended usage
pattern where `Output.file` is passed into `Logger.Config.sinks` and the logger
manages the lifecycle.

Attempts to work around this by capturing a switch existentially (e.g. with a
first-class module or a `Eio.Switch.run` at construction time) introduce either
unsafe resource aliasing or a blocking construction call — both unacceptable.

## Decision

`Output.file` will use `Eio.Path.with_open_out` (the callback-scoped variant) on
every `write` call rather than maintaining a persistent open file handle.

```ocaml
Eio.Path.with_open_out ~append:true ~create:(`If_missing 0o644) path
  (fun flow -> List.iter (fun s -> Eio.Flow.copy_string s flow) formatted)
```

`close ()` becomes a no-op because there is no persistent resource to release.
The `.mli` documents this explicitly: `[close ()] is a no-op.`

## Rationale

- **No public API change.** The RFC signature is preserved exactly. No `~sw`
  parameter is added.
- **No lifetime hazard.** Each `with_open_out` call opens, writes, and closes
  atomically within a single `write` invocation. There is no risk of using a
  resource after its scope closes.
- **Append mode still correct.** `~append:true` is passed on every open, so
  consecutive writes accumulate in the file rather than overwriting it.
- **Rotation is unaffected.** The per-write model simplifies rotation: close is
  implicit at the end of each `with_open_out` call, so renaming the file between
  write calls is safe without an explicit close step.
- **Error handling is simpler.** Exceptions from `with_open_out` are caught by
  the existing `protect` wrapper; there is no handle to clean up on error.

## Trade-offs

**What we give up:**
- One `open`/`close` syscall pair per `write` batch (vs. one pair per logger
  lifetime with a persistent handle). For the expected write frequency of a
  logger worker fiber this overhead is negligible.
- Buffered writes. `with_open_out` uses unbuffered Eio flow I/O. Buffering would
  require an `Eio.Buf_write` layer added in a future RFC.
- RFC F12 is violated in letter: `close ()` cannot close a handle that does not
  exist. The `.mli` and this ADR document the deviation; the behaviour is
  otherwise correct.

## Alternatives Rejected

- **Add `~sw:Switch.t` to `Output.file`.** Breaks the RFC public interface and
  shifts lifetime management to the caller. Rejected.
- **`Eio.Switch.run` inside the `Output.file` constructor.** This would block at
  construction time (the switch would run until cancelled) or close immediately
  (if the run body returns). Neither is correct. Rejected.
- **Store the handle with an explicit `Eio.Cancel.protect` guard.** Unsafe: the
  handle escapes the scope that should own it; closing it from `Output.t.close`
  with no switch coordination is unsound. Rejected.

## Consequences

**Easier:**
- `Output.file` is straightforward to implement and test: no switch dependency,
  no handle lifecycle to manage.
- Rotation (rename-and-reopen) is a natural fit: each write already opens and
  closes the file independently.

**Harder:**
- High-frequency logging will pay the per-batch open/close cost. Acceptable
  for the current use case; a future buffered variant can add `~sw` and persistent
  handles behind a separate constructor (`Output.file_buffered` or similar).
- `close ()` is a no-op: operators using `Output.to_sink` must not rely on
  `Logger.sink.close` flushing pending file I/O — there is no in-process buffer
  to flush.

**Monitoring:**
- If write latency attributable to file-open syscalls becomes measurable, revisit
  this decision and file a migration ADR proposing a persistent-handle variant.
