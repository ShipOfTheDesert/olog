(* ── Group 1: Config ─────────────────────────────────────────────────────── *)

(* F4 — Config.make validates queue_depth >= 1 (RFC 0013) *)
let test_config_make_rejects_nonpositive_queue_depth () =
  let is_error = function Ok _ -> false | Error _ -> true in
  Alcotest.(check bool)
    "queue_depth 0 is rejected" true
    (is_error
       (Olog.Logger.Config.make ~min_level:Olog.Level.Info ~queue_depth:0
          ~sinks:[] ()));
  Alcotest.(check bool)
    "queue_depth -1 is rejected" true
    (is_error
       (Olog.Logger.Config.make ~min_level:Olog.Level.Info ~queue_depth:(-1)
          ~sinks:[] ()));
  Alcotest.(check bool)
    "queue_depth 1 is accepted" false
    (is_error
       (Olog.Logger.Config.make ~min_level:Olog.Level.Info ~queue_depth:1
          ~sinks:[] ()))

(* Test helpers. [Config.make] and [create] now return results; in these
   fixtures the inputs are statically valid, so any [Error] is a programmer
   error in the test itself — surface it loudly with its diagnostic message. *)
let make_config ?(min_level = Olog.Level.Info) ?(queue_depth = 1024)
    ?(sinks = []) ?timestamp_fallback () =
  match
    Olog.Logger.Config.make ~min_level ~queue_depth ~sinks ?timestamp_fallback
      ()
  with
  | Ok config -> config
  | Error msg -> Alcotest.failf "Config.make: %s" msg

let make_logger ~sw ~clock config name =
  match Olog.Logger.create ~sw ~clock config name with
  | Ok logger -> logger
  | Error msg -> Alcotest.failf "Logger.create: %s" msg

(* A clock whose current reading is a mutable [float ref], so a test can make
   it "break" — return a value [Ptime.of_float_s] rejects (NaN / out of range)
   — at a chosen moment. Self-contained via [Eio.Time.Pi]: no dependency on
   eio.mock and full control over the exact reading. *)
module Mock_clock = struct
  type t = float ref
  type time = float

  let now (r : t) = !r
  let sleep_until _ _ = ()
end

let mock_clock (r : float ref) : _ Eio.Time.clock =
  Eio.Resource.T
    ( r,
      Eio.Time.Pi.clock
        (module Mock_clock : Eio.Time.Pi.CLOCK
          with type t = float ref
           and type time = float) )

(* Most test sinks perform a side effect and succeed; [mk_sink] wraps the
   effectful callbacks so each returns [Ok ()] under the result contract
   (RFC 0013). The [emit] callback is per-entry: it is applied to each entry
   of the batch in order, so counting/capturing tests stay batch-size
   agnostic. A raising callback still raises (it never reaches [Ok ()]),
   which is exactly what the contract-violation tests need. Tests that must
   return [Error] or see the whole batch construct the record directly. *)
let mk_sink ?(name = "test") ?(emit = fun _ -> ()) ?(flush = fun () -> ())
    ?(close = fun () -> ()) () : Olog.Logger.sink =
  {
    Olog.Logger.name;
    emit =
      (fun entries ->
        List.iter emit entries;
        Ok ());
    flush =
      (fun () ->
        flush ();
        Ok ());
    close =
      (fun () ->
        close ();
        Ok ());
  }

(* Capture everything written to process [stderr] (fd 2) while [f] runs, by
   redirecting the fd to a temp file and reading it back. [report_sink_error]
   writes its fallback line through [Printf.eprintf] — raw fd 2 by design
   (ADR 0006), not an Eio flow — so asserting on it means capturing the fd. *)
let capture_stderr f =
  flush stderr;
  let tmp = Filename.temp_file "olog_stderr" ".txt" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY ] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Fun.protect
    ~finally:(fun () ->
      flush stderr;
      Unix.dup2 saved Unix.stderr;
      Unix.close saved;
      Unix.close fd)
    f;
  let content = In_channel.with_open_bin tmp In_channel.input_all in
  Sys.remove tmp;
  content

let string_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec at i =
    i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1))
  in
  nl = 0 || at 0

let count_occurrences ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec at i acc =
    if i + nl > hl then acc
    else if String.sub haystack i nl = needle then at (i + nl) (acc + 1)
    else at (i + 1) acc
  in
  if nl = 0 then 0 else at 0 0

(* ── Group 2: is_enabled ─────────────────────────────────────────────────── *)

(* F8 — config.min_level = Info; Info >= Info → true *)
let test_is_enabled_at_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock (make_config ()) "test" in
      Alcotest.(check bool)
        "true when level equals min_level" true
        (Olog.Logger.is_enabled logger Olog.Level.Info))

(* F8 — Error > Info → true *)
let test_is_enabled_above_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock (make_config ()) "test" in
      Alcotest.(check bool)
        "true when level exceeds min_level" true
        (Olog.Logger.is_enabled logger Olog.Level.Error))

(* F8 — Debug < Info → false *)
let test_is_enabled_below_min_level () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock (make_config ()) "test" in
      Alcotest.(check bool)
        "false when level is below min_level" false
        (Olog.Logger.is_enabled logger Olog.Level.Debug))

(* ── Group 3: create + diagnostics ──────────────────────────────────────── *)

(* F5, F15 *)
let test_create_drop_count_zero () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock (make_config ()) "test" in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int) "drop_count is zero after create" 0 diag.drop_count)

(* F5, F15 *)
let test_create_name_in_diagnostics () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger =
        make_logger ~sw ~clock:env#clock (make_config ()) "my-logger"
      in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check string)
        "name matches in diagnostics" "my-logger" diag.name)

(* F5, F15 *)
let test_create_queue_capacity () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let config = make_config ~queue_depth:64 () in
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int)
        "queue_capacity matches config" 64 diag.queue_capacity)

(* F15 *)
let test_create_queue_depth_zero () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock (make_config ()) "test" in
      let diag = Olog.Logger.diagnostics logger in
      Alcotest.(check int) "queue_depth is zero after create" 0 diag.queue_depth)

(* ── Group 4: log level guard ────────────────────────────────────────────── *)

(* F9 — entry below min_level must not reach sink *)
let test_log_below_min_no_emit () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~min_level:Olog.Level.Info ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Debug "below min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log below min_level does not call sink emit" 0 !emitted

(* F9 — drop_count must not increment for filtered entries *)
let test_log_below_min_no_drop () =
  Eio_main.run @@ fun env ->
  let drop_count_after = ref (-1) in
  let config = make_config ~min_level:Olog.Level.Info () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Debug "below min";
      Olog.Logger.flush logger;
      drop_count_after := (Olog.Logger.diagnostics logger).drop_count);
  Alcotest.(check int)
    "log below min_level does not increment drop_count" 0 !drop_count_after

(* F10, F12 — entry at min_level must be dispatched to sink *)
let test_log_at_min_emits () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~min_level:Olog.Level.Info ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "at min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log at min_level emits entry after flush" 1 !emitted

(* F10, F12 — entry above min_level must be dispatched to sink *)
let test_log_above_min_emits () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~min_level:Olog.Level.Info ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Error "above min";
      Olog.Logger.flush logger);
  Alcotest.(check int) "log above min_level emits entry after flush" 1 !emitted

