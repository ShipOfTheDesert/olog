let all_levels = Olog.Level.[ Trace; Debug; Info; Warn; Error; Fatal ]
let all_strings = [ "trace"; "debug"; "info"; "warn"; "error"; "fatal" ]

let level_testable =
  Alcotest.testable
    (fun fmt l -> Format.fprintf fmt "%s" (Olog.Level.to_string l))
    Olog.Level.equal

let result_level_testable = Alcotest.result level_testable Alcotest.string

let test_to_string_all_variants () =
  List.iter2
    (fun level expected ->
      Alcotest.(check string)
        ("to_string " ^ expected) expected
        (Olog.Level.to_string level))
    all_levels all_strings

let test_of_string_valid () =
  List.iter2
    (fun expected s ->
      Alcotest.(check result_level_testable)
        ("of_string " ^ s) (Ok expected) (Olog.Level.of_string s))
    all_levels all_strings

let test_of_string_case_insensitive () =
  let cases = [ "INFO"; "Info"; "info"; "iNfO" ] in
  List.iter
    (fun s ->
      Alcotest.(check result_level_testable)
        ("of_string " ^ s) (Ok Olog.Level.Info) (Olog.Level.of_string s))
    cases

let test_of_string_invalid () =
  let bad = "not_a_level" in
  Alcotest.(check result_level_testable)
    "of_string invalid" (Error bad) (Olog.Level.of_string bad)

let test_compare_ordering () =
  let pairs =
    [
      (Olog.Level.Trace, Olog.Level.Debug);
      (Olog.Level.Debug, Olog.Level.Info);
      (Olog.Level.Info, Olog.Level.Warn);
      (Olog.Level.Warn, Olog.Level.Error);
      (Olog.Level.Error, Olog.Level.Fatal);
    ]
  in
  List.iter
    (fun (lo, hi) ->
      Alcotest.(check bool)
        (Format.asprintf "%s < %s" (Olog.Level.to_string lo)
           (Olog.Level.to_string hi))
        true
        (Olog.Level.compare lo hi < 0))
    pairs

let test_compare_equal () =
  List.iter
    (fun level ->
      Alcotest.(check int)
        (Format.asprintf "compare %s %s = 0"
           (Olog.Level.to_string level)
           (Olog.Level.to_string level))
        0
        (Olog.Level.compare level level))
    all_levels

let test_equal_same () =
  List.iter
    (fun level ->
      Alcotest.(check bool)
        (Format.asprintf "equal %s %s"
           (Olog.Level.to_string level)
           (Olog.Level.to_string level))
        true
        (Olog.Level.equal level level))
    all_levels

let test_equal_different () =
  Alcotest.(check bool)
    "Trace <> Fatal" false
    (Olog.Level.equal Olog.Level.Trace Olog.Level.Fatal)

let yojson_testable =
  Alcotest.testable
    (fun fmt j -> Format.fprintf fmt "%s" (Yojson.Safe.to_string j))
    (fun a b -> Yojson.Safe.equal a b)

let result_yojson_level = Alcotest.result level_testable Alcotest.string

let test_to_yojson () =
  List.iter2
    (fun level s ->
      Alcotest.(check yojson_testable)
        ("to_yojson " ^ s) (`String s)
        (Olog.Level.to_yojson level))
    all_levels all_strings

let test_of_yojson_roundtrip () =
  List.iter
    (fun level ->
      Alcotest.(check result_yojson_level)
        (Format.asprintf "roundtrip %s" (Olog.Level.to_string level))
        (Ok level)
        (Olog.Level.of_yojson (Olog.Level.to_yojson level)))
    all_levels

let test_of_yojson_invalid () =
  Alcotest.(check bool)
    "of_yojson int is Error" true
    (Result.is_error (Olog.Level.of_yojson (`Int 42)))

let () =
  Alcotest.run "Olog.Level"
    [
      ( "to_string",
        [ Alcotest.test_case "all variants" `Quick test_to_string_all_variants ]
      );
      ( "of_string",
        [
          Alcotest.test_case "valid" `Quick test_of_string_valid;
          Alcotest.test_case "case insensitive" `Quick
            test_of_string_case_insensitive;
          Alcotest.test_case "invalid" `Quick test_of_string_invalid;
        ] );
      ( "compare",
        [
          Alcotest.test_case "ordering" `Quick test_compare_ordering;
          Alcotest.test_case "equal" `Quick test_compare_equal;
        ] );
      ( "equal",
        [
          Alcotest.test_case "same" `Quick test_equal_same;
          Alcotest.test_case "different" `Quick test_equal_different;
        ] );
      ( "yojson",
        [
          Alcotest.test_case "to_yojson" `Quick test_to_yojson;
          Alcotest.test_case "roundtrip" `Quick test_of_yojson_roundtrip;
          Alcotest.test_case "invalid" `Quick test_of_yojson_invalid;
        ] );
    ]
