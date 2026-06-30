open Olog

(* Demonstrates exception logging with structured error fields.

   [Logger.log_exn] captures exn.name, exn.message, and exn.backtrace as
   structured fields. The PPX variant [%log.error_exn] handles backtrace
   capture automatically. *)

exception Connection_refused of string

let connect_to_database host =
  raise (Connection_refused (Printf.sprintf "refused by %s:5432" host))

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
      Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "error_demo"
    with
    | Ok logger -> logger
    | Error msg -> failwith msg
  in
  (* Manual exception logging with Logger.log_exn *)
  (try connect_to_database "db.prod.internal"
   with exn ->
     let bt = Printexc.get_raw_backtrace () in
     Logger.log_exn logger ~level:Level.Error exn bt
       "database connection failed"
       ~fields:
         [ ("host", Value.string "db.prod.internal"); ("attempt", Value.int 1) ]);

  (* PPX variant — backtrace capture is automatic *)
  (try connect_to_database "db.replica.internal"
   with exn ->
     [%log.error_exn
       logger exn "replica connection failed"
         [ ("host", "db.replica.internal"); ("attempt", 2) ]]);

  Logger.flush logger