(* ── Group 5: multi-sink dispatch + error isolation ─────────────────────── *)

(* F12 — worker calls each sink in list order for every entry *)
let test_log_emits_to_each_sink () =
  Eio_main.run @@ fun env ->
  let order = ref [] in
  let make_sink id = mk_sink ~emit:(fun _ -> order := id :: !order) () in
  let config = make_config ~sinks:[ make_sink 1; make_sink 2 ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger);
  (* Called in list order 1 then 2; prepended so reversed *)
  Alcotest.(check (list int))
    "entry emitted to each sink in order" [ 1; 2 ] (List.rev !order)

(* F13 — sink emit raising must not stop dispatch to subsequent sinks *)
let test_log_continues_after_sink_raise () =
  Eio_main.run @@ fun env ->
  let second_emitted = ref 0 in
  let raising_sink = mk_sink ~emit:(fun _ -> raise Exit) () in
  let counting_sink = mk_sink ~emit:(fun _ -> incr second_emitted) () in
  let config = make_config ~sinks:[ raising_sink; counting_sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "worker continues after sink emit raises" 1 !second_emitted

(* F13 — sink raising on one entry must not stop processing of the next. The
   yield between the logs lets the worker take each entry as its own batch, so
   the raise lands on one delivery and the assertion counts the next. *)
let test_log_next_entry_after_raise () =
  Eio_main.run @@ fun env ->
  let call_count = ref 0 in
  let sink =
    mk_sink
      ~emit:(fun _ ->
        incr call_count;
        if !call_count = 1 then raise Exit)
      ()
  in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "first";
      Eio.Fiber.yield ();
      Olog.Logger.log logger ~level:Olog.Level.Info "second";
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "subsequent entries emitted after sink error" 2 !call_count

(* F3 — a sink that returns [Error] on one delivery must not halt delivery of
   subsequent entries (the result-value failure path, distinct from a raise).
   Yields between the logs pin one entry per batch so each delivery is its own
   [emit] call; multi-entry batch failure is covered by
   [test_batch_write_error_continues]. *)
let test_sink_emit_error_does_not_stop_worker () =
  Eio_main.run @@ fun env ->
  let call_count = ref 0 in
  let erroring_sink : Olog.Logger.sink =
    {
      Olog.Logger.name = "erroring";
      emit =
        (fun _ ->
          incr call_count;
          if !call_count = 1 then Error "intentional emit error" else Ok ());
      flush = (fun () -> Ok ());
      close = (fun () -> Ok ());
    }
  in
  let config = make_config ~sinks:[ erroring_sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "first";
      Eio.Fiber.yield ();
      Olog.Logger.log logger ~level:Olog.Level.Info "second";
      Eio.Fiber.yield ();
      Olog.Logger.log logger ~level:Olog.Level.Info "third";
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "worker keeps dispatching after a sink returns Error" 3 !call_count

(* F3 — a contract-violating sink (one that raises instead of returning a
   result) must not kill the worker; entries logged after the raise are still
   delivered. Yields between the logs pin one entry per batch so the raise on
   the first delivery leaves four later deliveries to count. *)
let test_contract_violating_sink_does_not_stop_worker () =
  Eio_main.run @@ fun env ->
  let call_count = ref 0 in
  let raising_sink : Olog.Logger.sink =
    {
      Olog.Logger.name = "raising";
      emit =
        (fun _ ->
          incr call_count;
          if !call_count = 1 then raise Exit else Ok ());
      flush = (fun () -> Ok ());
      close = (fun () -> Ok ());
    }
  in
  let config = make_config ~sinks:[ raising_sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      for _ = 1 to 5 do
        Olog.Logger.log logger ~level:Olog.Level.Info "msg";
        Eio.Fiber.yield ()
      done;
      Olog.Logger.flush logger);
  Alcotest.(check int)
    "worker survives a raising sink and delivers later entries" 5 !call_count

(* F3 — a sink failure is not merely swallowed: the worker emits an
   operator-facing fallback line to process stderr ([report_sink_error],
   ADR 0006 semantics) naming the failing sink and its message. Capture fd 2
   and assert the diagnostic is actually produced — the [Error]-continues
   behaviour is covered elsewhere; this pins the visible diagnostic itself. *)
let test_sink_error_reports_fallback_line_to_stderr () =
  let output =
    capture_stderr (fun () ->
        Eio_main.run @@ fun env ->
        let erroring_sink : Olog.Logger.sink =
          {
            Olog.Logger.name = "broken-sink";
            emit = (fun _ -> Error "disk full");
            flush = (fun () -> Ok ());
            close = (fun () -> Ok ());
          }
        in
        let config = make_config ~sinks:[ erroring_sink ] () in
        Eio.Switch.run (fun sw ->
            let logger = make_logger ~sw ~clock:env#clock config "test" in
            Olog.Logger.log logger ~level:Olog.Level.Info "msg";
            Olog.Logger.flush logger))
  in
  Alcotest.(check bool)
    "stderr fallback names the failing sink" true
    (string_contains ~needle:"broken-sink" output);
  Alcotest.(check bool)
    "stderr fallback includes the sink's error message" true
    (string_contains ~needle:"disk full" output)

(* FR2, ADR 0007 (Feature 0018) — batch failure granularity: a sink [Error]
   covers the whole batch, is reported to stderr exactly once, and the worker
   continues with later entries — the failed batch is not retried. The sink
   consumes its argument as a list, pinning the batch-shaped contract. *)
let test_batch_write_error_continues () =
  let received = ref [] in
  let calls = ref 0 in
  let output =
    capture_stderr (fun () ->
        Eio_main.run @@ fun env ->
        let failing_once_sink : Olog.Logger.sink =
          {
            Olog.Logger.name = "failing-once";
            emit =
              (fun entries ->
                incr calls;
                received := List.rev_append entries !received;
                if !calls = 1 then Error "batch write failed" else Ok ());
            flush = (fun () -> Ok ());
            close = (fun () -> Ok ());
          }
        in
        let config = make_config ~sinks:[ failing_once_sink ] () in
        Eio.Switch.run (fun sw ->
            let logger = make_logger ~sw ~clock:env#clock config "test" in
            Olog.Logger.log logger ~level:Olog.Level.Info "first";
            Olog.Logger.log logger ~level:Olog.Level.Info "second";
            Olog.Logger.log logger ~level:Olog.Level.Info "third";
            Olog.Logger.flush logger))
  in
  Alcotest.(check (list string))
    "worker keeps delivering later entries after a batch Error"
    [ "first"; "second"; "third" ]
    (List.rev_map (fun (e : Olog.Entry.t) -> e.Olog.Entry.message) !received);
  Alcotest.(check int)
    "the batch Error is reported to stderr exactly once" 1
    (count_occurrences ~needle:"batch write failed" output)

(* ── Group 5b: greedy batch drain (FR2, Feature 0018) ────────────────────── *)

(* FR2 — entries that are consecutively queued while the worker is busy reach
   the sink in ONE [emit] call, in enqueue order. The warmup entry parks the
   worker inside [emit] (awaiting the latch) so the five entries queue up
   consecutively before the worker's next take; releasing the latch lets the
   greedy drain collect them as a single batch. The sink records whole batches
   — batch boundaries are the behaviour under test — so it is built directly
   rather than through the per-entry [mk_sink]. *)
let test_batch_delivery () =
  Eio_main.run @@ fun env ->
  let batches = ref [] in
  let calls = ref 0 in
  let latch, release = Eio.Promise.create () in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.name = "batch-recording";
      emit =
        (fun entries ->
          incr calls;
          batches :=
            List.map (fun (e : Olog.Entry.t) -> e.Olog.Entry.message) entries
            :: !batches;
          if !calls = 1 then Eio.Promise.await latch;
          Ok ());
      flush = (fun () -> Ok ());
      close = (fun () -> Ok ());
    }
  in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "warmup";
      Eio.Fiber.yield ();
      (* Worker is parked in [emit ["warmup"]]; these queue consecutively. *)
      for i = 1 to 5 do
        Olog.Logger.log logger ~level:Olog.Level.Info
          (Printf.sprintf "entry-%d" i)
      done;
      Eio.Promise.resolve release ();
      Olog.Logger.flush logger);
  Alcotest.(check (list (list string)))
    "consecutively queued entries arrive as one in-order batch"
    [ [ "warmup" ]; [ "entry-1"; "entry-2"; "entry-3"; "entry-4"; "entry-5" ] ]
    (List.rev !batches)

