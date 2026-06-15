open Olog

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ()) in
  let config =
    match
      Logger.Config.make ~min_level:Level.Info ~queue_depth:1024 ~sinks:[ sink ]
        ()
    with
    | Ok config -> config
    | Error msg -> failwith msg
  in
  let logger =
    match
      Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "structured"
    with
    | Ok logger -> logger
    | Error msg -> failwith msg
  in
  Context.with_context ~fields:[ ("request_id", Value.String "req-abc123") ]
  @@ fun () ->
  [%log.info logger "server started" [ ("port", 8080) ]];
  [%log.info
    logger "request received" [ ("method", "GET"); ("path", "/health") ]];
  [%log.warn
    logger "slow response" [ ("duration_ms", 523); ("threshold_ms", 500) ]];
  Logger.flush logger
