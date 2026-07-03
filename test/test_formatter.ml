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
  check "String" "hello" (Value.string "hello");
  check "Int" "42" (Value.int 42);
  check "Float" "2.5" (Value.float 2.5);
  check "Bool true" "true" (Value.bool true);
  check "Bool false" "false" (Value.bool false);
  check "Null" "null" Value.null

(* Extract the rendered value of a space-separated [key=value] field from a
   single formatted line (logfmt or text). Float renderings never contain a
   space, so splitting on ' ' recovers the token intact. *)
let extract_field line key =
  let line = String.trim line in
  let prefix = key ^ "=" in
  match
    List.find_opt
      (fun t -> String.starts_with ~prefix t)
      (String.split_on_char ' ' line)
  with
  | Some t ->
      String.sub t (String.length prefix)
        (String.length t - String.length prefix)
  | None -> Alcotest.failf "field %s not found in %S" key line

(* Count newlines in a formatted record. A correct single-line record has
   exactly one (the trailing terminator); any interior newline is a forged
   second line. *)
let newline_count s =
  String.fold_left (fun n c -> if c = '\n' then n + 1 else n) 0 s

(* Floats whose round-trip the legacy [%g] (= [%.6g]) rendering destroys, plus
   the IEEE specials whose handling the chosen format must preserve. *)
let roundtrip_floats =
  [
    12.3456789;
    (* nanosecond-precision epoch float *)
    1_623_412_345.123456789;
    0.1 +. 0.2;
    Float.nan;
    Float.infinity;
    Float.neg_infinity;
    -0.0;
  ]

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

(* Return the nested ["fields"] object of a parsed JSON entry as an assoc list.
   Structured fields live under ["fields"], not as top-level keys (Decision 1). *)
let fields_obj label json =
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt "fields" pairs with
      | Some (`Assoc f) -> f
      | Some other ->
          Alcotest.failf "%s: 'fields' expected object, got %s" label
            (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s: 'fields' object missing" label)
  | _ -> Alcotest.failf "%s: expected JSON object" label

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

let test_json_fields_are_nested () =
  let fields = [ ("count", Value.int 5); ("tag", Value.string "web") ] in
  let entry = make_entry ~fields "req" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_fields" result in
  let pairs = fields_obj "json_fields" json in
  (match List.assoc_opt "count" pairs with
  | Some (`Int 5) -> ()
  | _ -> Alcotest.fail "count missing or wrong");
  match List.assoc_opt "tag" pairs with
  | Some (`String "web") -> ()
  | _ -> Alcotest.fail "tag missing or wrong"

let test_json_no_fields_key () =
  (* Fields are nested under "fields", not spliced as top-level keys
     (Decision 1, finding 4). *)
  let entry = make_entry ~fields:[ ("k", Value.int 1) ] "msg" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_no_fields_key" result in
  let pairs = fields_obj "json_no_fields_key" json in
  match List.assoc_opt "k" pairs with
  | Some (`Int 1) -> ()
  | _ -> Alcotest.fail "field 'k' not nested under 'fields'"

