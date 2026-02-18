(* ── Group 1: Config ─────────────────────────────────────────────────────── *)

(* F3 *)
let test_config_default_min_level () =
  Alcotest.(check bool)
    "default min_level is Info" true
    (Olog.Level.equal Olog.Logger.Config.default.min_level Olog.Level.Info)

(* F3 *)
let test_config_default_queue_depth () =
  Alcotest.(check int)
    "default queue_depth is 1024" 1024 Olog.Logger.Config.default.queue_depth

(* F3 *)
let test_config_default_sinks () =
  Alcotest.(check bool)
    "default sinks is empty list" true
    (Olog.Logger.Config.default.sinks = [])

(* ── Group 2: is_enabled ─────────────────────────────────────────────────── *)

(* F8 — config.min_level = Info; Info >= Info → true *)
let test_is_enabled_at_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "test"
      in
      Alcotest.(check bool)
        "true when level equals min_level" true
        (Olog.Logger.is_enabled logger Olog.Level.Info))

(* F8 — Error > Info → true *)
let test_is_enabled_above_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "test"
      in
      Alcotest.(check bool)
        "true when level exceeds min_level" true
        (Olog.Logger.is_enabled logger Olog.Level.Error))

(* F8 — Debug < Info → false *)
let test_is_enabled_below_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "test"
      in
      Alcotest.(check bool)
        "false when level is below min_level" false
        (Olog.Logger.is_enabled logger Olog.Level.Debug))

(* ── Group 3: create + diagnostics ──────────────────────────────────────── *)

(* F5, F15 *)
let test_create_drop_count_zero () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "test"
      in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int) "drop_count is zero after create" 0 diag.drop_count)

(* F5, F15 *)
let test_create_name_in_diagnostics () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "my-logger"
      in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check string)
        "name matches in diagnostics" "my-logger" diag.name)

(* F5, F15 *)
let test_create_queue_capacity () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let config = { Olog.Logger.Config.default with queue_depth = 64 } in
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int)
        "queue_capacity matches config" 64 diag.queue_capacity)

(* F15 *)
let test_create_queue_depth_zero () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        Olog.Logger.create ~sw ~clock:env#clock Olog.Logger.Config.default
          "test"
      in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int) "queue_depth is zero after create" 0 diag.queue_depth)

(* ── Group 4: log level guard ────────────────────────────────────────────── *)

(* F9 — entry below min_level must not reach sink *)
let test_log_below_min_no_emit () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    {
      Olog.Logger.Config.default with
      min_level = Olog.Level.Info;
      sinks = [ sink ];
    }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Debug "below min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log below min_level does not call sink emit" 0 !emitted

(* F9 — drop_count must not increment for filtered entries *)
let test_log_below_min_no_drop () =
  Eio_main.run @@ fun env ->
  let drop_count_after = ref (-1) in
  let config =
    { Olog.Logger.Config.default with min_level = Olog.Level.Info }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Debug "below min";
      Olog.Logger.flush logger;
      drop_count_after := (Olog.Logger.diagnostics logger).drop_count);
  Alcotest.(check int)
    "log below min_level does not increment drop_count" 0 !drop_count_after

(* F10, F12 — entry at min_level must be dispatched to sink *)
let test_log_at_min_emits () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    {
      Olog.Logger.Config.default with
      min_level = Olog.Level.Info;
      sinks = [ sink ];
    }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "at min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log at min_level emits entry after flush" 1 !emitted

(* F10, F12 — entry above min_level must be dispatched to sink *)
let test_log_above_min_emits () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    {
      Olog.Logger.Config.default with
      min_level = Olog.Level.Info;
      sinks = [ sink ];
    }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Error "above min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log above min_level emits entry after flush" 1 !emitted

(* ── Group 5: multi-sink dispatch + error isolation ─────────────────────── *)

(* F12 — worker calls each sink in list order for every entry *)
let test_log_emits_to_each_sink () =
  Eio_main.run @@ fun env ->
  let order = ref [] in
  let make_sink id : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> order := id :: !order);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    { Olog.Logger.Config.default with sinks = [ make_sink 1; make_sink 2 ] }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger);
  (* Called in list order 1 then 2; prepended so reversed *)
  Alcotest.(check (list int))
    "entry emitted to each sink in order" [ 1; 2 ] (List.rev !order)

(* F13 — sink emit raising must not stop dispatch to subsequent sinks *)
let test_log_continues_after_sink_raise () =
  Eio_main.run @@ fun env ->
  let second_emitted = ref 0 in
  let raising_sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> raise Exit);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let counting_sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr second_emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    { Olog.Logger.Config.default with sinks = [ raising_sink; counting_sink ] }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "worker continues after sink emit raises" 1 !second_emitted

(* F13 — sink raising on one entry must not stop processing of the next *)
let test_log_next_entry_after_raise () =
  Eio_main.run @@ fun env ->
  let call_count = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit =
        (fun _ ->
          incr call_count;
          if !call_count = 1 then raise Exit);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "first";
      Olog.Logger.log logger ~level:Olog.Level.Info "second";
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "subsequent entries emitted after sink error" 2 !call_count

