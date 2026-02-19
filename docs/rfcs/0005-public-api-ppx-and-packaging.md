# RFC 0005: Public API, PPX, and Packaging

| Field       | Value                                      |
|-------------|--------------------------------------------|
| **RFC**     | 0005                                       |
| **Title**   | Public API, PPX, and Packaging             |
| **Status**  | Accepted                                   |
| **Created** | 2026-02-18                                 |
| **Session** | 5                                          |

---

## Summary

Introduce three deliverables that complete the library's usable surface:

1. **`lib/olog.mli`** — the library's unified entry point, re-exporting `Level`, `Value`, `Entry`, `Context`, `Logger`, `Formatter`, and `Output` with a package-level doc comment.
2. **`ppx/ppx_olog.ml`** — a separate `olog_ppx` opam package that expands `[%log.LEVEL logger "msg" fields]` into a guarded `Logger.log` call with automatic source-location injection. Literal values in the fields list are auto-wrapped to `Value.*` constructors; polymorphic-variant shorthands (`` `Int ``, `` `String ``, `` `Float ``, `` `Bool ``, `` `Null ``) cover non-literal expressions. Uses `ppxlib`'s `Extension.declare` and `Ast_builder.Default` — no raw AST manipulation.
3. **`examples/`** — runnable executables invokable with `dune exec examples/NAME.exe`.

---

## Problem

After four sessions, olog has seven implementation modules but no unified entry point. Users must qualify every call (`Olog.Logger.create`, `Olog.Entry.t`, etc.) or `open` individual modules. `dune build @doc` generates HTML for each submodule but produces no landing page explaining how the modules relate — the auto-generated `Olog` wrapper has no doc comment.

There is no PPX for source-location capture. Users must manually pass `~src_pos:{file=__FILE__; line=__LINE__; col=0}` to every `Logger.log` call, which is verbose and error-prone. A PPX matches the ergonomics of industry loggers (`go-zap`, Rust's `tracing!`, Java's `log.info()`) and lets the compiler verify field types at the call site.

Source-location capture is split into a separate `olog_ppx` package: not all users want or need PPX preprocessing (batch pipelines, library authors, or projects with strict no-ppx policies can use `Logger.log` directly). A separate package avoids making `ppxlib` a mandatory runtime dependency of `olog` itself.

There are no example programs. Docs and the README cannot point users to a runnable end-to-end demonstration.

---

## Scope

### In Scope

- `lib/olog.ml` and `lib/olog.mli` — wrapper re-exporting all seven public modules
- `ppx/ppx_olog.ml` — PPX rewriter for `[%log.LEVEL]` extensions
- `ppx/dune` — `olog_ppx` library stanza with `(kind ppx_rewriter)`
- `dune-project` updated with a new `olog_ppx` package declaration; `ppxlib` runtime constraint moved from the `olog` package to `olog_ppx`
- `examples/dune` and two example executables: `basic.ml` (stdout + text formatter) and `structured.ml` (JSON formatter + context + PPX)
- `test/test_ppx.ml` — runtime integration tests for the PPX (entry count, source location, value auto-wrapping)
- `test/dune` updated to include `test_ppx` with `(preprocess (pps olog_ppx))`

### Out of Scope

- Convenience top-level functions on `Olog` (e.g., `Olog.info`) — module aliases only
- PPX syntax for `Context.with_context`
- PPX-level log filtering beyond the `is_enabled` guard
- Log sampling, rate-limiting, or deduplication in the PPX
- OCaml 4.x compatibility
- More than two examples
- CI pipeline changes

---

## Requirements

### Functional Requirements

| #   | Requirement |
|-----|-------------|
| F1  | `lib/olog.mli` has a module-level doc comment describing the library with a usage example, and exposes exactly: `module Level`, `module Value`, `module Entry`, `module Context`, `module Logger`, `module Formatter`, `module Output` as module aliases with per-module doc comments |
| F2  | `[%log.LEVEL logger_expr "message" fields_expr]` (LEVEL ∈ `{trace, debug, info, warn, error, fatal}`) expands to: `(let __olog_l = logger_expr in if Olog.Logger.is_enabled __olog_l Olog.Level.LEVEL then Olog.Logger.log __olog_l ~level:Olog.Level.LEVEL ~src_pos:{Olog.Entry.file=F; line=L; col=C} ~fields:fields_expr "message")` where F, L, C are string/int literals derived from the extension's source location at compile time |
| F3  | `fields_expr` may be omitted; when omitted the expansion uses `~fields:[]` |
| F4  | Within `fields_expr`, the PPX auto-wraps the value position of each `("key", VALUE)` pair by inspecting the AST node of `VALUE`: an OCaml int literal becomes `Olog.Value.Int`; a float literal becomes `Olog.Value.Float`; a string literal becomes `Olog.Value.String`; the identifiers `true` and `false` become `Olog.Value.Bool`; a polymorphic-variant expression `` `Int e ``, `` `String e ``, `` `Float e ``, `` `Bool e ``, or `` `Null `` becomes the corresponding `Olog.Value.*` constructor applied to `e`; any other expression is passed through unmodified and must already have type `Value.t` |
| F5  | The PPX registers each of the 6 level extensions using `Ppxlib.Extension.declare` with `Ppxlib.Extension.Context.expression`; all AST construction uses `Ppxlib.Ast_builder.Default`; no direct `Parsetree` node construction |
| F6  | `col` in the injected `src_pos` is computed as `loc.loc_start.pos_cnum - loc.loc_start.pos_bol` using ppxlib's location |
| F7  | `olog_ppx` is a separate opam package in `dune-project` with `(public_name olog_ppx)` and `(kind ppx_rewriter)` in its dune stanza; the `olog` package does not depend on `ppxlib` at runtime |
| F8  | `examples/basic.ml` creates a logger with `Output.stdout` and `Formatter.text`, logs at three levels, prints `Logger.diagnostics`, and exits 0; invokable with `dune exec examples/basic.exe` |
| F9  | `examples/structured.ml` creates a logger with `Output.stdout` and `Formatter.json`, uses `Context.with_context`, uses `[%log.info]` PPX syntax with literal values, and exits 0; invokable with `dune exec examples/structured.exe` |
| F10 | `test/test_ppx.ml` contains at least three Alcotest test cases: (a) a `[%log.info]` call on a real logger results in exactly one entry emitted, (b) the emitted entry's `src_pos` has the correct `file` field matching the test file name and `line > 0`, (c) a literal int value `42` in `fields_expr` results in a `Value.Int 42` field in the emitted entry |
| F11 | `dune build`, `dune test`, `dune build @fmt`, `dune build @doc` all pass with zero warnings |

### Non-Functional Requirements

| #   | Requirement |
|-----|-------------|
| NF1 | OCaml >= 5.2.0 |
| NF2 | `ppxlib >= 0.32` for the `olog_ppx` package |
| NF3 | `olog_ppx` declares a dependency on `olog` at `:version` in the generated opam file |
| NF4 | The `olog` package's runtime closure does not include `ppxlib` |
| NF5 | PPX rewriting is purely syntactic — no type information is required; literal detection and polymorphic-variant matching operate on AST node constructors only |
| NF6 | Example executables produce visible output to stdout and exit 0 |

---

## Public Interface

### `lib/olog.mli`

```ocaml
(** olog — structured async logging for OCaml 5 / Eio.

    This module is the library entry point. All public sub-modules are
    accessible here once the library is linked.

    Typical setup:

    {[
      open Olog

      let () = Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let sink =
          Output.to_sink
            (Output.stdout ~env ~formatter:Formatter.json ())
        in
        let logger =
          Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
            { Logger.Config.default with sinks = [ sink ] }
            "app"
        in
        Context.with_context ~fields:[ "request_id", Value.String "abc" ]
        @@ fun () ->
        Logger.log logger ~level:Level.Info "server started"
    ]}

    With the [olog_ppx] preprocessor the last call shortens to:

    {[
      [%log.info logger "server started" [("request_id", "abc")]]
    ]} *)

module Level     : module type of Level
(** Log severity levels — [Trace | Debug | Info | Warn | Error | Fatal]. *)

module Value     : module type of Value
(** Structured log field values — [String | Int | Float | Bool | Null]. *)

module Entry     : module type of Entry
(** Immutable log entry records. *)

module Context   : module type of Context
(** Fiber-local context for propagating structured fields. *)

module Logger    : module type of Logger
(** Asynchronous structured logger backed by a bounded queue. *)

module Formatter : module type of Formatter
(** Pure log entry formatters ([json], [logfmt], [text]). *)

module Output    : module type of Output
(** Output destinations: stdout, stderr, file, HTTP. *)
```

### PPX extension syntax

```ocaml
(* Literal values — auto-wrapped, no constructor needed *)
[%log.error logger "failed"    [("ok", false); ("code", 503)]]
[%log.info  logger "connected" [("host", "db.local"); ("port", 5432)]]
[%log.debug logger "timing"    [("start", 0.0)]]

(* Non-literal expressions — backtick shorthand *)
[%log.debug logger "iteration" [("i", `Int n); ("elapsed", `Float t)]]
[%log.warn  logger "slow"      [("path", `String req_path)]]

