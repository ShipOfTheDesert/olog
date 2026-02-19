open Olog

(* Shared test infrastructure *)

let make_capturing_sink () =
  let entries = ref [] in
  let sink : Logger.sink =
    {
      emit = (fun e -> entries := e :: !entries);
      flush = Fun.id;
      close = Fun.id;
    }
  in
  (sink, entries)

let with_test_logger min_level f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let sink, entries = make_capturing_sink () in
  let logger =
    Logger.create ~sw ~clock:(Eio.Stdenv.clock env)
      { Logger.Config.min_level; queue_depth = 64; sinks = [ sink ] }
      "test"
  in
  f logger entries

(* Test functions *)

let test_info_emits_one_entry () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "hello"];
  Logger.flush logger;
  let emitted = List.rev !entries in
  Alcotest.(check int) "one entry" 1 (List.length emitted)

let test_info_src_pos_file_matches () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "hello"];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  match entry.Entry.src_pos with
  | None -> Alcotest.fail "expected src_pos Some"
  | Some p ->
      Alcotest.(check string)
        "file basename" "test_ppx.ml"
        (Filename.basename p.Entry.file);
      Alcotest.(check bool) "line > 0" true (p.Entry.line > 0)

let test_literal_int_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "data" [ ("x", 42) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has int field" true
    (List.mem ("x", Value.Int 42) entry.Entry.fields)

let test_literal_string_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "data" [ ("s", "hello") ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has string field" true
    (List.mem ("s", Value.String "hello") entry.Entry.fields)

let test_literal_bool_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "data" [ ("ok", false) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has bool field" true
    (List.mem ("ok", Value.Bool false) entry.Entry.fields)

let test_backtick_int_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  let n = 7 in
  [%log.info logger "iter" [ ("n", `Int n) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has int field" true
    (List.mem ("n", Value.Int 7) entry.Entry.fields)

let test_no_fields_form_empty_fields () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "hello"];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool) "empty fields" true (entry.Entry.fields = [])

let test_is_enabled_guard_skips () =
  with_test_logger Level.Error @@ fun logger entries ->
  [%log.debug logger "skip"];
  Logger.flush logger;
  Alcotest.(check int) "no entries" 0 (List.length !entries)

let test_literal_float_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "data" [ ("pi", 3.14) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has float field" true
    (List.mem ("pi", Value.Float 3.14) entry.Entry.fields)

let test_backtick_float_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  let t = 2.72 in
  [%log.info logger "data" [ ("x", `Float t) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has float field" true
    (List.mem ("x", Value.Float 2.72) entry.Entry.fields)

let test_backtick_string_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  let v = "abc" in
  [%log.info logger "data" [ ("s", `String v) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has string field" true
    (List.mem ("s", Value.String "abc") entry.Entry.fields)

let test_backtick_bool_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  let b = true in
  [%log.info logger "data" [ ("ok", `Bool b) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has bool field" true
    (List.mem ("ok", Value.Bool true) entry.Entry.fields)

let test_backtick_null_wrapped () =
  with_test_logger Level.Info @@ fun logger entries ->
  [%log.info logger "data" [ ("k", `Null) ]];
  Logger.flush logger;
  let entry = List.hd (List.rev !entries) in
  Alcotest.(check bool)
    "has null field" true
    (List.mem ("k", Value.Null) entry.Entry.fields)

let () =
  Alcotest.run "ppx"
    [
      ( "ppx",
        [
          Alcotest.test_case "[%log.info] emits exactly one entry" `Quick
            test_info_emits_one_entry;
          Alcotest.test_case "src_pos file matches test file name" `Quick
            test_info_src_pos_file_matches;
          Alcotest.test_case "literal int 42 auto-wrapped to Value.Int" `Quick
            test_literal_int_wrapped;
          Alcotest.test_case "literal string auto-wrapped to Value.String"
            `Quick test_literal_string_wrapped;
          Alcotest.test_case "literal bool false auto-wrapped to Value.Bool"
            `Quick test_literal_bool_wrapped;
          Alcotest.test_case "backtick Int wraps expression" `Quick
            test_backtick_int_wrapped;
          Alcotest.test_case "no-fields form uses empty fields" `Quick
            test_no_fields_form_empty_fields;
          Alcotest.test_case "is_enabled guard skips log below min_level" `Quick
            test_is_enabled_guard_skips;
          Alcotest.test_case "literal float 3.14 auto-wrapped to Value.Float"
            `Quick test_literal_float_wrapped;
          Alcotest.test_case "backtick Float wraps expression" `Quick
            test_backtick_float_wrapped;
          Alcotest.test_case "backtick String wraps expression" `Quick
            test_backtick_string_wrapped;
          Alcotest.test_case "backtick Bool wraps expression" `Quick
            test_backtick_bool_wrapped;
          Alcotest.test_case "backtick Null wraps to Value.Null" `Quick
            test_backtick_null_wrapped;
        ] );
    ]
