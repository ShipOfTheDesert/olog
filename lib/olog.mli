(** olog — structured async logging for OCaml 5 / Eio.

    This module is the library entry point. All public sub-modules are
    accessible here once the library is linked.

    Typical setup:

    {[
      open Olog

      let () =
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let sink =
          Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ())
        in
        let logger =
          Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
            { Logger.Config.default with sinks = [ sink ] }
            "app"
        in
        Context.with_context ~fields:[ ("request_id", Value.String "abc") ]
        @@ fun () -> Logger.log logger ~level:Level.Info "server started"
    ]}

    With the [olog_ppx] preprocessor the last call shortens to:

    {[
      [%log.info logger "server started" [ ("request_id", "abc") ]]
    ]}

    Note: [Context.with_context] fields are not yet automatically merged into
    log entries — context wiring in [Logger.log] is deferred to a future
    release. Until then, context fields must be passed explicitly via [~fields].
*)

module Level : module type of Level
(** Log severity levels — [Trace | Debug | Info | Warn | Error | Fatal]. *)

module Value : module type of Value
(** Structured log field values — [String | Int | Float | Bool | Null]. *)

module Entry : module type of Entry
(** Immutable log entry records. *)

module Context : module type of Context
(** Fiber-local context for propagating structured fields. *)

module Logger : module type of Logger
(** Asynchronous structured logger backed by a bounded queue. *)

module Formatter : module type of Formatter
(** Pure log entry formatters ([json], [logfmt], [text]). *)

module Output : module type of Output
(** Output destinations: stdout, stderr, file, HTTP. *)
