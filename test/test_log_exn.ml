open Olog

(* ── Shared test infrastructure ─────────────────────────────────────────── *)

let make_capturing_sink () =
  let entries = ref [] in
  let sink : Logger.sink =
    {
      name = "capture";
      emit =
        (fun e ->
          entries := e :: !entries;
          Ok ());
      flush = (fun () -> Ok ());
      close = (fun () -> Ok ());
    }
  in
  (sink, entries)

let unwrap label = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "%s: %s" label msg

let with_test_logger min_level f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink, entries = make_capturing_sink () in
  let config =
    unwrap "Config.make"
      (Logger.Config.make ~min_level ~queue_depth:64 ~sinks:[ sink ] ())
  in
  let logger =
    unwrap "Logger.create"
      (Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "test")
  in
  f logger entries

(* ── F1: exn.name field ─────────────────────────────────────────────────── *)

let test_log_exn_captures_exn_name () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  Logger.log_exn logger ~level:Level.Error exn bt "error occurred";
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has exn.name field" true
    (List.mem ("exn.name", Value.string "Failure") entry.Entry.fields)

(* ── F2: exn.message field ──────────────────────────────────────────────── *)

let test_log_exn_captures_exn_message () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  Logger.log_exn logger ~level:Level.Error exn bt "error occurred";
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  let expected_msg = Printexc.to_string exn in
  Alcotest.(check bool)
    "has exn.message field" true
    (List.mem ("exn.message", Value.string expected_msg) entry.Entry.fields)

(* ── F3: exn.backtrace when recording enabled ───────────────────────────── *)

let test_log_exn_backtrace_when_recording_enabled () =
  let prev = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace prev)
    (fun () ->
      with_test_logger Level.Trace @@ fun logger entries ->
      let bt =
        try raise (Failure "bt test") with _ -> Printexc.get_raw_backtrace ()
      in
      let exn = Failure "bt test" in
      Logger.log_exn logger ~level:Level.Error exn bt "error occurred";
      Logger.flush logger;
      let entry = List.hd (List.rev !entries) in
      let has_bt =
        List.exists
          (fun (k, v) ->
            k = "exn.backtrace"
            && match v with Value.String s -> String.length s > 0 | _ -> false)
          entry.Entry.fields
      in
      Alcotest.(check bool) "backtrace is non-empty" true has_bt)

(* ── F3: exn.backtrace when recording disabled ──────────────────────────── *)

let test_log_exn_backtrace_when_recording_disabled () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let bt = Printexc.get_callstack 0 in
  let exn = Failure "no bt" in
  Logger.log_exn logger ~level:Level.Error exn bt "error occurred";
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "backtrace is empty string" true
    (List.mem ("exn.backtrace", Value.string "") entry.Entry.fields)

(* ── F4: user fields merged with exn fields ──────────────────────────────── *)

let test_log_exn_merges_user_fields () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  Logger.log_exn logger ~level:Level.Error exn bt
    ~fields:[ ("request_id", Value.string "abc") ]
    "error occurred";
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  let has_user =
    List.mem ("request_id", Value.string "abc") entry.Entry.fields
  in
  let has_exn =
    List.mem ("exn.name", Value.string "Failure") entry.Entry.fields
  in
  Alcotest.(check bool) "has user field" true has_user;
  Alcotest.(check bool) "has exn field" true has_exn

(* ── F4: exn fields override user fields on collision ────────────────────── *)

let test_log_exn_exn_fields_override_collision () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  Logger.log_exn logger ~level:Level.Error exn bt
    ~fields:[ ("exn.name", Value.string "custom") ]
    "error occurred";
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  (* exn.name should be "Failure", not "custom" — exn fields take precedence *)
  Alcotest.(check bool)
    "exn.name is auto-extracted, not user override" true
    (List.mem ("exn.name", Value.string "Failure") entry.Entry.fields);
  Alcotest.(check bool)
    "user override is not present" false
    (List.mem ("exn.name", Value.string "custom") entry.Entry.fields)

(* ── F5: never raises on full queue ──────────────────────────────────────── *)

let test_log_exn_never_raises_on_full_queue () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink, _entries = make_capturing_sink () in
  let config =
    unwrap "Config.make"
      (Logger.Config.make ~min_level:Level.Trace ~queue_depth:1 ~sinks:[ sink ]
         ())
  in
  let logger =
    unwrap "Logger.create"
      (Logger.create ~sw ~clock:(Eio.Stdenv.clock env) config "test")
  in
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  (* Fill the queue and overflow — should not raise *)
  for _ = 1 to 10 do
    Logger.log_exn logger ~level:Level.Error exn bt "overflow"
  done;
  let diag = Logger.diagnostics logger in
  Alcotest.(check bool) "drop_count > 0" true (diag.drop_count > 0)

(* ── F5: skips when level disabled ───────────────────────────────────────── *)

let test_log_exn_skips_when_level_disabled () =
  with_test_logger Level.Error @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  Logger.log_exn logger ~level:Level.Debug exn bt "should be skipped";
  Logger.flush logger;
  Alcotest.(check int) "no entries when level disabled" 0 (List.length !entries)

(* ── General: all six levels ─────────────────────────────────────────────── *)

let test_log_exn_all_six_levels () =
  with_test_logger Level.Trace @@ fun logger entries ->
  let exn = Failure "test" in
  let bt = Printexc.get_callstack 0 in
  let levels =
    [
      Level.Trace; Level.Debug; Level.Info; Level.Warn; Level.Error; Level.Fatal;
    ]
  in
  List.iter
    (fun level -> Logger.log_exn logger ~level exn bt (Level.to_string level))
    levels;
  Logger.flush logger;
  let emitted = List.rev !entries in
  Alcotest.(check int) "six entries" 6 (List.length emitted);
  List.iter2
    (fun expected entry ->
      Alcotest.(check bool)
        ("level is " ^ Level.to_string expected)
        true
        (Level.equal expected entry.Entry.level))
    levels emitted

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "log_exn"
    [
      ( "log_exn",
        [
          Alcotest.test_case "log_exn captures exn.name" `Quick
            test_log_exn_captures_exn_name;
          Alcotest.test_case "log_exn captures exn.message" `Quick
            test_log_exn_captures_exn_message;
          Alcotest.test_case "log_exn captures backtrace when recording enabled"
            `Quick test_log_exn_backtrace_when_recording_enabled;
          Alcotest.test_case
            "log_exn captures empty backtrace when recording disabled" `Quick
            test_log_exn_backtrace_when_recording_disabled;
          Alcotest.test_case "log_exn merges user fields with exn fields" `Quick
            test_log_exn_merges_user_fields;
          Alcotest.test_case
            "log_exn exn fields override user fields on collision" `Quick
            test_log_exn_exn_fields_override_collision;
          Alcotest.test_case "log_exn never raises on full queue" `Quick
            test_log_exn_never_raises_on_full_queue;
          Alcotest.test_case "log_exn skips when level disabled" `Quick
            test_log_exn_skips_when_level_disabled;
          Alcotest.test_case "log_exn works for all six levels" `Quick
            test_log_exn_all_six_levels;
        ] );
    ]