(* FR2, ADR 0004 — the greedy drain must stop at the first control message:
   entries enqueued after a [Flush] are not written before it resolves. The
   sink records one ordered event trace (batches and sink-flush calls), so a
   barrier crossing shows up as an [after-*] message in a batch preceding the
   "flush" event. Same warmup-latch parking as [test_batch_delivery]; the
   [Fiber.both] enqueues [before-1; before-2; Flush; after-1; after-2] before
   the worker resumes. Ends with [shutdown] (not a second [flush]) so the
   trace is not extended by the switch-close cancellation drain. *)
let test_batch_respects_flush_barrier () =
  Eio_main.run @@ fun env ->
  let events = ref [] in
  let calls = ref 0 in
  let latch, release = Eio.Promise.create () in
  let sink : Olog.Logger.sink =
    {
      Olog.Logger.name = "barrier-recording";
      emit =
        (fun entries ->
          incr calls;
          events :=
            ("batch:"
            ^ String.concat ","
                (List.map
                   (fun (e : Olog.Entry.t) -> e.Olog.Entry.message)
                   entries))
            :: !events;
          if !calls = 1 then Eio.Promise.await latch;
          Ok ());
      flush =
        (fun () ->
          events := "flush" :: !events;
          Ok ());
      close = (fun () -> Ok ());
    }
  in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "warmup";
      Eio.Fiber.yield ();
      Olog.Logger.log logger ~level:Olog.Level.Info "before-1";
      Olog.Logger.log logger ~level:Olog.Level.Info "before-2";
      Eio.Fiber.both
        (fun () -> Olog.Logger.flush logger)
        (fun () ->
          Olog.Logger.log logger ~level:Olog.Level.Info "after-1";
          Olog.Logger.log logger ~level:Olog.Level.Info "after-2";
          Eio.Promise.resolve release ());
      Olog.Logger.shutdown logger);
  Alcotest.(check (list string))
    "greedy drain stops at the flush barrier"
    [
      "batch:warmup";
      "batch:before-1,before-2";
      "flush";
      "batch:after-1,after-2";
      "flush";
    ]
    (List.rev !events)

(* ── Group 6: drop semantics ─────────────────────────────────────────────── *)

(* F11 — drop_count increments once per dropped entry *)
let test_drop_count_increments () =
  Eio_main.run @@ fun env ->
  let drop_count_snapshot = ref 0 in
  let latch, release = Eio.Promise.create () in
  let sink = mk_sink ~emit:(fun _ -> Eio.Promise.await latch) () in
  let config = make_config ~queue_depth:1 ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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
  let sink = mk_sink ~emit:(fun _ -> Eio.Promise.await latch) () in
  let config = make_config ~queue_depth:1 ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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

(* FR3 (Feature 0018) — each drop path increments its own cause counter, and
   [drop_count] stays the total. Three scenarios, one per cause:

   queue-full: the worker is parked inside [sink.emit] on a latch, the queue
   (capacity 1) is filled, and two further entries are rejected by the
   producer fast path — [drops_queue_full] only.

   after-shutdown: entries logged after [shutdown] returns are rejected by
   the producer fast path observing a non-[Running] state —
   [drops_after_shutdown] only.

   cancellation loss: the worker is parked inside [sink.emit] when the switch
   fails; the cancellation drain re-delivers the next queued entry to the
   sink, which raises [Eio.Cancel.Cancelled] (the one exception [run_sink_op]
   re-raises, simulating a sink torn down by the same cancellation), aborting
   the drain — the remaining queued entries are counted by the worker's
   final stop-and-count drain as [drops_on_cancel]. Entries handed to the
   sink before the abort count as emitted, so conservation is checkable from
   diagnostics alone even on this path. *)
