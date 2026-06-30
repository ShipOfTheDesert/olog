let yojson_testable =
  Alcotest.testable
    (fun fmt j -> Format.fprintf fmt "%s" (Yojson.Safe.to_string j))
    (fun a b -> Yojson.Safe.equal a b)

(* A fixed timestamp for deterministic tests: 2024-01-15T10:30:00Z *)
let test_timestamp =
  match Ptime.of_date_time ((2024, 1, 15), ((10, 30, 0), 0)) with
  | Some t -> t
  | None -> failwith "invalid test timestamp"

let test_create_minimal () =
  let entry =
    Olog.Entry.create ~level:Olog.Level.Info ~message:"hello"
      ~timestamp:test_timestamp ()
  in
  Alcotest.(check string) "message" "hello" entry.message;
  Alcotest.(check bool)
    "level is Info" true
    (Olog.Level.equal entry.level Olog.Level.Info);
  Alcotest.(check bool) "no fields" true (entry.fields = []);
  Alcotest.(check bool) "no src_pos" true (entry.src_pos = None)

let test_create_with_all_fields () =
  let src : Olog.Entry.src_pos = { file = "test.ml"; line = 42; col = 5 } in
  let fields = [ ("key", Olog.Value.string "val") ] in
  let entry =
    Olog.Entry.create ~level:Olog.Level.Error ~message:"boom" ~fields
      ~src_pos:src ~timestamp:test_timestamp ()
  in
  Alcotest.(check string) "message" "boom" entry.message;
  Alcotest.(check bool) "has fields" true (entry.fields = fields);
  Alcotest.(check bool) "has src_pos" true (entry.src_pos = Some src)

let test_create_fields_upsert () =
  let fields =
    [
      ("a", Olog.Value.int 1); ("b", Olog.Value.int 2); ("a", Olog.Value.int 3);
    ]
  in
  let entry =
    Olog.Entry.create ~level:Olog.Level.Debug ~message:"upsert" ~fields
      ~timestamp:test_timestamp ()
  in
  (* Last occurrence of "a" should win *)
  let a_val = List.assoc "a" entry.fields in
  Alcotest.(check yojson_testable)
    "upsert: a = 3" (`Int 3)
    (Olog.Value.to_yojson a_val);
  (* "b" should still be present *)
  let b_val = List.assoc "b" entry.fields in
  Alcotest.(check yojson_testable)
    "upsert: b = 2" (`Int 2)
    (Olog.Value.to_yojson b_val)

let test_to_yojson_minimal () =
  let entry =
    Olog.Entry.create ~level:Olog.Level.Info ~message:"hi"
      ~timestamp:test_timestamp ()
  in
  let json = Olog.Entry.to_yojson entry in
  let assoc =
    match json with `Assoc a -> a | _ -> Alcotest.fail "expected JSON object"
  in
  Alcotest.(check bool) "has timestamp" true (List.mem_assoc "timestamp" assoc);
  Alcotest.(check bool) "has level" true (List.mem_assoc "level" assoc);
  Alcotest.(check bool) "has message" true (List.mem_assoc "message" assoc);
  Alcotest.(check bool) "has fields" true (List.mem_assoc "fields" assoc);
  Alcotest.(check bool) "no src_pos" false (List.mem_assoc "src_pos" assoc);
  Alcotest.(check yojson_testable)
    "level value" (`String "info") (List.assoc "level" assoc);
  Alcotest.(check yojson_testable)
    "message value" (`String "hi")
    (List.assoc "message" assoc)

let test_to_yojson_with_src_pos () =
  let src : Olog.Entry.src_pos = { file = "foo.ml"; line = 10; col = 3 } in
  let entry =
    Olog.Entry.create ~level:Olog.Level.Warn ~message:"w" ~src_pos:src
      ~timestamp:test_timestamp ()
  in
  let json = Olog.Entry.to_yojson entry in
  let assoc =
    match json with `Assoc a -> a | _ -> Alcotest.fail "expected JSON object"
  in
  Alcotest.(check bool) "has src_pos" true (List.mem_assoc "src_pos" assoc);
  let sp =
    match List.assoc "src_pos" assoc with
    | `Assoc a -> a
    | _ -> Alcotest.fail "src_pos should be object"
  in
  Alcotest.(check yojson_testable)
    "file" (`String "foo.ml") (List.assoc "file" sp);
  Alcotest.(check yojson_testable) "line" (`Int 10) (List.assoc "line" sp);
  Alcotest.(check yojson_testable) "col" (`Int 3) (List.assoc "col" sp)

let test_to_yojson_timestamp_iso8601 () =
  let entry =
    Olog.Entry.create ~level:Olog.Level.Info ~message:"ts"
      ~timestamp:test_timestamp ()
  in
  let json = Olog.Entry.to_yojson entry in
  let ts_str =
    match json with
    | `Assoc a -> (
        match List.assoc "timestamp" a with
        | `String s -> s
        | _ -> Alcotest.fail "timestamp should be string")
    | _ -> Alcotest.fail "expected JSON object"
  in
  (* Must contain T separator and end with Z for UTC *)
  Alcotest.(check bool) "contains T" true (String.contains ts_str 'T');
  Alcotest.(check bool)
    "ends with Z" true
    (String.get ts_str (String.length ts_str - 1) = 'Z')

let test_to_yojson_fields () =
  let fields =
    [ ("count", Olog.Value.int 5); ("name", Olog.Value.string "test") ]
  in
  let entry =
    Olog.Entry.create ~level:Olog.Level.Debug ~message:"f" ~fields
      ~timestamp:test_timestamp ()
  in
  let json = Olog.Entry.to_yojson entry in
  let fields_json =
    match json with
    | `Assoc a -> (
        match List.assoc "fields" a with
        | `Assoc f -> f
        | _ -> Alcotest.fail "fields should be object")
    | _ -> Alcotest.fail "expected JSON object"
  in
  Alcotest.(check yojson_testable)
    "count field" (`Int 5)
    (List.assoc "count" fields_json);
  Alcotest.(check yojson_testable)
    "name field" (`String "test")
    (List.assoc "name" fields_json)

let () =
  Alcotest.run "Entry"
    [
      ( "create",
        [
          Alcotest.test_case "minimal" `Quick test_create_minimal;
          Alcotest.test_case "all fields" `Quick test_create_with_all_fields;
          Alcotest.test_case "upsert" `Quick test_create_fields_upsert;
        ] );
      ( "to_yojson",
        [
          Alcotest.test_case "minimal" `Quick test_to_yojson_minimal;
          Alcotest.test_case "with src_pos" `Quick test_to_yojson_with_src_pos;
          Alcotest.test_case "timestamp iso8601" `Quick
            test_to_yojson_timestamp_iso8601;
          Alcotest.test_case "fields" `Quick test_to_yojson_fields;
        ] );
    ]
