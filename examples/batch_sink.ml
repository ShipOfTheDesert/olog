open Olog

(* Demonstrates implementing the Logger.sink record directly, without an
   Output.t wrapper.

   A sink's emit receives entries in batches (Entry.t list): the worker
   delivers every consecutively queued entry in one call, so a custom sink can
   amortise per-write costs — one syscall, one network request, one database
   transaction — across the whole batch.

   This sink prints a header per batch and one text-formatted line per entry.
   The three entries below are logged back-to-back with no suspension point
   between them, so the worker's greedy drain delivers them as one batch. *)

let batch_printing_sink : Logger.sink =
  {
    Logger.name = "batch-printer";
    emit =
      (fun entries ->
        Printf.printf "--- batch of %d entries ---\n" (List.length entries);
        List.iter (fun entry -> print_string (Formatter.text entry)) entries;
        Ok ());
    flush =
      (fun () ->
        print_string "--- flush ---\n";
        Ok ());
    close =
      (fun () ->
        print_string "--- close ---\n";
        Ok ());
  }

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    match
      Logger.Config.make ~min_level:Level.Info ~queue_depth:1024
        ~sinks:[ batch_printing_sink ] ()
    with
    | Ok config -> config
    | Error msg -> failwith msg
  in
  let logger =
    match
      Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "batch_sink_demo"
    with
    | Ok logger -> logger
    | Error msg -> failwith msg
  in
  [%log.info logger "request received" [ ("path", "/health") ]];
  [%log.info logger "request authorised" [ ("user_id", 42) ]];
  [%log.warn logger "slow response" [ ("duration_ms", 523) ]];
  Logger.shutdown logger