let test_drop_cause_counters () =
  (* Scenario 1: queue-full. *)
  let queue_full_diag =
    Eio_main.run @@ fun env ->
    let latch, release = Eio.Promise.create () in
    let sink = mk_sink ~emit:(fun _ -> Eio.Promise.await latch) () in
    let config = make_config ~queue_depth:1 ~sinks:[ sink ] () in
    Eio.Switch.run (fun sw ->
        let logger = make_logger ~sw ~clock:env#clock config "test" in
        (* entry-1: worker takes it and parks inside sink.emit *)
        Olog.Logger.log logger ~level:Olog.Level.Info "entry-1";
        Eio.Fiber.yield ();
        (* entry-2 fills the queue; entry-3 and entry-4 are dropped *)
        Olog.Logger.log logger ~level:Olog.Level.Info "entry-2";
        Olog.Logger.log logger ~level:Olog.Level.Info "entry-3";
        Olog.Logger.log logger ~level:Olog.Level.Info "entry-4";
        let diag = Olog.Logger.diagnostics logger in
        Eio.Promise.resolve release ();
        Olog.Logger.flush logger;
        diag)
  in
  Alcotest.(check int)
    "queue-full drops land in drops_queue_full" 2
    queue_full_diag.Olog.Logger.drops_queue_full;
  Alcotest.(check int)
    "queue-full drops do not land in drops_after_shutdown" 0
    queue_full_diag.Olog.Logger.drops_after_shutdown;
  Alcotest.(check int)
    "queue-full drops do not land in drops_on_cancel" 0
    queue_full_diag.Olog.Logger.drops_on_cancel;
  Alcotest.(check int)
    "drop_count is the queue-full total" 2
    queue_full_diag.Olog.Logger.drop_count;
  (* Scenario 2: after-shutdown. *)
  let after_shutdown_diag =
    Eio_main.run @@ fun env ->
    let sink = mk_sink () in
    let config = make_config ~sinks:[ sink ] () in
    Eio.Switch.run (fun sw ->
        let logger = make_logger ~sw ~clock:env#clock config "test" in
        Olog.Logger.shutdown logger;
        Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-1";
        Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-2";
        Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-3";
        Olog.Logger.diagnostics logger)
  in
  Alcotest.(check int)
    "post-shutdown drops land in drops_after_shutdown" 3
    after_shutdown_diag.Olog.Logger.drops_after_shutdown;
  Alcotest.(check int)
    "post-shutdown drops do not land in drops_queue_full" 0
    after_shutdown_diag.Olog.Logger.drops_queue_full;
  Alcotest.(check int)
    "post-shutdown drops do not land in drops_on_cancel" 0
    after_shutdown_diag.Olog.Logger.drops_on_cancel;
  Alcotest.(check int)
    "drop_count is the post-shutdown total" 3
    after_shutdown_diag.Olog.Logger.drop_count;
  (* Scenario 3: cancellation loss. *)
  let on_cancel_diag =
    Eio_main.run @@ fun env ->
    let gate, _never_resolved = Eio.Promise.create () in
    let emit_calls = ref 0 in
    let sink =
      mk_sink
        ~emit:(fun _ ->
          incr emit_calls;
          if !emit_calls = 1 then Eio.Promise.await gate
          else raise (Eio.Cancel.Cancelled (Failure "sink torn down")))
        ()
    in
    let config = make_config ~queue_depth:16 ~sinks:[ sink ] () in
    let logger_ref = ref None in
    (try
       Eio.Switch.run (fun sw ->
           let logger = make_logger ~sw ~clock:env#clock config "test" in
           logger_ref := Some logger;
           (* entry-1: worker takes it and parks inside sink.emit *)
           Olog.Logger.log logger ~level:Olog.Level.Info "entry-1";
           Eio.Fiber.yield ();
           (* entry-2 is re-delivered by the cancellation drain (the sink
              raises Cancelled at it); entry-3 and entry-4 stay queued and
              are counted by the final stop-and-count drain *)
           Olog.Logger.log logger ~level:Olog.Level.Info "entry-2";
           Olog.Logger.log logger ~level:Olog.Level.Info "entry-3";
           Olog.Logger.log logger ~level:Olog.Level.Info "entry-4";
           Eio.Switch.fail sw (Failure "cancel"))
     with Failure _ -> ());
    match !logger_ref with
    | Some logger -> Olog.Logger.diagnostics logger
    | None -> Alcotest.fail "logger was not created"
  in
  Alcotest.(check int)
    "cancellation losses land in drops_on_cancel" 2
    on_cancel_diag.Olog.Logger.drops_on_cancel;
  Alcotest.(check int)
    "cancellation losses do not land in drops_queue_full" 0
    on_cancel_diag.Olog.Logger.drops_queue_full;
  Alcotest.(check int)
    "cancellation losses do not land in drops_after_shutdown" 0
    on_cancel_diag.Olog.Logger.drops_after_shutdown;
  Alcotest.(check int)
    "drop_count is the cancellation-loss total" 2
    on_cancel_diag.Olog.Logger.drop_count;
  Alcotest.(check int)
    "entries handed to the sink before the abort count as emitted" 2
    on_cancel_diag.Olog.Logger.emit_count

(* ── Group 7: flush ──────────────────────────────────────────────────────── *)

(* F14 — flush blocks until all preceding entries have been emitted *)
let test_flush_waits_for_entries () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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
  let sink = mk_sink ~flush:(fun () -> flushed := true) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.flush logger;
      Alcotest.(check bool) "flush calls sink flush for each sink" true !flushed)

(* sink.flush raising must not prevent the flush promise from resolving *)
let test_flush_sink_raise_does_not_hang () =
  Eio_main.run @@ fun env ->
  let second_flushed = ref false in
  let raising_sink = mk_sink ~flush:(fun () -> raise Exit) () in
  let counting_sink = mk_sink ~flush:(fun () -> second_flushed := true) () in
  let config = make_config ~sinks:[ raising_sink; counting_sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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
  let sink = mk_sink ~close:(fun () -> closed := true) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let _logger = make_logger ~sw ~clock:env#clock config "test" in
      ());
  Alcotest.(check bool) "sink close called when switch closes" true !closed

(* F7 — exceptions from sink.close must not propagate out of the worker *)
let test_close_exception_ignored () =
  Eio_main.run @@ fun env ->
  let sink = mk_sink ~close:(fun () -> raise Exit) () in
  let config = make_config ~sinks:[ sink ] () in
  (* If the exception propagates, Switch.run raises and the test fails *)
  Eio.Switch.run (fun sw ->
      let _logger = make_logger ~sw ~clock:env#clock config "test" in
      ())

(* F7 — sinks are closed in the order they appear in config.sinks *)
let test_close_in_list_order () =
  Eio_main.run @@ fun env ->
  let order = ref [] in
  let make_sink n = mk_sink ~close:(fun () -> order := n :: !order) () in
  let config =
    make_config ~sinks:[ make_sink 1; make_sink 2; make_sink 3 ] ()
  in
  Eio.Switch.run (fun sw ->
      let _logger = make_logger ~sw ~clock:env#clock config "test" in
      ());
  Alcotest.(check (list int))
    "sinks closed in list order" [ 1; 2; 3 ] (List.rev !order)

(* ── Group 9: concurrency ────────────────────────────────────────────────── *)

(* F16 — concurrent log calls from multiple fibers must all be emitted *)
let test_concurrent_log_all_emitted () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let n_fibers = 5 in
  let n_entries = 10 in
  let config =
    make_config ~queue_depth:(n_fibers * n_entries) ~sinks:[ sink ] ()
  in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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
  let sink = mk_sink () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
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

(* ── Helpers for context-wiring tests ───────────────────────────────────── *)

let pp_value fmt = function
  | Olog.Value.String s -> Format.fprintf fmt "String %S" s
  | Olog.Value.Int i -> Format.fprintf fmt "Int %d" i
  | Olog.Value.Float f -> Format.fprintf fmt "Float %f" f
  | Olog.Value.Bool b -> Format.fprintf fmt "Bool %b" b
  | Olog.Value.Null -> Format.fprintf fmt "Null"

let value_testable = Alcotest.testable pp_value ( = )
let opt_value = Alcotest.option value_testable
let field_value fields key = List.assoc_opt key fields

(* ── Group 10: context wiring ───────────────────────────────────────────── *)

(* F0, F7 — context fields must appear in emitted entry *)
let test_log_context_fields_appear () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Context.with_context
        ~fields:[ ("request_id", Olog.Value.string "req-abc123") ]
      @@ fun () ->
      Olog.Logger.log logger ~level:Olog.Level.Info "test";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  Alcotest.(check opt_value)
    "context field request_id appears in entry"
    (Some (Olog.Value.string "req-abc123"))
    (field_value entry.Olog.Entry.fields "request_id")

(* F8 — no context fields appear outside with_context scope *)
let test_log_no_context_outside_scope () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info
        ~fields:[ ("key", Olog.Value.string "val") ]
        "test";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  Alcotest.(check (list (pair string value_testable)))
    "fields contain only user-supplied key"
    [ ("key", Olog.Value.string "val") ]
    entry.Olog.Entry.fields

