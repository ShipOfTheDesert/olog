type t = Entry.t -> string

(* ── JSON Lines ─────────────────────────────────────────────────────────── *)

let src_pos_json (sp : Entry.src_pos) =
  `Assoc
    [ ("file", `String sp.file); ("line", `Int sp.line); ("col", `Int sp.col) ]

let json entry =
  let ts = Ptime.to_rfc3339 ~tz_offset_s:0 entry.Entry.timestamp in
  let base =
    [
      ("timestamp", `String ts);
      ("level", `String (Level.to_string entry.Entry.level));
      ("message", `String entry.Entry.message);
    ]
  in
  let fields =
    List.map (fun (k, v) -> (k, Value.to_yojson v)) entry.Entry.fields
  in
  let src =
    match entry.Entry.src_pos with
    | None -> []
    | Some p -> [ ("src_pos", src_pos_json p) ]
  in
  Yojson.Safe.to_string (`Assoc (base @ fields @ src)) ^ "\n"

(* ── logfmt ─────────────────────────────────────────────────────────────── *)

(* Quote a logfmt value if it contains whitespace, '=', or '"'.
   Interior '"' characters are escaped as '\"'. *)
let logfmt_quote s =
  let needs_quoting =
    String.exists
      (fun c -> c = ' ' || c = '\t' || c = '\n' || c = '=' || c = '"')
      s
  in
  if not needs_quoting then s
  else begin
    let buf = Buffer.create (String.length s + 2) in
    Buffer.add_char buf '"';
    String.iter
      (fun c ->
        if c = '"' then Buffer.add_string buf "\\\"" else Buffer.add_char buf c)
      s;
    Buffer.add_char buf '"';
    Buffer.contents buf
  end

let logfmt_value = function
  | Value.String s -> logfmt_quote s
  | Value.Int n -> string_of_int n
  | Value.Float f -> Printf.sprintf "%g" f
  | Value.Bool b -> string_of_bool b
  | Value.Null -> "null"

let logfmt entry =
  let ts = Ptime.to_rfc3339 ~tz_offset_s:0 entry.Entry.timestamp in
  let fixed =
    [
      "ts=" ^ ts;
      "level=" ^ Level.to_string entry.Entry.level;
      "msg=" ^ logfmt_quote entry.Entry.message;
    ]
  in
  let fields =
    List.map (fun (k, v) -> k ^ "=" ^ logfmt_value v) entry.Entry.fields
  in
  String.concat " " (fixed @ fields) ^ "\n"

(* ── human-readable text ─────────────────────────────────────────────────── *)

let text entry =
  let ts = Ptime.to_rfc3339 ~tz_offset_s:0 entry.Entry.timestamp in
  let level = String.uppercase_ascii (Level.to_string entry.Entry.level) in
  let fields =
    List.map (fun (k, v) -> k ^ "=" ^ Value.to_string v) entry.Entry.fields
  in
  String.concat " " ([ ts; level; entry.Entry.message ] @ fields) ^ "\n"