let test_json_no_duplicate_keys () =
  (* A user field named like a fixed key (level/message/timestamp) must not
     collide with it: fields nest under "fields", so top-level keys stay unique
     (FR1, finding 4). *)
  let fields =
    [
      ("level", Value.string "custom");
      ("message", Value.string "m2");
      ("timestamp", Value.string "t2");
    ]
  in
  let entry = make_entry ~fields "real" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_no_duplicate_keys" result in
  match json with
  | `Assoc pairs -> (
      let keys = List.sort String.compare (List.map fst pairs) in
      let rec dup = function
        | a :: (b :: _ as rest) -> if a = b then Some a else dup rest
        | _ -> None
      in
      match dup keys with
      | Some k ->
          Alcotest.failf "duplicate top-level JSON key %S in %S" k result
      | None -> ())
  | _ -> Alcotest.fail "expected JSON object"

let test_json_matches_entry_to_yojson () =
  (* One serializer per type: Formatter.json is exactly the JSON Lines rendering
     of Entry.to_yojson (FR1). *)
  let fields = [ ("count", Value.int 5); ("level", Value.string "x") ] in
  let src_pos = Some Entry.{ file = "a.ml"; line = 1; col = 2 } in
  let entry = make_entry ~fields ?src_pos "msg" in
  let expected = Yojson.Safe.to_string (Entry.to_yojson entry) ^ "\n" in
  Alcotest.(check string)
    "json equals Entry.to_yojson rendering" expected (Formatter.json entry)

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
      ("s", Value.string "hi");
      ("n", Value.int 7);
      ("f", Value.float 2.5);
      ("b", Value.bool false);
      ("z", Value.null);
    ]
  in
  let entry = make_entry ~fields "vals" in
  let result = Formatter.json entry in
  let json = parse_jsonl "json_value_types" result in
  let pairs = fields_obj "json_value_types" json in
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
  | _ -> Alcotest.fail "z wrong"

(* A non-finite float field built through the public [Value.float] smart
   constructor renders as a JSON string and [Formatter.json] never raises:
   every formatter is total (FR2). Replaces [test_json_non_finite_float_raises],
   which pinned the now-removed 0016 raising behaviour. *)
let test_json_total_non_finite () =
  List.iter
    (fun (f, expected) ->
      let entry = make_entry ~fields:[ ("v", Value.float f) ] "m" in
      let result =
        match Formatter.json entry with
        | line -> line
        | exception Yojson.Json_error msg ->
            Alcotest.failf "json raised on non-finite float %h: %s" f msg
      in
      let pairs =
        fields_obj "json_total_non_finite"
          (parse_jsonl "json_total_non_finite" result)
      in
      match List.assoc_opt "v" pairs with
      | Some (`String s) ->
          Alcotest.(check string) "non-finite renders as JSON string" expected s
      | _ ->
          Alcotest.failf "expected JSON string field for non-finite float %h" f)
    [
      (Float.nan, "nan"); (Float.infinity, "inf"); (Float.neg_infinity, "-inf");
    ]