(* F9 — call-site fields override context on key collision *)
let test_log_callsite_overrides_context () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Context.with_context
        ~fields:
          [
            ("k", Olog.Value.string "ctx");
            ("ctx_only", Olog.Value.string "from-ctx");
          ]
      @@ fun () ->
      Olog.Logger.log logger ~level:Olog.Level.Info
        ~fields:[ ("k", Olog.Value.string "explicit") ]
        "test";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  let fields = entry.Olog.Entry.fields in
  Alcotest.(check opt_value)
    "non-colliding context field appears"
    (Some (Olog.Value.string "from-ctx"))
    (field_value fields "ctx_only");
  Alcotest.(check opt_value)
    "call-site field overrides context on collision"
    (Some (Olog.Value.string "explicit"))
    (field_value fields "k")

(* F10 — log_exn: context, user, and exception fields all present *)
let test_log_exn_context_user_exn_all_present () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Context.with_context
        ~fields:[ ("request_id", Olog.Value.string "req-abc123") ]
      @@ fun () ->
      let exn, bt =
        try raise (Failure "boom")
        with exn -> (exn, Printexc.get_raw_backtrace ())
      in
      Olog.Logger.log_exn logger ~level:Olog.Level.Error exn bt
        ~fields:[ ("extra", Olog.Value.string "val") ]
        "error occurred";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  let fields = entry.Olog.Entry.fields in
  Alcotest.(check opt_value)
    "context field request_id present"
    (Some (Olog.Value.string "req-abc123"))
    (field_value fields "request_id");
  Alcotest.(check opt_value)
    "user field extra present"
    (Some (Olog.Value.string "val"))
    (field_value fields "extra");
  Alcotest.(check opt_value)
    "exn.name present"
    (Some (Olog.Value.string "Failure"))
    (field_value fields "exn.name");
  Alcotest.(check bool)
    "exn.message present" true
    (Option.is_some (field_value fields "exn.message"));
  Alcotest.(check bool)
    "exn.backtrace present" true
    (Option.is_some (field_value fields "exn.backtrace"))

(* F10 — log_exn: exception fields override both context and user on collision *)
let test_log_exn_exn_overrides_context_and_user () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Context.with_context
        ~fields:
          [
            ("exn.name", Olog.Value.string "from-context");
            ("ctx_field", Olog.Value.string "ctx-val");
          ]
      @@ fun () ->
      let exn, bt =
        try raise (Failure "boom")
        with exn -> (exn, Printexc.get_raw_backtrace ())
      in
      Olog.Logger.log_exn logger ~level:Olog.Level.Error exn bt
        ~fields:[ ("exn.name", Olog.Value.string "from-user") ]
        "error occurred";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  let fields = entry.Olog.Entry.fields in
  Alcotest.(check opt_value)
    "non-colliding context field present"
    (Some (Olog.Value.string "ctx-val"))
    (field_value fields "ctx_field");
  Alcotest.(check opt_value)
    "exn.name is real exception name, not context or user value"
    (Some (Olog.Value.string "Failure"))
    (field_value fields "exn.name")

(* F11 — nested context: inner scope fields appear, inner wins on collision *)
let test_log_nested_context_inner_wins () =
  Eio_main.run @@ fun env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Context.with_context
        ~fields:
          [
            ("outer", Olog.Value.string "a");
            ("shared", Olog.Value.string "outer");
          ]
      @@ fun () ->
      Olog.Context.with_context
        ~fields:
          [
            ("inner", Olog.Value.string "b");
            ("shared", Olog.Value.string "inner");
          ]
      @@ fun () ->
      Olog.Logger.log logger ~level:Olog.Level.Info "test";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  let fields = entry.Olog.Entry.fields in
  Alcotest.(check opt_value)
    "outer context field present"
    (Some (Olog.Value.string "a"))
    (field_value fields "outer");
  Alcotest.(check opt_value)
    "inner context field present"
    (Some (Olog.Value.string "b"))
    (field_value fields "inner");
  Alcotest.(check opt_value)
    "inner value wins on shared key"
    (Some (Olog.Value.string "inner"))
    (field_value fields "shared")

(* ── Group 11: shutdown ─────────────────────────────────────────────────── *)

(* F13 — shutdown drains all queued entries *)
let test_shutdown_drains_all_queued_entries () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      for _ = 1 to 50 do
        Olog.Logger.log logger ~level:Olog.Level.Info "msg"
      done;
      Olog.Logger.shutdown logger);
  Alcotest.(check int) "shutdown drains all 50 entries" 50 !emitted

(* F3, F11, F16 — shutdown calls sink flush and close exactly once *)
let test_shutdown_calls_flush_and_close_exactly_once () =
  Eio_main.run @@ fun env ->
  let flush_count = ref 0 in
  let close_count = ref 0 in
  let sink =
    mk_sink
      ~flush:(fun () -> incr flush_count)
      ~close:(fun () -> incr close_count)
      ()
  in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "msg";
      Olog.Logger.shutdown logger);
  Alcotest.(check int) "sink flush called exactly once" 1 !flush_count;
  Alcotest.(check int) "sink close called exactly once" 1 !close_count

(* F4, F5, F15 — log after shutdown is dropped *)
let test_log_after_shutdown_is_dropped () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.shutdown logger;
      let emitted_before = !emitted in
      Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-1";
      Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-2";
      Olog.Logger.log logger ~level:Olog.Level.Info "after-shutdown-3";
      Alcotest.(check int)
        "no entries emitted after shutdown" emitted_before !emitted;
      Alcotest.(check int)
        "drop_count incremented for post-shutdown entries" 3
        (Olog.Logger.diagnostics logger).drop_count)

(* F6, F17 — flush after shutdown returns immediately *)
let test_flush_after_shutdown_returns_immediately () =
  Eio_main.run @@ fun env ->
  let flush_count = ref 0 in
  let sink = mk_sink ~flush:(fun () -> incr flush_count) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.shutdown logger;
      let count_after_shutdown = !flush_count in
      Olog.Logger.flush logger;
      Alcotest.(check int)
        "flush after shutdown does not call sink flush again"
        count_after_shutdown !flush_count)

(* F7, F18 — shutdown is idempotent *)
let test_shutdown_is_idempotent () =
  Eio_main.run @@ fun env ->
  let close_count = ref 0 in
  let sink = mk_sink ~close:(fun () -> incr close_count) () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.shutdown logger;
      Olog.Logger.shutdown logger);
  Alcotest.(check int)
    "sink close called only once after two shutdowns" 1 !close_count

(* F12, F19 — diagnostics reports is_shutdown *)
let test_diagnostics_is_shutdown_flag () =
  Eio_main.run @@ fun env ->
  let sink = mk_sink () in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Alcotest.(check bool)
        "is_shutdown is false before shutdown" false
        (Olog.Logger.diagnostics logger).is_shutdown;
      Olog.Logger.shutdown logger;
      Alcotest.(check bool)
        "is_shutdown is true after shutdown" true
        (Olog.Logger.diagnostics logger).is_shutdown)

(* F3 — shutdown flushes then closes sinks in order *)
let test_shutdown_flushes_then_closes_in_order () =
  Eio_main.run @@ fun env ->
  let order = ref [] in
  let make_sink id =
    mk_sink
      ~flush:(fun () -> order := Printf.sprintf "s%d-flush" id :: !order)
      ~close:(fun () -> order := Printf.sprintf "s%d-close" id :: !order)
      ()
  in
  let config = make_config ~sinks:[ make_sink 1; make_sink 2 ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.shutdown logger);
  Alcotest.(check (list string))
    "shutdown flushes all sinks then closes all sinks in order"
    [ "s1-flush"; "s2-flush"; "s1-close"; "s2-close" ]
    (List.rev !order)

