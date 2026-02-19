open Olog

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.text ()) in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.default with sinks = [ sink ] }
      "basic"
  in
  Logger.log logger ~level:Level.Info "server starting";
  Logger.log logger ~level:Level.Warn "low disk space"
    ~fields:[ ("free_mb", Value.Int 42) ];
  Logger.log logger ~level:Level.Error "connection failed"
    ~fields:[ ("host", Value.String "db.local") ];
  Logger.flush logger;
  let d = Logger.diagnostics logger in
  Printf.printf "diagnostics: name=%s queue_depth=%d drop_count=%d\n" d.name
    d.queue_depth d.drop_count
