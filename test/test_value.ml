let yojson_testable =
  Alcotest.testable
    (fun fmt j -> Format.fprintf fmt "%s" (Yojson.Safe.to_string j))
    (fun a b -> Yojson.Safe.equal a b)

let value_testable =
  Alcotest.testable
    (fun fmt v ->
      Format.fprintf fmt "%s" (Yojson.Safe.to_string (Olog.Value.to_yojson v)))
    (fun a b ->
      Yojson.Safe.equal (Olog.Value.to_yojson a) (Olog.Value.to_yojson b))

let result_value_testable = Alcotest.result value_testable Alcotest.string

let test_to_yojson_string () =
  Alcotest.(check yojson_testable)
    "String to yojson" (`String "hello")
    (Olog.Value.to_yojson (Olog.Value.String "hello"))

let test_to_yojson_int () =
  Alcotest.(check yojson_testable)
    "Int to yojson" (`Int 42)
    (Olog.Value.to_yojson (Olog.Value.Int 42))

let test_to_yojson_float () =
  Alcotest.(check yojson_testable)
    "Float to yojson" (`Float 3.14)
    (Olog.Value.to_yojson (Olog.Value.Float 3.14))

let test_to_yojson_bool () =
  Alcotest.(check yojson_testable)
    "Bool to yojson" (`Bool true)
    (Olog.Value.to_yojson (Olog.Value.Bool true))

let test_to_yojson_null () =
  Alcotest.(check yojson_testable)
    "Null to yojson" `Null
    (Olog.Value.to_yojson Olog.Value.Null)

let test_of_yojson_roundtrip () =
  let cases = Olog.Value.[ String "x"; Int 0; Float 1.5; Bool false; Null ] in
  List.iter
    (fun v ->
      Alcotest.(check result_value_testable)
        "roundtrip" (Ok v)
        (Olog.Value.of_yojson (Olog.Value.to_yojson v)))
    cases

let test_of_yojson_unsupported () =
  let cases = [ `List [ `Int 1 ]; `Assoc [ ("k", `Int 1) ] ] in
  List.iter
    (fun j ->
      Alcotest.(check bool)
        "unsupported JSON is Error" true
        (Result.is_error (Olog.Value.of_yojson j)))
    cases

let () =
  Alcotest.run "Value"
    [
      ( "to_yojson",
        [
          Alcotest.test_case "string" `Quick test_to_yojson_string;
          Alcotest.test_case "int" `Quick test_to_yojson_int;
          Alcotest.test_case "float" `Quick test_to_yojson_float;
          Alcotest.test_case "bool" `Quick test_to_yojson_bool;
          Alcotest.test_case "null" `Quick test_to_yojson_null;
        ] );
      ( "of_yojson",
        [
          Alcotest.test_case "roundtrip" `Quick test_of_yojson_roundtrip;
          Alcotest.test_case "unsupported" `Quick test_of_yojson_unsupported;
        ] );
    ]
