open Olog

(* Demonstrates writing to a custom Eio flow using Output.make.

   Output.make accepts any Eio.Flow.sink, so you can write logs to buffers,
   pipes, network sockets, or any other Eio-compatible destination.

   This example writes JSON logs to an in-memory buffer, then prints the
   buffer contents — useful for testing or capturing logs programmatically. *)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* Create an in-memory buffer sink *)
  let buf = Buffer.create 1024 in
  let buf_sink = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"buffer" ~formatter:Formatter.json buf_sink in
  let sink = Output.to_sink output in

  (* Also log to stderr with human-readable text format *)
  let stderr_sink =
    Output.to_sink (Output.stderr ~env ~formatter:Formatter.text ())
  in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.default with sinks = [ sink; stderr_sink ] }
      "custom_output_demo"
  in
  [%log.info logger "event one" [ ("key", "value") ]];
  [%log.warn logger "event two" [ ("count", 42) ]];
  Logger.flush logger;

  (* Print what was captured in the buffer *)
  Printf.printf "\n--- captured buffer (%d bytes) ---\n%s" (Buffer.length buf)
    (Buffer.contents buf)
