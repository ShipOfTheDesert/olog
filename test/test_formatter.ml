(* test/test_formatter.ml
   Tests for Value.to_string and Formatter.{json,logfmt,text}.
   All tests are pure — no Eio scheduler required. *)

open Olog

(* A fixed timestamp for deterministic output.
   Ptime.to_rfc3339 ~tz_offset_s:0 Ptime.epoch = "1970-01-01T00:00:00Z" *)
let epoch = Ptime.epoch
let epoch_str = "1970-01-01T00:00:00Z"

let make_entry ?(fields = []) ?src_pos ?(level = Level.Info) msg =
  Entry.create ~level ~message:msg ~fields ?src_pos ~timestamp:epoch ()

(* ── Value.to_string ────────────────────────────────────────────────────── *)

let test_value_to_string () =
  let check label expected v =
    Alcotest.(check string) label expected (Value.to_string v)
  in
  check "String" "hello" (Value.String "hello");
  check "Int" "42" (Value.Int 42);
  check "Float" "2.5" (Value.Float 2.5);
  check "Bool true" "true" (Value.Bool true);
  check "Bool false" "false" (Value.Bool false);
  check "Null" "null" Value.Null

(* ── Formatter.json helpers ─────────────────────────────────────────────── *)

(* Parse JSON from a JSON Lines string: confirm trailing newline, strip it,
   parse the remainder. *)
let parse_jsonl label s =
  let n = String.length s in
  if n = 0 || s.[n - 1] <> '\n' then
    Alcotest.failf "%s: JSON output does not end with '\\n'" label;
  Yojson.Safe.from_string (String.sub s 0 (n - 1))