(* ── Group 12: drain-on-cancel ─────────────────────────────────────────── *)

(* F8, F14 — cancel drains remaining queue entries *)
let test_cancel_drains_remaining_queue_entries () =
  Eio_main.run @@ fun env ->
  let emitted = ref 0 in
  let sink = mk_sink ~emit:(fun _ -> incr emitted) () in
  let config = make_config ~queue_depth:100 ~sinks:[ sink ] () in
  (try
     Eio.Switch.run (fun sw ->
         let logger = make_logger ~sw ~clock:env#clock config "test" in
         for _ = 1 to 10 do
           Olog.Logger.log logger ~level:Olog.Level.Info "msg"
         done;
         Eio.Switch.fail sw (Failure "cancel"))
   with Failure _ -> ());
  Alcotest.(check int) "all entries drained on cancel" 10 !emitted

(* F9, ADR 0007 — drain continues after sink emit failure *)
let test_drain_continues_after_sink_emit_failure () =
  Eio_main.run @@ fun env ->
  let second_emitted = ref 0 in
  let raising_sink = mk_sink ~emit:(fun _ -> raise Exit) () in
  let counting_sink = mk_sink ~emit:(fun _ -> incr second_emitted) () in
  let config =
    make_config ~queue_depth:100 ~sinks:[ raising_sink; counting_sink ] ()
  in
  (try
     Eio.Switch.run (fun sw ->
         let logger = make_logger ~sw ~clock:env#clock config "test" in
         for _ = 1 to 10 do
           Olog.Logger.log logger ~level:Olog.Level.Info "msg"
         done;
         Eio.Switch.fail sw (Failure "cancel"))
   with Failure _ -> ());
  Alcotest.(check int)
    "second sink receives all entries despite first sink raising" 10
    !second_emitted

(* ── Group 13: lifecycle liveness (RFC 0013 F1, F2) ─────────────────────── *)

(* Raised by [with_timeout] when the wrapped operation fails to return within
   the deadline. Used to convert a hang (the pre-fix failure mode) into a
   bounded test failure rather than a stuck suite (RFC 0013 test plan). *)
exception Test_timeout

let with_timeout ~clock seconds f =
  Eio.Fiber.first
    (fun () -> f ())
    (fun () ->
      Eio.Time.sleep clock seconds;
      raise Test_timeout)

(* F1 — after the logger's switch is cancelled, the worker has terminated;
   [flush] must return promptly instead of awaiting a resolver no worker will
   ever fulfil (it hangs forever pre-fix). *)
let test_flush_returns_after_switch_cancellation () =
  Eio_main.run @@ fun env ->
  let config = make_config () in
  let logger_ref = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let logger = make_logger ~sw ~clock:env#clock config "test" in
         logger_ref := Some logger;
         Eio.Switch.fail sw (Failure "cancel"))
   with Failure _ -> ());
  let logger = Option.get !logger_ref in
  let completed = ref false in
  with_timeout ~clock:env#clock 2.0 (fun () ->
      Olog.Logger.flush logger;
      completed := true);
  Alcotest.(check bool)
    "flush returns after the logger's switch is cancelled" true !completed

(* F1 — same liveness guarantee for [shutdown] after switch cancellation. *)
let test_shutdown_returns_after_switch_cancellation () =
  Eio_main.run @@ fun env ->
  let config = make_config () in
  let logger_ref = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let logger = make_logger ~sw ~clock:env#clock config "test" in
         logger_ref := Some logger;
         Eio.Switch.fail sw (Failure "cancel"))
   with Failure _ -> ());
  let logger = Option.get !logger_ref in
  let completed = ref false in
  with_timeout ~clock:env#clock 2.0 (fun () ->
      Olog.Logger.shutdown logger;
      completed := true);
  Alcotest.(check bool)
    "shutdown returns after the logger's switch is cancelled" true !completed

(* F2 — concurrent [shutdown] from several fibers and a second domain: every
   caller returns and the sink is closed exactly once. Looped to surface the
   late-enqueue-after-worker-death race (RFC 0013 R5). *)
let test_concurrent_shutdown_all_callers_return () =
  Eio_main.run @@ fun env ->
  let domain_mgr = env#domain_mgr in
  for _ = 1 to 100 do
    let close_count = Atomic.make 0 in
    let sink = mk_sink ~close:(fun () -> Atomic.incr close_count) () in
    let config = make_config ~sinks:[ sink ] () in
    Eio.Switch.run (fun sw ->
        let logger = make_logger ~sw ~clock:env#clock config "test" in
        Eio.Fiber.all
          ((fun () ->
             Eio.Domain_manager.run domain_mgr (fun () ->
                 Olog.Logger.shutdown logger))
          :: List.init 4 (fun _ -> fun () -> Olog.Logger.shutdown logger)));
    Alcotest.(check int)
      "sink closed exactly once across concurrent shutdowns" 1
      (Atomic.get close_count)
  done

(* F1, R4 — the [flush] liveness *race* arm: the worker dies after taking the
   [Flush] message but before resolving its promise, abandoning the resolver.
   The switch-cancellation tests above all land in [flush]'s [Stopped] fast
   path (the worker is already dead when [flush] is called); this one drives the
   [Fiber.first] [stopped]-wins arm, where state is [Running] at the check and
   the worker dies mid-flush. A sink whose [flush] raises [Eio.Cancel.Cancelled]
   on its first call makes the worker take its cancellation exit (re-raised by
   [run_sink_op]) without ever resolving the in-flight [Flush] resolver; the
   worker's [finally] still resolves [stopped], so [flush] must return via the
   [stopped] arm rather than awaiting a promise no worker will fulfil. The
   second [flush] call (from the cancellation drain) succeeds, so the worker
   stops cleanly without failing the switch. *)
let test_flush_returns_when_worker_dies_mid_flush () =
  Eio_main.run @@ fun env ->
  let flush_calls = ref 0 in
  let sink =
    mk_sink
      ~flush:(fun () ->
        incr flush_calls;
        if !flush_calls = 1 then
          raise (Eio.Cancel.Cancelled (Failure "simulated sink cancellation")))
      ()
  in
  let config = make_config ~sinks:[ sink ] () in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      let completed = ref false in
      with_timeout ~clock:env#clock 2.0 (fun () ->
          Olog.Logger.flush logger;
          completed := true);
      Alcotest.(check bool)
        "flush returns when the worker dies mid-flush" true !completed)

(* ── Group 14: conservation accounting (RFC 0013 F5) ────────────────────── *)

(* Each producer runs its entry loop on its own domain, so the producers run
   in genuine parallel with the worker and with [shutdown]/cancellation on the
   main domain. Single-domain Eio scheduling is cooperative — [log]'s fast path
   has no suspension point, so the accounting races these tests target only
   surface under true parallelism (RFC 0013 R1, R5). [submitted] is incremented
   once per completed [log] call; a call cut short by cancellation never
   increments it, so [submitted] always equals the number of accepted entries. *)
