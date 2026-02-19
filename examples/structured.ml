open Olog

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ()) in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.default with sinks = [ sink ] }
      "structured"
  in
  (* FUTURE: context wiring in Logger.log is deferred to a later session.
     When wired, the request_id field will appear automatically in every log
     entry emitted inside this block without being listed in [fields]. *)
  Context.with_context ~fields:[ ("request_id", Value.String "req-abc123") ]
  @@ fun () ->
  [%log.info logger "server started" [ ("port", 8080) ]];
  [%log.info
    logger "request received" [ ("method", "GET"); ("path", "/health") ]];
  [%log.warn
    logger "slow response" [ ("duration_ms", 523); ("threshold_ms", 500) ]];
  Logger.flush logger