let string_field label pairs key =
  match List.assoc_opt key pairs with
  | Some (`String s) -> s
  | Some other ->
      Alcotest.failf "%s: field %s expected string, got %s" label key
        (Yojson.Safe.to_string other)
  | None -> Alcotest.failf "%s: field %s missing" label key

(* ── Formatter.json ─────────────────────────────────────────────────────── *)

let test_json_ends_with_newline () =
  let result = Formatter.json (make_entry "x") in
  let n = String.length result in
  Alcotest.(check char) "ends with newline" '\n' result.[n - 1]

let test_json_fixed_keys () =
  let entry = make_entry "hello" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_fixed_keys" result in
  match json with
  | `Assoc pairs ->
      Alcotest.(check string)
        "timestamp" epoch_str
        (string_field "json_fixed_keys" pairs "timestamp");
      Alcotest.(check string)
        "level" "info"
        (string_field "json_fixed_keys" pairs "level");
      Alcotest.(check string)
        "message" "hello"
        (string_field "json_fixed_keys" pairs "message")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_fields_are_top_level () =
  let fields = [ ("count", Value.Int 5); ("tag", Value.String "web") ] in
  let entry = make_entry ~fields "req" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_fields" result in
  match json with
  | `Assoc pairs -> (
      (match List.assoc_opt "count" pairs with
      | Some (`Int 5) -> ()
      | _ -> Alcotest.fail "count missing or wrong");
      match List.assoc_opt "tag" pairs with
      | Some (`String "web") -> ()
      | _ -> Alcotest.fail "tag missing or wrong")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_no_fields_key () =
  (* Fields must be top-level keys, not nested under "fields". *)
  let entry = make_entry ~fields:[ ("k", Value.Int 1) ] "msg" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_no_fields_key" result in
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt "fields" pairs with
      | None -> ()
      | Some _ -> Alcotest.fail "unexpected 'fields' wrapper key")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_src_pos_present () =
  let src_pos = Some Entry.{ file = "foo.ml"; line = 42; col = 3 } in
  let entry = make_entry ?src_pos "trace" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_src_pos" result in
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt "src_pos" pairs with
      | Some (`Assoc sp) -> (
          (match List.assoc_opt "file" sp with
          | Some (`String "foo.ml") -> ()
          | _ -> Alcotest.fail "src_pos.file wrong");
          (match List.assoc_opt "line" sp with
          | Some (`Int 42) -> ()
          | _ -> Alcotest.fail "src_pos.line wrong");
          match List.assoc_opt "col" sp with
          | Some (`Int 3) -> ()
          | _ -> Alcotest.fail "src_pos.col wrong")
      | _ -> Alcotest.fail "src_pos missing or wrong")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_src_pos_absent () =
  let entry = make_entry "msg" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_src_pos_absent" result in
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt "src_pos" pairs with
      | None -> ()
      | Some _ -> Alcotest.fail "src_pos should be absent")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_all_value_types () =
  let fields =
    [
      ("s", Value.String "hi");
      ("n", Value.Int 7);
      ("f", Value.Float 2.5);
      ("b", Value.Bool false);
      ("z", Value.Null);
    ]
  in
  let entry = make_entry ~fields "vals" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_value_types" result in
  match json with
  | `Assoc pairs -> (
      (match List.assoc_opt "s" pairs with
      | Some (`String "hi") -> ()
      | _ -> Alcotest.fail "s wrong");
      (match List.assoc_opt "n" pairs with
      | Some (`Int 7) -> ()
      | _ -> Alcotest.fail "n wrong");
      (match List.assoc_opt "f" pairs with
      | Some (`Float 2.5) -> ()
      | _ -> Alcotest.fail "f wrong");
      (match List.assoc_opt "b" pairs with
      | Some (`Bool false) -> ()
      | _ -> Alcotest.fail "b wrong");
      match List.assoc_opt "z" pairs with
      | Some `Null -> ()
      | _ -> Alcotest.fail "z wrong")
  | _ -> Alcotest.fail "expected JSON object"

(* ── Formatter.logfmt ───────────────────────────────────────────────────── *)

let test_logfmt_ends_with_newline () =
  let result = Formatter.logfmt (make_entry "x") in
  let n = String.length result in
  Alcotest.(check char) "ends with newline" '\n' result.[n - 1]

let test_logfmt_minimal () =
  let entry = make_entry "hello" in
  let result = Formatter.logfmt entry in
  let expected = Printf.sprintf "ts=%s level=info msg=hello\n" epoch_str in
  Alcotest.(check string) "logfmt minimal" expected result

let test_logfmt_with_int_field () =
  let fields = [ ("n", Value.Int 7) ] in
  let entry = make_entry ~fields "req" in
  let result = Formatter.logfmt entry in
  let expected = Printf.sprintf "ts=%s level=info msg=req n=7\n" epoch_str in
  Alcotest.(check string) "logfmt int field" expected result

let test_logfmt_message_with_space () =
  (* Message containing whitespace must be double-quoted. *)
  let entry = make_entry "hello world" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=\"hello world\"\n" epoch_str
  in
  Alcotest.(check string) "logfmt quoted message" expected result

let test_logfmt_field_value_with_equals () =
  (* String value containing '=' must be double-quoted. *)
  let fields = [ ("kv", Value.String "a=b") ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=msg kv=\"a=b\"\n" epoch_str
  in
  Alcotest.(check string) "logfmt field with =" expected result

let test_logfmt_field_value_with_interior_quote () =
  (* String value containing '"' must be double-quoted with '"' escaped. *)
  let fields = [ ("q", Value.String "say \"hi\"") ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=msg q=\"say \\\"hi\\\"\"\n" epoch_str
  in
  Alcotest.(check string) "logfmt field with interior quote" expected result

let test_logfmt_fixed_key_order () =
  (* ts, level, msg must appear before structured fields. *)
  let fields = [ ("z", Value.Bool true) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let prefix = Printf.sprintf "ts=%s level=info msg=ev" epoch_str in
  let actual_prefix = String.sub result 0 (String.length prefix) in
  Alcotest.(check string) "fixed key prefix" prefix actual_prefix

let test_logfmt_bool_field () =
  (* Bool values must be rendered unquoted as "true" or "false". *)
  let fields = [ ("flag", Value.Bool true) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=ev flag=true\n" epoch_str
  in
  Alcotest.(check string) "logfmt bool field unquoted" expected result

let test_logfmt_null_field () =
  (* Null must render as the unquoted string "null". *)
  let fields = [ ("x", Value.Null) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let expected = Printf.sprintf "ts=%s level=info msg=ev x=null\n" epoch_str in
  Alcotest.(check string) "logfmt null field" expected result

let test_logfmt_with_float_field () =
  let fields = [ ("ratio", Value.Float 2.5) ] in
  let entry = make_entry ~fields "stat" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=stat ratio=2.5\n" epoch_str
  in
  Alcotest.(check string) "logfmt float field" expected result

(* ── Formatter.text ─────────────────────────────────────────────────────── *)

let test_text_ends_with_newline () =
  let result = Formatter.text (make_entry "x") in
  let n = String.length result in
  Alcotest.(check char) "ends with newline" '\n' result.[n - 1]

let test_text_minimal () =
  let entry = make_entry "hello" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO hello\n" epoch_str in
  Alcotest.(check string) "text minimal" expected result

let test_text_level_uppercase () =
  let entry = make_entry ~level:Level.Error "fail" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s ERROR fail\n" epoch_str in
  Alcotest.(check string) "text level upper" expected result

let test_text_with_fields () =
  let fields = [ ("n", Value.Int 3); ("ok", Value.Bool true) ] in
  let entry = make_entry ~fields "done" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO done n=3 ok=true\n" epoch_str in
  Alcotest.(check string) "text with fields" expected result

let test_text_null_field () =
  let fields = [ ("x", Value.Null) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO ev x=null\n" epoch_str in
  Alcotest.(check string) "text null field" expected result

let test_text_float_field () =
  let fields = [ ("ratio", Value.Float 2.5) ] in
  let entry = make_entry ~fields "stat" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO stat ratio=2.5\n" epoch_str in
  Alcotest.(check string) "text float field" expected result

(* ── Main ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Formatter"
    [
      ( "Value.to_string",
        [ Alcotest.test_case "all variants" `Quick test_value_to_string ] );
      ( "Formatter.json",
        [
          Alcotest.test_case "ends with newline" `Quick
            test_json_ends_with_newline;
          Alcotest.test_case "fixed keys" `Quick test_json_fixed_keys;
          Alcotest.test_case "fields are top-level" `Quick
            test_json_fields_are_top_level;
          Alcotest.test_case "no 'fields' wrapper" `Quick
            test_json_no_fields_key;
          Alcotest.test_case "src_pos present" `Quick test_json_src_pos_present;
          Alcotest.test_case "src_pos absent" `Quick test_json_src_pos_absent;
          Alcotest.test_case "all value types" `Quick test_json_all_value_types;
        ] );
      ( "Formatter.logfmt",
        [
          Alcotest.test_case "ends with newline" `Quick
            test_logfmt_ends_with_newline;
          Alcotest.test_case "minimal entry" `Quick test_logfmt_minimal;
          Alcotest.test_case "int field" `Quick test_logfmt_with_int_field;
          Alcotest.test_case "quoted message" `Quick
            test_logfmt_message_with_space;
          Alcotest.test_case "field with =" `Quick
            test_logfmt_field_value_with_equals;
          Alcotest.test_case "field with interior quote" `Quick
            test_logfmt_field_value_with_interior_quote;
          Alcotest.test_case "fixed key order" `Quick
            test_logfmt_fixed_key_order;
          Alcotest.test_case "bool field unquoted" `Quick test_logfmt_bool_field;
          Alcotest.test_case "null field" `Quick test_logfmt_null_field;
          Alcotest.test_case "float field" `Quick test_logfmt_with_float_field;
        ] );
      ( "Formatter.text",
        [
          Alcotest.test_case "ends with newline" `Quick
            test_text_ends_with_newline;
          Alcotest.test_case "minimal entry" `Quick test_text_minimal;
          Alcotest.test_case "level uppercase" `Quick test_text_level_uppercase;
          Alcotest.test_case "with fields" `Quick test_text_with_fields;
          Alcotest.test_case "null field" `Quick test_text_null_field;
          Alcotest.test_case "float field" `Quick test_text_float_field;
        ] );
    ]