let conservation_producers ~domain_mgr ~submitted ~logger ~m_producers
    ~k_entries =
  Eio.Fiber.all
    (List.init m_producers (fun _ ->
         fun () ->
          Eio.Domain_manager.run domain_mgr (fun () ->
              for _ = 1 to k_entries do
                Olog.Logger.log logger ~level:Olog.Level.Info "msg";
                Atomic.incr submitted
              done)))

(* F5 — every entry accepted by [log] is either dispatched to the sinks or
   counted in [drop_count], even under parallel producers and a mid-stream
   [shutdown]. Verified entirely from outside: a test-side [submitted] counter,
   a counting sink ([emitted]), and [diagnostics.drop_count]. With [queue_depth]
   far smaller than the total entry count, most entries are dropped, exercising
   both the queue-full and the post-shutdown accounting paths. Pre-fix, a [Log]
   enqueued after [Shutdown] is silently discarded by the worker's trailing
   drain, so [submitted > emitted + drop_count] and the invariant breaks. *)
let test_conservation_under_concurrent_load () =
  Eio_main.run @@ fun env ->
  let domain_mgr = env#domain_mgr in
  let m_producers = 8 in
  let k_entries = 1000 in
  let submitted = Atomic.make 0 in
  let emitted = Atomic.make 0 in
  let sink = mk_sink ~emit:(fun _ -> Atomic.incr emitted) () in
  let config = make_config ~queue_depth:16 ~sinks:[ sink ] () in
  let drop_count = ref (-1) in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Eio.Fiber.both
        (fun () ->
          conservation_producers ~domain_mgr ~submitted ~logger ~m_producers
            ~k_entries)
        (fun () ->
          (* Let producers start contending, then shut down mid-stream. *)
          Eio.Fiber.yield ();
          Olog.Logger.shutdown logger);
      drop_count := (Olog.Logger.diagnostics logger).drop_count);
  Alcotest.(check int)
    "conservation: submitted = emitted + drop_count under concurrent shutdown"
    (Atomic.get submitted)
    (Atomic.get emitted + !drop_count)

(* F5 + F1 — the same conservation invariant must hold when the logger's switch
   is cancelled mid-stream instead of a graceful [shutdown]. The worker's
   cancellation drain must set [Stopped] under the producer mutex before
   draining, so every [Log] is either drained-and-emitted or seen as [Stopped]
   and counted as a drop — none lost. Pre-fix, the drain neither sets [Stopped]
   first nor counts stragglers, so parallel producers slip entries past the
   drain and the invariant breaks. *)
let test_conservation_after_cancellation () =
  Eio_main.run @@ fun env ->
  let domain_mgr = env#domain_mgr in
  let m_producers = 8 in
  let k_entries = 1000 in
  let submitted = Atomic.make 0 in
  let emitted = Atomic.make 0 in
  let sink = mk_sink ~emit:(fun _ -> Atomic.incr emitted) () in
  let config = make_config ~queue_depth:16 ~sinks:[ sink ] () in
  let logger_ref = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let logger = make_logger ~sw ~clock:env#clock config "test" in
         logger_ref := Some logger;
         Eio.Fiber.both
           (fun () ->
             conservation_producers ~domain_mgr ~submitted ~logger ~m_producers
               ~k_entries)
           (fun () ->
             Eio.Fiber.yield ();
             Eio.Switch.fail sw (Failure "cancel")))
   with Failure _ -> ());
  let logger = Option.get !logger_ref in
  let drop_count = (Olog.Logger.diagnostics logger).drop_count in
  Alcotest.(check int)
    "conservation: submitted = emitted + drop_count under cancellation"
    (Atomic.get submitted)
    (Atomic.get emitted + drop_count)

(* FR3, NFR3 (Feature 0018) — conservation must be checkable from diagnostics
   alone: [submitted = emit_count + drop_count] and the per-cause counters sum
   to [drop_count], under parallel producers and a mid-stream [shutdown]. The
   test-side sink counter cross-checks that [emit_count] means entries handed
   to the sinks, counted once per entry (not once per sink call). *)
let test_conservation_with_split () =
  Eio_main.run @@ fun env ->
  let domain_mgr = env#domain_mgr in
  let m_producers = 8 in
  let k_entries = 1000 in
  let submitted = Atomic.make 0 in
  let emitted = Atomic.make 0 in
  let sink = mk_sink ~emit:(fun _ -> Atomic.incr emitted) () in
  let config = make_config ~queue_depth:16 ~sinks:[ sink ] () in
  let diag = ref None in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Eio.Fiber.both
        (fun () ->
          conservation_producers ~domain_mgr ~submitted ~logger ~m_producers
            ~k_entries)
        (fun () ->
          (* Let producers start contending, then shut down mid-stream. *)
          Eio.Fiber.yield ();
          Olog.Logger.shutdown logger);
      diag := Some (Olog.Logger.diagnostics logger));
  match !diag with
  | None -> Alcotest.fail "diagnostics snapshot was not captured"
  | Some d ->
      Alcotest.(check int)
        "conservation: submitted = emit_count + drop_count"
        (Atomic.get submitted)
        (d.Olog.Logger.emit_count + d.Olog.Logger.drop_count);
      Alcotest.(check int)
        "drop_count = sum of the per-cause counters" d.Olog.Logger.drop_count
        (d.Olog.Logger.drops_queue_full + d.Olog.Logger.drops_after_shutdown
       + d.Olog.Logger.drops_on_cancel);
      Alcotest.(check int)
        "emit_count matches the sink-side emitted counter" (Atomic.get emitted)
        d.Olog.Logger.emit_count

(* FR3 (Feature 0018) — [emit_count] counts entries, not sink calls: the
   [logger.mli] contract says "once per entry regardless of the number of
   sinks", which a single-sink test cannot distinguish from per-sink counting.
   With two sinks, N entries must yield [emit_count = N], not [2N]; the
   sink-side counters cross-check that each sink still saw every entry. *)
let test_emit_count_counts_entries_not_sink_calls () =
  Eio_main.run @@ fun env ->
  let first_emitted = ref 0 in
  let second_emitted = ref 0 in
  let first = mk_sink ~emit:(fun _ -> incr first_emitted) () in
  let second = mk_sink ~emit:(fun _ -> incr second_emitted) () in
  let config = make_config ~sinks:[ first; second ] () in
  let diag = ref None in
  Eio.Switch.run (fun sw ->
      let logger = make_logger ~sw ~clock:env#clock config "test" in
      Olog.Logger.log logger ~level:Olog.Level.Info "one";
      Olog.Logger.log logger ~level:Olog.Level.Info "two";
      Olog.Logger.log logger ~level:Olog.Level.Info "three";
      Olog.Logger.shutdown logger;
      diag := Some (Olog.Logger.diagnostics logger));
  match !diag with
  | None -> Alcotest.fail "diagnostics snapshot was not captured"
  | Some d ->
      Alcotest.(check int)
        "emit_count counts once per entry regardless of the number of sinks" 3
        d.Olog.Logger.emit_count;
      Alcotest.(check int) "first sink saw every entry" 3 !first_emitted;
      Alcotest.(check int) "second sink saw every entry" 3 !second_emitted

(* ── Group: timestamp fallback (RFC 0013 F6) ─────────────────────────────── *)

(* F6 — [Fail] mode probes the clock once at [create] and rejects an
   unrepresentable reading, rather than forking a worker that would silently
   stamp [Ptime.epoch] on every entry for the lifetime of the logger. *)
