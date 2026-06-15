open Olog

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.text ()) in
  let config =
    match
      Logger.Config.make ~min_level:Level.Info ~queue_depth:1024 ~sinks:[ sink ]
        ()
    with
    | Ok config -> config
    | Error msg -> failwith msg
  in
  let logger =
    match Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "basic" with
    | Ok logger -> logger
    | Error msg -> failwith msg
  in
  Logger.log logger ~level:Level.Info "server starting";
  Logger.log logger ~level:Level.Warn "low disk space"
    ~fields:[ ("free_mb", Value.Int 42) ];
  Logger.log logger ~level:Level.Error "connection failed"
    ~fields:[ ("host", Value.String "db.local") ];
  Logger.flush logger;
  let d = Logger.diagnostics logger in
  Printf.printf
    "diagnostics: name=%s queue_depth=%d drop_count=%d is_shutdown=%b\n" d.name
    d.queue_depth d.drop_count d.is_shutdown
