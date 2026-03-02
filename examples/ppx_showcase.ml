open Olog

(* Demonstrates the olog_ppx extension points.

   The PPX provides [%log.LEVEL] and [%log.LEVEL_exn] which:
   - Guard with is_enabled (no allocation if level is filtered)
   - Inject compile-time source position (file, line, col)
   - Auto-wrap literal field values (strings, ints, floats, bools)

   Compare the PPX calls below with their manual equivalents in comments. *)

exception Timeout

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ()) in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.default with min_level = Level.Trace; sinks = [ sink ] }
      "ppx_demo"
  in
  (* Basic: string and int literals are auto-wrapped to Value.String / Value.Int *)
  [%log.info logger "server started" [ ("port", 8080); ("host", "0.0.0.0") ]];

  (* No fields — just a message *)
  [%log.debug logger "initializing subsystems" []];

  (* Float and bool literals *)
  [%log.trace
    logger "metrics snapshot"
      [ ("cpu_pct", 42.5); ("healthy", true); ("gpu_pct", 0.0) ]];

  (* All six levels *)
  [%log.trace logger "trace level" []];
  [%log.debug logger "debug level" []];
  [%log.info logger "info level" []];
  [%log.warn logger "warn level" []];
  [%log.error logger "error level" []];
  [%log.fatal logger "fatal level" []];

  (* Exception logging — backtrace captured automatically by the PPX *)
  (try raise Timeout
   with exn ->
     [%log.error_exn logger exn "operation timed out" [ ("timeout_ms", 5000) ]]);

  (* Polymorphic variant tags for non-literal values *)
  let latency = 123.456 in
  [%log.info
    logger "request complete"
      [ ("status", 200); ("latency_ms", `Float latency) ]];

  (* Null value *)
  [%log.info logger "user logged out" [ ("next_url", `Null) ]];

  Logger.flush logger