(* Two-argument form: logger, message (no fields) *)
[%log.info logger "started"]

(* Explicit Value.t — always accepted, passes through unmodified *)
[%log.info logger "data" [("v", Value.Int n)]]
```

Expansion of `[%log.error logger "failed" [("ok", false); ("code", 503)]]` at `app.ml` line 42, col 4:

```ocaml
(let __olog_l = logger in
 if Olog.Logger.is_enabled __olog_l Olog.Level.Error then
   Olog.Logger.log __olog_l
     ~level:Olog.Level.Error
     ~src_pos:{ Olog.Entry.file = "app.ml"; line = 42; col = 4 }
     ~fields:[("ok", Olog.Value.Bool false); ("code", Olog.Value.Int 503)]
     "failed")
```

### `ppx/dune`

```
(library
 (name olog_ppx)
 (public_name olog_ppx)
 (kind ppx_rewriter)
 (libraries ppxlib olog))
```

### `dune-project` addition

```
(package
 (name olog_ppx)
 (synopsis "PPX for automatic source-location injection in olog log calls")
 (description
  "Provides [%%log.LEVEL] extension points that expand to guarded Logger.log
   calls with compile-time source location and automatic Value wrapping for
   literal field values.")
 (depends
  (ppxlib (>= 0.32))
  (olog   (= :version))))
```

`ppxlib` moves from the `olog` package's `depends` to `olog_ppx` only (or remains in `olog` as `:with-test` if test infrastructure needs it).

### `examples/dune`

```
(executables
 (names basic structured)
 (libraries olog eio_main)
 (preprocess (pps olog_ppx)))
```

---

## Options Considered

### Option A: Explicit `lib/olog.ml` with module aliases — chosen

Provide `lib/olog.ml` and `lib/olog.mli` re-exporting each sub-module explicitly.

**Pros:** Explicit `.mli` gives a clear library landing page with a usage example doc comment. The entry point is inspectable — adding or removing a public module requires an intentional change. `dune build @doc` produces populated HTML for `Olog`. Works with dune's wrapped library mode without special configuration.

**Cons:** Two files to maintain; new modules require updating both.

### Option B: Rely on dune's auto-generated wrapper

Do not create `lib/olog.ml`. All modules are already accessible as `Olog.*` by dune's wrapping.

**Pros:** Zero code.

**Cons:** No doc comment at the `Olog` module level — the odoc HTML for `Olog` is empty. No explicit whitelist of public modules (any file added to `lib/` becomes public). **Rejected** — a production library requires an explicit, documented entry point.

### Option C: PPX uses `[@@deriving log]` attribute on logger bindings

`let logger = Logger.create ... [@@deriving log]` generates level-specific helpers (`log_info`, `log_debug`, …) scoped to that binding.

**Pros:** Helpers look like normal functions; IDE autocomplete works without extension syntax.

**Cons:** Requires a static `let` binding — does not compose with dynamically-chosen loggers or loggers passed as function arguments. Significantly more complex PPX (attribute on binding, not expression extension). Non-standard use of `[@@deriving]`. **Rejected.**

### Option D: Single `[%log]` extension with level as a string argument

`[%log "info" logger "msg" fields]` instead of `[%log.info logger ...]`.

**Pros:** Only one extension registration.

**Cons:** Level is a string literal — invalid level names become runtime errors, not compile-time errors; no exhaustiveness check. Worse ergonomics. **Rejected.**

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| dune conflict between explicit `lib/olog.ml` and auto-generated wrapper | Build failure | Verify with `dune build` before marking task complete; dune supports explicit wrapper modules |
| `module type of Level` in `olog.mli` becomes stale | `Olog.Level` and `Level` interfaces diverge | `module type of` always tracks the current `.mli` — no manual copying; verified by build |
| PPX literal auto-wrap silently coerces an int literal the user intended as something else | Wrong `Value.t` constructor in emitted entry | The mapping is unambiguous for the five OCaml literal kinds; document that all `("k", LITERAL)` pairs in `fields_expr` are rewritten |
| PPX backtick shorthand rewrites a polymorphic variant the user did not intend as `Value.*` | Silent misrewrite in `fields_expr` | Only rewrite the five known tags (`Int`, `String`, `Float`, `Bool`, `Null`); all other tags pass through; document reserved tags |
| `:version` opam constraint on `olog_ppx → olog` complicates dev installs | `opam install` fails when versions differ in working tree | Use `opam install . --deps-only --with-test` for development |
| `test_ppx.ml` embeds source location — fragile if lines are renumbered | Test fails on trivial refactors | Assert `src_pos.file` name and `src_pos.line > 0`; do not assert exact line number |
| odoc: doc comment in `olog.mli` uses `{!...}` cross-references to sub-modules | CI doc warning (ambiguous reference) | Use `[Olog.Level]` code spans instead of `{!Olog.Level}` for all cross-references in `olog.mli` |
| PPX qualified references (`Olog.Logger`, `Olog.Value`, …) fail if user aliases the `Olog` module | Compile error in generated code | Document this limitation; fully-qualified names are safer than unqualified |

---

## Open Questions

- **Q1**: Should the two-argument form `[%log.info logger "msg"]` be a separate `Extension.declare` registration or handled by inspecting the payload tuple length at parse time? **Proposed**: A single registration per level that pattern-matches on a 2- or 3-tuple payload; a parse error is emitted for any other arity. This avoids doubling the number of registered extensions.

- **Q2**: Should the PPX emit fully-qualified names (`Olog.Logger.is_enabled`, `Olog.Level.Info`, `Olog.Entry.file`, `Olog.Value.Int`) or unqualified names (`Logger.is_enabled`, `Level.Info`)? **Proposed**: Fully-qualified names so the PPX works regardless of whether the user has `open Olog` in scope.
