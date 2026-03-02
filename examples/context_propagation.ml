open Olog

(* Demonstrates fiber-local context propagation.

   Context fields set via [Context.with_context] are automatically merged into
   every log entry within that scope. Context does NOT propagate to forked
   fibers — each fiber must establish its own context. *)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink = Output.to_sink (Output.stdout ~env ~formatter:Formatter.json ()) in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.default with sinks = [ sink ] }
      "context_demo"
  in
  (* Top-level context: request_id is attached to every log in this scope *)
  Context.with_context ~fields:[ ("request_id", Value.String "req-001") ]
  @@ fun () ->
  [%log.info logger "handling request" [ ("endpoint", "/users") ]];

  (* Nested context: user_id is added; request_id is still present *)
  Context.with_context ~fields:[ ("user_id", Value.Int 42) ] @@ fun () ->
  [%log.info logger "authorized user" []];

  (* Override: a deeper context field replaces the outer one on key collision *)
  Context.with_context ~fields:[ ("request_id", Value.String "req-002-retry") ]
  @@ fun () ->
  [%log.warn logger "retrying with new correlation id" []];

  (* Forked fiber: starts with empty context — must set its own *)
  Eio.Fiber.fork ~sw (fun () ->
      (* This log will NOT have request_id *)
      [%log.info logger "background task started" [ ("task", "cleanup") ]];

      (* Establish context explicitly for the forked fiber *)
      Context.with_context ~fields:[ ("task_id", Value.String "bg-007") ]
      @@ fun () -> [%log.info logger "background task running" []]);

  (* Back in the original fiber — request_id is still present *)
  [%log.info logger "request complete" [ ("status", 200) ]];
  Logger.flush logger