let test_create_fail_mode_rejects_broken_clock () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run (fun sw ->
      let clock = mock_clock (ref Float.nan) in
      let config = make_config ~timestamp_fallback:Olog.Logger.Fail () in
      let result = Olog.Logger.create ~sw ~clock config "test" in
      Alcotest.(check bool)
        "create returns Error for a broken clock in Fail mode" true
        (match result with Ok _ -> false | Error _ -> true))

(* F6 — the [Fail] probe gates only on an unrepresentable reading: a valid
   clock must pass it and yield a working logger. [create] owns both arms of
   its Ok/Error collapse, so the accept arm is pinned here, not left to
   transitive coverage. *)
let test_create_fail_mode_accepts_valid_clock () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run (fun sw ->
      let clock = mock_clock (ref 1_700_000_000.0) in
      let config = make_config ~timestamp_fallback:Olog.Logger.Fail () in
      let result = Olog.Logger.create ~sw ~clock config "test" in
      Alcotest.(check bool)
        "create accepts a representable clock in Fail mode" true
        (match result with Ok _ -> true | Error _ -> false))

(* F6 — default [Mark_invalid]: a clock that breaks after creation must not
   lose the entry. It is stamped with [Ptime.epoch] and flagged with the
   reserved [olog.invalid_timestamp] marker so the corruption is detectable
   downstream. *)
let test_log_marks_invalid_timestamp_by_default () =
  Eio_main.run @@ fun _env ->
  let captured = ref None in
  let sink = mk_sink ~emit:(fun entry -> captured := Some entry) () in
  let config = make_config ~sinks:[ sink ] () in
  let clk = ref 1_700_000_000.0 in
  Eio.Switch.run (fun sw ->
      let clock = mock_clock clk in
      let logger = make_logger ~sw ~clock config "test" in
      clk := Float.nan;
      Olog.Logger.log logger ~level:Olog.Level.Info "after clock break";
      Olog.Logger.flush logger);
  let entry = Option.get !captured in
  Alcotest.(check bool)
    "unrepresentable timestamp is stamped with the epoch" true
    (Ptime.equal entry.Olog.Entry.timestamp Ptime.epoch);
  Alcotest.(check opt_value)
    "reserved invalid-timestamp marker is appended"
    (Some (Olog.Value.bool true))
    (field_value entry.Olog.Entry.fields "olog.invalid_timestamp")

(* ── runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Logger"
    [
      ( "Config",
        [
          Alcotest.test_case "make rejects nonpositive queue_depth" `Quick
            test_config_make_rejects_nonpositive_queue_depth;
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
          Alcotest.test_case "sink emit Error does not stop worker" `Quick
            test_sink_emit_error_does_not_stop_worker;
          Alcotest.test_case "contract-violating sink does not stop worker"
            `Quick test_contract_violating_sink_does_not_stop_worker;
          Alcotest.test_case "sink error reports fallback line to stderr" `Quick
            test_sink_error_reports_fallback_line_to_stderr;
          Alcotest.test_case "batch write error reported once, worker continues"
            `Quick test_batch_write_error_continues;
        ] );
      ( "batching",
        [
          Alcotest.test_case
            "consecutively queued entries delivered as one batch" `Quick
            test_batch_delivery;
          Alcotest.test_case "greedy drain stops at the flush barrier" `Quick
            test_batch_respects_flush_barrier;
        ] );
      ( "drop",
        [
          Alcotest.test_case "drop_count increments when queue is full" `Quick
            test_drop_count_increments;
          Alcotest.test_case "log returns without suspending when queue is full"
            `Quick test_log_does_not_suspend;
          Alcotest.test_case "each drop cause increments its own counter" `Quick
            test_drop_cause_counters;
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
      ( "context",
        [
          Alcotest.test_case "context fields appear in emitted entry" `Quick
            test_log_context_fields_appear;
          Alcotest.test_case "no context fields outside with_context" `Quick
            test_log_no_context_outside_scope;
          Alcotest.test_case "call-site fields override context on collision"
            `Quick test_log_callsite_overrides_context;
          Alcotest.test_case
            "log_exn: context, user, and exn fields all present" `Quick
            test_log_exn_context_user_exn_all_present;
          Alcotest.test_case "log_exn: exn fields override context and user"
            `Quick test_log_exn_exn_overrides_context_and_user;
          Alcotest.test_case "nested context: inner scope fields appear" `Quick
            test_log_nested_context_inner_wins;
        ] );
      ( "shutdown",
        [
          Alcotest.test_case "shutdown drains all queued entries" `Quick
            test_shutdown_drains_all_queued_entries;
          Alcotest.test_case "shutdown calls sink flush and close exactly once"
            `Quick test_shutdown_calls_flush_and_close_exactly_once;
          Alcotest.test_case "log after shutdown is dropped" `Quick
            test_log_after_shutdown_is_dropped;
          Alcotest.test_case "flush after shutdown returns immediately" `Quick
            test_flush_after_shutdown_returns_immediately;
          Alcotest.test_case "shutdown is idempotent" `Quick
            test_shutdown_is_idempotent;
          Alcotest.test_case "diagnostics reports is_shutdown" `Quick
            test_diagnostics_is_shutdown_flag;
          Alcotest.test_case "shutdown flushes then closes sinks in order"
            `Quick test_shutdown_flushes_then_closes_in_order;
        ] );
      ( "drain-on-cancel",
        [
          Alcotest.test_case "cancel drains remaining queue entries" `Quick
            test_cancel_drains_remaining_queue_entries;
          Alcotest.test_case "drain continues after sink emit failure" `Quick
            test_drain_continues_after_sink_emit_failure;
        ] );
      ( "lifecycle",
        [
          Alcotest.test_case "flush returns after switch cancellation" `Quick
            test_flush_returns_after_switch_cancellation;
          Alcotest.test_case "shutdown returns after switch cancellation" `Quick
            test_shutdown_returns_after_switch_cancellation;
          Alcotest.test_case "concurrent shutdown all callers return" `Quick
            test_concurrent_shutdown_all_callers_return;
          Alcotest.test_case "flush returns when worker dies mid-flush" `Quick
            test_flush_returns_when_worker_dies_mid_flush;
        ] );
      ( "conservation",
        [
          Alcotest.test_case "submitted = emitted + drops under concurrent load"
            `Quick test_conservation_under_concurrent_load;
          Alcotest.test_case "submitted = emitted + drops after cancellation"
            `Quick test_conservation_after_cancellation;
          Alcotest.test_case
            "submitted = emit_count + drop_count with per-cause split" `Quick
            test_conservation_with_split;
          Alcotest.test_case
            "emit_count counts entries, not sink calls, with two sinks" `Quick
            test_emit_count_counts_entries_not_sink_calls;
        ] );
      ( "timestamp",
        [
          Alcotest.test_case "Fail mode rejects a broken clock at create" `Quick
            test_create_fail_mode_rejects_broken_clock;
          Alcotest.test_case "Fail mode accepts a valid clock at create" `Quick
            test_create_fail_mode_accepts_valid_clock;
          Alcotest.test_case
            "Mark_invalid stamps epoch and marker on broken clock" `Quick
            test_log_marks_invalid_timestamp_by_default;
        ] );
    ]