(* The JSON parse path manufactures a non-finite [Float] from an overflowing
   literal ([1e999] parses to [`Float infinity]); [of_yojson] must coerce it
   through [Value.float] so a parsed [Value] never carries a non-finite [Float]
   (FR4). [Value.t] is [private], so pattern position stays open even though
   construction is gated. *)
let test_of_yojson_coerces_overflow () =
  let cases = [ ("1e999", "inf"); ("-1e999", "-inf") ] in
  List.iter
    (fun (literal, expected) ->
      let j = Yojson.Safe.from_string literal in
      match Value.of_yojson j with
      | Error m -> Alcotest.failf "of_yojson failed on %s: %s" literal m
      | Ok (Value.Float _) ->
          Alcotest.failf "of_yojson kept a non-finite Float for %s" literal
      | Ok (Value.String s) ->
          Alcotest.(check string)
            "overflow coerced to its string form" expected s
      | Ok ((Value.Int _ | Value.Bool _ | Value.Null) as v) ->
          Alcotest.failf "expected String %S, got %s" expected
            (Value.to_string v))
    cases

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
  let fields = [ ("n", Value.int 7) ] in
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
  let fields = [ ("kv", Value.string "a=b") ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=msg kv=\"a=b\"\n" epoch_str
  in
  Alcotest.(check string) "logfmt field with =" expected result

let test_logfmt_field_value_with_interior_quote () =
  (* String value containing '"' must be double-quoted with '"' escaped. *)
  let fields = [ ("q", Value.string "say \"hi\"") ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=msg q=\"say \\\"hi\\\"\"\n" epoch_str
  in
  Alcotest.(check string) "logfmt field with interior quote" expected result

let test_logfmt_fixed_key_order () =
  (* ts, level, msg must appear before structured fields. *)
  let fields = [ ("z", Value.bool true) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let prefix = Printf.sprintf "ts=%s level=info msg=ev" epoch_str in
  let actual_prefix = String.sub result 0 (String.length prefix) in
  Alcotest.(check string) "fixed key prefix" prefix actual_prefix

let test_logfmt_bool_field () =
  (* Bool values must be rendered unquoted as "true" or "false". *)
  let fields = [ ("flag", Value.bool true) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=ev flag=true\n" epoch_str
  in
  Alcotest.(check string) "logfmt bool field unquoted" expected result

let test_logfmt_null_field () =
  (* Null must render as the unquoted string "null". *)
  let fields = [ ("x", Value.null) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let expected = Printf.sprintf "ts=%s level=info msg=ev x=null\n" epoch_str in
  Alcotest.(check string) "logfmt null field" expected result

let test_logfmt_with_float_field () =
  let fields = [ ("ratio", Value.float 2.5) ] in
  let entry = make_entry ~fields "stat" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf "ts=%s level=info msg=stat ratio=2.5\n" epoch_str
  in
  Alcotest.(check string) "logfmt float field" expected result

let test_float_roundtrip_logfmt () =
  List.iter
    (fun f ->
      let entry = make_entry ~fields:[ ("v", Value.float f) ] "m" in
      let rendered = extract_field (Formatter.logfmt entry) "v" in
      let parsed = float_of_string rendered in
      (* Float.equal is NaN-safe (nan = nan) and distinguishes -0.0 from 0.0. *)
      if not (Float.equal parsed f) then
        Alcotest.failf "logfmt float not lossless: %h rendered %S parsed %h" f
          rendered parsed)
    roundtrip_floats

let test_logfmt_single_line_newline_field () =
  (* A field value containing a newline must not forge a second line: it is
     quoted and the newline backslash-escaped, so the record stays one line
     (FR2, finding 5). *)
  let fields = [ ("v", Value.string "line1\nline2") ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  Alcotest.(check int) "single line" 1 (newline_count result);
  Alcotest.(check string)
    "newline backslash-escaped inside quotes" "\"line1\\nline2\""
    (extract_field result "v")

let test_logfmt_backslash_quote_unambiguous () =
  (* A value containing both backslash and quote must parse back unambiguously:
     the backslash is escaped so the parser cannot read it as escaping the
     following quote (FR2, finding 5). *)
  let fields = [ ("v", Value.string {|a\b"c|}) ] in
  let entry = make_entry ~fields "msg" in
  let result = Formatter.logfmt entry in
  Alcotest.(check int) "single line" 1 (newline_count result);
  Alcotest.(check string)
    "backslash and quote both escaped" {|"a\\b\"c"|} (extract_field result "v")

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
  let fields = [ ("n", Value.int 3); ("ok", Value.bool true) ] in
  let entry = make_entry ~fields "done" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO done n=3 ok=true\n" epoch_str in
  Alcotest.(check string) "text with fields" expected result

let test_text_null_field () =
  let fields = [ ("x", Value.null) ] in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO ev x=null\n" epoch_str in
  Alcotest.(check string) "text null field" expected result

let test_text_float_field () =
  let fields = [ ("ratio", Value.float 2.5) ] in
  let entry = make_entry ~fields "stat" in
  let result = Formatter.text entry in
  let expected = Printf.sprintf "%s INFO stat ratio=2.5\n" epoch_str in
  Alcotest.(check string) "text float field" expected result

let test_float_roundtrip_text () =
  List.iter
    (fun f ->
      let entry = make_entry ~fields:[ ("v", Value.float f) ] "m" in
      let rendered = extract_field (Formatter.text entry) "v" in
      let parsed = float_of_string rendered in
      if not (Float.equal parsed f) then
        Alcotest.failf "text float not lossless: %h rendered %S parsed %h" f
          rendered parsed)
    roundtrip_floats

let test_text_single_line_newline_message () =
  (* A message containing a newline must not forge a second line: the newline is
     escaped so the record stays one readable line (FR3, finding 5). text is
     pretty, not reversible — only line-splitters are escaped. *)
  let entry = make_entry "line1\nline2" in
  let result = Formatter.text entry in
  Alcotest.(check int) "single line" 1 (newline_count result);
  Alcotest.(check string)
    "newline escaped in message"
    (Printf.sprintf "%s INFO line1\\nline2\n" epoch_str)
    result

(* ── Property round-trip tests (NFR1) ────────────────────────────────────────

   The regression guard for findings 4–6: over generated entries, [json] and
   [logfmt] verify a full format→parse round-trip; [text] verifies only its
   weaker contract — one line per entry and lossless floats (FR3 / Decision 2:
   text is pretty, not reversible).

   Bootstrap note (bootstrap-feature-tdd-exception): this is the project's first
   QCheck suite. The invariants are already structurally true — Tasks 1–3 fixed
   the formatters — so there is no red phase to observe without re-breaking the
   implementation. The wiring of the property harness is the state change being
   validated. *)

(* ── Generators ─────────────────────────────────────────────────────────────

   Messages, field values, and field *keys* all carry the adversarial content
   the findings concern (newlines, quotes, backslashes, whitespace, '=',
   control bytes, edge floats). Keys additionally include the exact fixed
   strings ts/level/msg: FR1 (Feature 0018) requires that an arbitrary key
   keeps a logfmt record one unambiguous line and cannot shadow or duplicate
   a fixed token. *)

let fixed_logfmt_keys = [ "ts"; "level"; "msg" ]

let gen_text_char =
  let open QCheck.Gen in
  oneof_weighted
    [
      (5, char_range 'a' 'z');
      (3, printable);
      (* line-splitters and escape-grammar characters, plus two C0 controls that
         the formatters pass through literally (Task 3 reflection): they must
         still round-trip without forging a line. *)
      (4, oneof_list [ '\n'; '\r'; '\t'; '"'; '\\'; ' '; '='; '\000'; '\031' ]);
    ]

let gen_str =
  QCheck.Gen.string_size ~gen:gen_text_char (QCheck.Gen.int_range 0 12)

(* Keys mix safe identifiers, fully adversarial strings (same alphabet as
   values, including the empty key), and the exact fixed keys. *)
let gen_key =
  let open QCheck.Gen in
  let ident_char =
    oneof
      [ char_range 'a' 'z'; char_range 'A' 'Z'; char_range '0' '9'; return '_' ]
  in
  oneof_weighted
    [
      (5, string_size ~gen:ident_char (int_range 1 6));
      (3, string_size ~gen:gen_text_char (int_range 0 6));
      (2, oneof_list fixed_logfmt_keys);
    ]

(* Key generator for the key-focused logfmt property: adversarial and
   fixed-key content only, so every generated field stresses the key grammar
   rather than occasionally hitting it. *)
let gen_adversarial_key =
  let open QCheck.Gen in
  oneof_weighted
    [
      (3, string_size ~gen:gen_text_char (int_range 0 6));
      (2, oneof_list fixed_logfmt_keys);
    ]

(* Edge-case floats for the value generators; [special_floats] (below) adds the
   non-finite IEEE values. The split is for readability only: post-0017
   [Value.float] coerces a non-finite input to its string form at construction,
   so a special never reaches [json] as a non-finite [Float] and every generator
   may include them ([specials:true]). *)
let finite_edge_floats =
  [
    0.0;
    -0.0;
    1.1;
    12.3456789;
    1_623_412_345.123456789;
    0.1 +. 0.2;
    3.141592653589793;
    4.9e-324;
    1.7976931348623157e308;
    -2.5e-10;
  ]

let special_floats = [ Float.nan; Float.infinity; Float.neg_infinity ]

let gen_value ~specials =
  let open QCheck.Gen in
  let float_pool =
    if specials then finite_edge_floats @ special_floats else finite_edge_floats
  in
  oneof_weighted
    [
      (4, map (fun s -> Value.string s) gen_str);
      (3, map (fun n -> Value.int n) (int_range (-1_000_000_000) 1_000_000_000));
      (3, map (fun f -> Value.float f) (oneof_list float_pool));
      (2, map (fun b -> Value.bool b) bool);
      (1, return Value.null);
    ]

let gen_src_pos =
  let open QCheck.Gen in
  option
    (map3
       (fun file line col -> Entry.{ file; line; col })
       (string_size ~gen:(char_range 'a' 'z') (int_range 1 8))
       (int_range 0 100_000) (int_range 0 200))

let gen_entry ~gen_field_key ~min_fields ~specials =
  let open QCheck.Gen in
  let gen_ts =
    map
      (fun n ->
        match Ptime.of_span (Ptime.Span.of_int_s n) with
        | Some p -> p
        (* Unreachable: 0..~4.1e9 s sits well inside Ptime's range. [failwith]
           (not [Alcotest.fail]) so QCheck reports a generator crash rather than
           a phantom counterexample (qcheck-generator-failwith). *)
        | None ->
            failwith "gen_entry: unreachable — timestamp out of Ptime range")
      (int_range 0 4_102_444_800)
  in
  gen_ts >>= fun timestamp ->
  oneof_list
    [
      Level.Trace; Level.Debug; Level.Info; Level.Warn; Level.Error; Level.Fatal;
    ]
  >>= fun level ->
  gen_str >>= fun message ->
  list_size (int_range min_fields 5) (pair gen_field_key (gen_value ~specials))
  >>= fun fields ->
  gen_src_pos >>= fun src_pos ->
  return (Entry.create ~level ~message ~fields ?src_pos ~timestamp ())

let print_entry e =
  let field (k, v) = Printf.sprintf "%S=%S" k (Value.to_string v) in
  Printf.sprintf "{ts=%s level=%s msg=%S fields=[%s] src_pos=%b}"
    (Ptime.to_rfc3339 ~tz_offset_s:0 e.Entry.timestamp)
    (Level.to_string e.Entry.level)
    e.Entry.message
    (String.concat "; " (List.map field e.Entry.fields))
    (Option.is_some e.Entry.src_pos)

let arb_entry ~specials =
  QCheck.make ~print:print_entry
    (gen_entry ~gen_field_key:gen_key ~min_fields:0 ~specials)

(* Key-stress entries for the logfmt key property: at least one field, every
   key drawn from the adversarial pool. *)
let arb_entry_adversarial_keys =
  QCheck.make ~print:print_entry
    (gen_entry ~gen_field_key:gen_adversarial_key ~min_fields:1 ~specials:true)

(* ── Entry equality (NaN-aware) ──────────────────────────────────────────── *)

(* Float is compared with [Float.equal] (nan = nan, -0.0 <> 0.0). The remaining
   value arms carry no floats, so polymorphic [=] is safe there
   (float-safe-record-equality); enumerating them rather than using [| _ ->]
   keeps the match exhaustive, so a new [Value.t] constructor is a compile error
   here (exhaustive-variant-matching). *)
let value_equal a b =
  match a with
  | Value.Float x -> (
      match b with
      | Value.Float y -> Float.equal x y
      | Value.String _ | Value.Int _ | Value.Bool _ | Value.Null -> false)
  | Value.String _ | Value.Int _ | Value.Bool _ | Value.Null -> a = b

let fields_equal a b =
  List.length a = List.length b
  && List.for_all2
       (fun (k1, v1) (k2, v2) -> String.equal k1 k2 && value_equal v1 v2)
       a b

let src_pos_equal a b =
  match (a, b) with
  | None, None -> true
  | Some x, Some y ->
      String.equal x.Entry.file y.Entry.file
      && x.Entry.line = y.Entry.line
      && x.Entry.col = y.Entry.col
  | None, Some _ | Some _, None -> false

let entry_equal a b =
  Ptime.equal a.Entry.timestamp b.Entry.timestamp
  && Level.equal a.Entry.level b.Entry.level
  && String.equal a.Entry.message b.Entry.message
  && src_pos_equal a.Entry.src_pos b.Entry.src_pos
  && fields_equal a.Entry.fields b.Entry.fields

(* ── JSON test-side parser ───────────────────────────────────────────────── *)

let fail_parse label msg = failwith (Printf.sprintf "%s: %s" label msg)

let json_of_record label s =
  let n = String.length s in
  if n = 0 || s.[n - 1] <> '\n' then fail_parse label "missing trailing newline";
  Yojson.Safe.from_string (String.sub s 0 (n - 1))

let value_of_json label j =
  match Value.of_yojson j with
  | Ok v -> v
  | Error m -> fail_parse label ("Value.of_yojson: " ^ m)

let entry_of_json label j =
  match j with
  | `Assoc pairs ->
      let field k =
        match List.assoc_opt k pairs with
        | Some v -> v
        | None -> fail_parse label ("missing key " ^ k)
      in
      let timestamp =
        match field "timestamp" with
        | `String s -> (
            match Ptime.of_rfc3339 s with
            | Ok (p, _, _) -> p
            | Error _ -> fail_parse label ("bad timestamp " ^ s))
        | _ -> fail_parse label "timestamp not a string"
      in
      let level =
        match Level.of_yojson (field "level") with
        | Ok l -> l
        | Error m -> fail_parse label ("level: " ^ m)
      in
      let message =
        match field "message" with
        | `String s -> s
        | _ -> fail_parse label "message not a string"
      in
      let fields =
        match field "fields" with
        | `Assoc fs -> List.map (fun (k, jv) -> (k, value_of_json label jv)) fs
        | _ -> fail_parse label "fields not an object"
      in
      let src_pos =
        match List.assoc_opt "src_pos" pairs with
        | None -> None
        | Some (`Assoc sp) ->
            let int_of k =
              match List.assoc_opt k sp with
              | Some (`Int n) -> n
              | _ -> fail_parse label ("src_pos." ^ k ^ " missing or not int")
            in
            let file =
              match List.assoc_opt "file" sp with
              | Some (`String s) -> s
              | _ -> fail_parse label "src_pos.file missing or not string"
            in
            Some Entry.{ file; line = int_of "line"; col = int_of "col" }
        | Some _ -> fail_parse label "src_pos not an object"
      in
      Entry.create ~level ~message ~fields ?src_pos ~timestamp ()
  | _ -> fail_parse label "entry not an object"

(* ── logfmt test-side parser ─────────────────────────────────────────────── *)

(* Reverse the logfmt escaping (Decision 4; keys joined the same grammar in
   Feature 0018). Tokens are separated by unquoted spaces; the key and the
   value position may each be quoted, and a quoted segment is unescaped with
   the inverse table (\\ → \, \" → ", \n → newline, \r → CR, \t → tab). An
   unquoted segment is literal — the formatter quotes any key or value
   containing an escape character, so an unquoted segment can never contain
   one. *)
let parse_logfmt_tokens line =
  let n = String.length line in
  let i = ref 0 in
  let parse_quoted () =
    incr i;
    (* opening quote *)
    let buf = Buffer.create 16 in
    let closed = ref false in
    while not !closed do
      if !i >= n then failwith "parse_logfmt: unterminated quote";
      match line.[!i] with
      | '\\' ->
          incr i;
          if !i >= n then failwith "parse_logfmt: trailing backslash";
          (match line.[!i] with
          | '\\' -> Buffer.add_char buf '\\'
          | '"' -> Buffer.add_char buf '"'
          | 'n' -> Buffer.add_char buf '\n'
          | 'r' -> Buffer.add_char buf '\r'
          | 't' -> Buffer.add_char buf '\t'
          | c -> failwith (Printf.sprintf "parse_logfmt: bad escape \\%c" c));
          incr i
      | '"' ->
          closed := true;
          incr i
      | c ->
          Buffer.add_char buf c;
          incr i
    done;
    Buffer.contents buf
  in
  let toks = ref [] in
  while !i < n do
    while !i < n && line.[!i] = ' ' do
      incr i
    done;
    if !i < n then begin
      let key =
        if line.[!i] = '"' then parse_quoted ()
        else begin
          let kstart = !i in
          while !i < n && line.[!i] <> '=' do
            incr i
          done;
          String.sub line kstart (!i - kstart)
        end
      in
      if !i >= n || line.[!i] <> '=' then
        failwith "parse_logfmt: key without '='";
      incr i;
      (* skip '=' *)
      let value =
        if !i < n && line.[!i] = '"' then parse_quoted ()
        else begin
          let vstart = !i in
          while !i < n && line.[!i] <> ' ' do
            incr i
          done;
          String.sub line vstart (!i - vstart)
        end
      in
      toks := (key, value) :: !toks
    end
  done;
  List.rev !toks

(* logfmt is untyped: every value is rendered to a string, so the round-trip is
   at the rendering level — the parser recovers each value's [Value.to_string]
   form and the message verbatim. src_pos is not emitted by logfmt and so is not
   part of its contract. *)
type logfmt_norm = {
  lts : string;
  llevel : string;
  lmsg : string;
  lfields : (string * string) list;
}

(* The oracle encodes the key contract (oracle-encodes-contract-not-library-
   default): an exact fixed-key match is renamed with the machine-detectable
   [olog.] prefix (Feature 0018 Decision 1); every other key passes through
   untouched. *)
let logfmt_field_key k = if List.mem k fixed_logfmt_keys then "olog." ^ k else k

let logfmt_norm_of_entry e =
  {
    lts = Ptime.to_rfc3339 ~tz_offset_s:0 e.Entry.timestamp;
    llevel = Level.to_string e.Entry.level;
    lmsg = e.Entry.message;
    lfields =
      List.map
        (fun (k, v) -> (logfmt_field_key k, Value.to_string v))
        e.Entry.fields;
  }

let parse_logfmt s =
  let n = String.length s in
  if n = 0 || s.[n - 1] <> '\n' then
    failwith "parse_logfmt: missing trailing newline";
  match parse_logfmt_tokens (String.sub s 0 (n - 1)) with
  | ("ts", lts) :: ("level", llevel) :: ("msg", lmsg) :: rest ->
      { lts; llevel; lmsg; lfields = rest }
  | _ -> failwith "parse_logfmt: unexpected fixed-key layout"

(* A user field named exactly like a fixed key cannot shadow or duplicate the
   fixed token: it is renamed with the [olog.] prefix (FR1, Feature 0018
   Decision 1). A key already inside the [olog.] namespace passes through
   untouched — the rename targets exact fixed-key matches only, so the pinned
   line deliberately shows the resulting benign user-key alias. Defined here
   (not in the unit-test section) because it reuses [parse_logfmt_tokens] to
   assert the parsed token stream carries each fixed key exactly once. *)
let test_logfmt_fixed_key_collision () =
  let fields =
    [
      ("ts", Value.string "x");
      ("level", Value.string "y");
      ("msg", Value.string "z");
      ("olog.ts", Value.string "w");
    ]
  in
  let entry = make_entry ~fields "ev" in
  let result = Formatter.logfmt entry in
  let expected =
    Printf.sprintf
      "ts=%s level=info msg=ev olog.ts=x olog.level=y olog.msg=z olog.ts=w\n"
      epoch_str
  in
  Alcotest.(check string) "fixed-key collisions renamed" expected result;
  let toks =
    parse_logfmt_tokens (String.sub result 0 (String.length result - 1))
  in
  List.iter
    (fun k ->
      let occurrences =
        List.length (List.filter (fun (k', _) -> String.equal k' k) toks)
      in
      Alcotest.(check int) (k ^ " appears exactly once") 1 occurrences)
    fixed_logfmt_keys

let logfmt_norm_equal a b =
  String.equal a.lts b.lts
  && String.equal a.llevel b.llevel
  && String.equal a.lmsg b.lmsg
  && List.length a.lfields = List.length b.lfields
  && List.for_all2
       (fun (k1, v1) (k2, v2) -> String.equal k1 k2 && String.equal v1 v2)
       a.lfields b.lfields

(* ── Properties ──────────────────────────────────────────────────────────── *)

let prop_json_roundtrip e =
  let parsed =
    entry_of_json "json_roundtrip"
      (json_of_record "json_roundtrip" (Formatter.json e))
  in
  entry_equal e parsed

let prop_logfmt_roundtrip e =
  let out = Formatter.logfmt e in
  (* one line (FR2) and a full rendering-level round-trip *)
  newline_count out = 1
  && logfmt_norm_equal (logfmt_norm_of_entry e) (parse_logfmt out)

let contains_sub ~sub s =
  let ls = String.length sub and l = String.length s in
  if ls = 0 then true
  else
    let rec go i =
      if i + ls > l then false
      else if String.equal (String.sub s i ls) sub then true
      else go (i + 1)
    in
    go 0

let prop_text_contract e =
  let out = Formatter.text e in
  (* text's weaker contract (FR3): exactly one line, and every float field is
     rendered losslessly and verbatim (text escapes only line-splitters, never a
     float's digits). *)
  newline_count out = 1
  && List.for_all
       (fun (_k, v) ->
         match v with
         | Value.Float f as v ->
             let r = Value.to_string v in
             contains_sub ~sub:r out && Float.equal (float_of_string r) f
         (* non-float fields carry no float to check; enumerated rather than
            [| _ ->] to stay exhaustive (exhaustive-variant-matching). *)
         | Value.String _ | Value.Int _ | Value.Bool _ | Value.Null -> true)
       e.Entry.fields

let qcheck_case name arb prop =
  QCheck_alcotest.to_alcotest (QCheck.Test.make ~count:1000 ~name arb prop)

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
          Alcotest.test_case "fields are nested" `Quick
            test_json_fields_are_nested;
          Alcotest.test_case "fields nested under 'fields'" `Quick
            test_json_no_fields_key;
          Alcotest.test_case "no duplicate keys" `Quick
            test_json_no_duplicate_keys;
          Alcotest.test_case "matches Entry.to_yojson" `Quick
            test_json_matches_entry_to_yojson;
          Alcotest.test_case "src_pos present" `Quick test_json_src_pos_present;
          Alcotest.test_case "src_pos absent" `Quick test_json_src_pos_absent;
          Alcotest.test_case "all value types" `Quick test_json_all_value_types;
          Alcotest.test_case "non-finite float total" `Quick
            test_json_total_non_finite;
        ] );
      ( "Value.of_yojson",
        [
          Alcotest.test_case "overflow coerced to string" `Quick
            test_of_yojson_coerces_overflow;
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
          Alcotest.test_case "float round-trip" `Quick
            test_float_roundtrip_logfmt;
          Alcotest.test_case "newline field stays one line" `Quick
            test_logfmt_single_line_newline_field;
          Alcotest.test_case "backslash and quote unambiguous" `Quick
            test_logfmt_backslash_quote_unambiguous;
          Alcotest.test_case "fixed-key collision renamed" `Quick
            test_logfmt_fixed_key_collision;
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
          Alcotest.test_case "float round-trip" `Quick test_float_roundtrip_text;
          Alcotest.test_case "newline message stays one line" `Quick
            test_text_single_line_newline_message;
        ] );
      ( "Property round-trip",
        [
          (* All three generators include the IEEE specials ([specials:true]):
             [Value.float] coerces a non-finite input to its string form at
             construction, so it never reaches [json] as a non-finite [Float]
             and the round-trip stays total (FR1, FR2, NFR3). *)
          qcheck_case "json round-trip" (arb_entry ~specials:true)
            prop_json_roundtrip;
          qcheck_case "logfmt round-trip" (arb_entry ~specials:true)
            prop_logfmt_roundtrip;
          qcheck_case "logfmt key round-trip" arb_entry_adversarial_keys
            prop_logfmt_roundtrip;
          qcheck_case "text contract" (arb_entry ~specials:true)
            prop_text_contract;
        ] );
    ]