(* ── Group 6: drop semantics ─────────────────────────────────────────────── *)

(* F11 — drop_count increments once per dropped entry *)
let test_drop_count_increments () =
  Eio_main.run @@ fun env ->
  let drop_count_snapshot = ref 0 in
  let latch, release = Eio.Promise.create () in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> Eio.Promise.await latch);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    { Olog.Logger.Config.default with queue_depth = 1; sinks = [ sink ] }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      (* entry-1: worker takes it and blocks inside sink.emit *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-1";
      Eio.Fiber.yield ();
      (* entry-2: fills the queue (capacity = 1, worker still blocked) *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-2";
      (* entry-3 and entry-4: both should be dropped *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-3";
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-4";
      drop_count_snapshot := (Olog.Logger.diagnostics logger).drop_count;
      Eio.Promise.resolve release ();
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "drop_count increments when queue is full" 2 !drop_count_snapshot

(* F11 — log must return without suspending when the queue is full.
   Proof by deadlock-prevention: worker is blocked in sink.emit (awaiting
   latch) and queue is full. If Logger.log were to call Eio.Stream.add
   (blocking), neither the current fiber nor the worker could make progress
   — the test would hang. Completion proves non-suspension. *)
let test_log_does_not_suspend () =
  Eio_main.run @@ fun env ->
  let latch, release = Eio.Promise.create () in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> Eio.Promise.await latch);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config =
    { Olog.Logger.Config.default with queue_depth = 1; sinks = [ sink ] }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      (* entry-1: worker takes it and blocks in sink.emit *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-1";
      Eio.Fiber.yield ();
      (* entry-2: fills the queue *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-2";
      (* entry-3: queue is full — must drop without suspending *)
      Olog.Logger.log logger ~level:Olog.Level.Info "entry-3";
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int)
        "log returns without suspending when queue is full" 1 diag.drop_count;
      Eio.Promise.resolve release ();
      Olog.Logger.flush logger)

(* ── Group 7: flush ──────────────────────────────────────────────────────── *)

(* F14 — flush blocks until all preceding entries have been emitted *)
let test_flush_waits_for_entries () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      for _ = 1 to 5 do
        Olog.Logger.log logger ~level:Olog.Level.Info "msg"
      done;
      Olog.Logger.flush logger;
      Alcotest.(check int)
        "flush waits until enqueued entries are processed" 5 !emitted)

(* F14 — flush calls sink.flush for each sink after entries are emitted *)
let test_flush_calls_sink_flush () =
  Eio_main.run @@ fun env ->
  let flushed = ref false in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> flushed := true);
      close = (fun () -> ());
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger;
      Alcotest.(check bool) "flush calls sink flush for each sink" true !flushed)

(* sink.flush raising must not prevent the flush promise from resolving *)
let test_flush_sink_raise_does_not_hang () =
  Eio_main.run @@ fun env ->
  let second_flushed = ref false in
  let raising_sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> raise Exit);
      close = (fun () -> ());
    }
  in
  let counting_sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> second_flushed := true);
      close = (fun () -> ());
    }
  in
  let config =
    { Olog.Logger.Config.default with sinks = [ raising_sink; counting_sink ] }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      (* flush must return even though the first sink's flush raises *)
      Olog.Logger.flush logger;
      Alcotest.(check bool)
        "flush returns and continues to next sink after sink flush raises" true
        !second_flushed)

(* ── Group 8: sink close on shutdown ────────────────────────────────────── *)

(* F7 — sink.close is called when the enclosing switch closes *)
let test_close_called_on_switch_close () =
  Eio_main.run @@ fun env ->
  let closed = ref false in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> ());
      close = (fun () -> closed := true);
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  Eio.Switch.run (fun sw ->
      let _logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      ());
  Alcotest.(check bool) "sink close called when switch closes" true !closed

(* F7 — exceptions from sink.close must not propagate out of the worker *)
let test_close_exception_ignored () =
  Eio_main.run @@ fun env ->
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> ());
      close = (fun () -> raise Exit);
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  (* If the exception propagates, Switch.run raises and the test fails *)
  Eio.Switch.run (fun sw ->
      let _logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      ())

(* F7 — sinks are closed in the order they appear in config.sinks *)
let test_close_in_list_order () =
  Eio_main.run @@ fun env ->
  let order = ref [] in
  let make_sink n : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> ());
      close = (fun () -> order := n :: !order);
    }
  in
  let config =
    {
      Olog.Logger.Config.default with
      sinks = [ make_sink 1; make_sink 2; make_sink 3 ];
    }
  in
  Eio.Switch.run (fun sw ->
      let _logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      ());
  Alcotest.(check (list int))
    "sinks closed in list order" [ 1; 2; 3 ] (List.rev !order)

(* ── Group 9: concurrency ────────────────────────────────────────────────── *)

(* F16 — concurrent log calls from multiple fibers must all be emitted *)
let test_concurrent_log_all_emitted () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> incr emitted);
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let n_fibers = 5 in
  let n_entries = 10 in
  let config =
    {
      Olog.Logger.Config.default with
      queue_depth = n_fibers * n_entries;
      sinks = [ sink ];
    }
  in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Eio.Fiber.all
        (List.init n_fibers (fun _ ->
             fun () ->
              for _ = 1 to n_entries do
                Olog.Logger.log logger ~level:Olog.Level.Info "concurrent"
              done));
      Olog.Logger.flush logger;
      Alcotest.(check int)
        "concurrent log calls from multiple fibers all emitted"
        (n_fibers * n_entries) !emitted)

(* F16 — diagnostics must be safe to call concurrently with log *)
let test_diagnostics_concurrent () =
  Eio_main.run @@ fun env ->
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.emit = (fun _ -> ());
      flush = (fun () -> ());
      close = (fun () -> ());
    }
  in
  let config = { Olog.Logger.Config.default with sinks = [ sink ] } in
  Eio.Switch.run (fun sw ->
      let logger = Olog.Logger.create ~sw ~clock:env#clock config "test" in
      Eio.Fiber.both
        (fun () ->
          for _ = 1 to 50 do
            Olog.Logger.log logger ~level:Olog.Level.Info "concurrent";
            Eio.Fiber.yield ()
          done)
        (fun () ->
          for _ = 1 to 50 do
            let _diag = Olog.Logger.diagnostics logger in
            Eio.Fiber.yield ()
          done);
      Olog.Logger.flush logger)

(* ── runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Logger"
    [
      ( "Config",
        [
          Alcotest.test_case "default min_level is Info" `Quick
            test_config_default_min_level;
          Alcotest.test_case "default queue_depth is 1024" `Quick
            test_config_default_queue_depth;
          Alcotest.test_case "default sinks is empty list" `Quick
            test_config_default_sinks;
        ] );
      ( "is_enabled",
        [
          Alcotest.test_case "true when level equals min_level" `Quick
            test_is_enabled_at_min_level;
          Alcotest.test_case "true when level exceeds min_level" `Quick
            test_is_enabled_above_min_level;
          Alcotest.test_case "false when level is below min_level" `Quick
            test_is_enabled_below_min_level;
        ] );
      ( "create",
        [
          Alcotest.test_case "drop_count is zero after create" `Quick
            test_create_drop_count_zero;
          Alcotest.test_case "name matches in diagnostics" `Quick
            test_create_name_in_diagnostics;
          Alcotest.test_case "queue_capacity matches config" `Quick
            test_create_queue_capacity;
          Alcotest.test_case "queue_depth is zero after create" `Quick
            test_create_queue_depth_zero;
        ] );
      ( "log",
        [
          Alcotest.test_case "log below min_level does not call sink emit"
            `Quick test_log_below_min_no_emit;
          Alcotest.test_case "log below min_level does not increment drop_count"
            `Quick test_log_below_min_no_drop;
          Alcotest.test_case "log at min_level emits entry after flush" `Quick
            test_log_at_min_emits;
          Alcotest.test_case "log above min_level emits entry after flush"
            `Quick test_log_above_min_emits;
        ] );
      ( "multi-sink",
        [
          Alcotest.test_case "entry emitted to each sink in order" `Quick
            test_log_emits_to_each_sink;
          Alcotest.test_case "worker continues after sink emit raises" `Quick
            test_log_continues_after_sink_raise;
          Alcotest.test_case "subsequent entries emitted after sink error"
            `Quick test_log_next_entry_after_raise;
        ] );
      ( "drop",
        [
          Alcotest.test_case "drop_count increments when queue is full" `Quick
            test_drop_count_increments;
          Alcotest.test_case "log returns without suspending when queue is full"
            `Quick test_log_does_not_suspend;
        ] );
      ( "flush",
        [
          Alcotest.test_case "flush waits until enqueued entries are processed"
            `Quick test_flush_waits_for_entries;
          Alcotest.test_case "flush calls sink flush for each sink" `Quick
            test_flush_calls_sink_flush;
          Alcotest.test_case
            "flush returns and continues to next sink after sink flush raises"
            `Quick test_flush_sink_raise_does_not_hang;
        ] );
      ( "close",
        [
          Alcotest.test_case "sink close called when switch closes" `Quick
            test_close_called_on_switch_close;
          Alcotest.test_case "sink close exception caught and ignored" `Quick
            test_close_exception_ignored;
          Alcotest.test_case "sinks closed in list order" `Quick
            test_close_in_list_order;
        ] );
      ( "concurrency",
        [
          Alcotest.test_case
            "concurrent log calls from multiple fibers all emitted" `Quick
            test_concurrent_log_all_emitted;
          Alcotest.test_case "diagnostics safe to call concurrently with log"
            `Quick test_diagnostics_concurrent;
        ] );
    ]
