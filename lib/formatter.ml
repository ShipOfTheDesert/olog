type t = Entry.t -> string

(* ── JSON Lines ─────────────────────────────────────────────────────────── *)

(* One JSON serializer per type: derive the line from [Entry.to_yojson] so the
   shape cannot drift from the canonical envelope (FR1, finding 4). Nesting
   fields under "fields" keeps top-level keys collision-free (Decision 1). *)
let json entry = Yojson.Safe.to_string (Entry.to_yojson entry) ^ "\n"

(* ── logfmt ─────────────────────────────────────────────────────────────── *)

(* Quote a logfmt value if it contains a character that would break
   tokenisation (whitespace, '='), split the line (newline, CR), or is itself
   part of the escape grammar ('"', '\'). When quoted, backslash, quote, and the
   control chars newline/CR/tab are backslash-escaped, so the value is exactly
   one line and a parser can reverse it unambiguously (FR2). Keeping '\' a
   quoting trigger means an unquoted value never contains an escape character,
   so the reverse is simply: unquoted = literal, quoted = unescape. *)
let logfmt_quote s =
  let needs_quoting =
    String.exists
      (fun c ->
        c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '=' || c = '"'
        || c = '\\')
      s
  in
  if not needs_quoting then s
  else begin
    let buf = Buffer.create (String.length s + 2) in
    Buffer.add_char buf '"';
    String.iter
      (fun c ->
        match c with
        | '\\' -> Buffer.add_string buf "\\\\"
        | '"' -> Buffer.add_string buf "\\\""
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c -> Buffer.add_char buf c)
      s;
    Buffer.add_char buf '"';
    Buffer.contents buf
  end

(* A field key joins the same quote/escape grammar as values, so the
   single-rule parser (unquoted = literal, quoted = unescape) covers the whole
   token stream. An exact fixed-key match is renamed first with the
   machine-detectable "olog." prefix so a user field cannot shadow or duplicate
   the fixed ts/level/msg tokens (FR1, Feature 0018 Decision 1); keys already
   inside the olog. namespace pass through untouched. *)
let logfmt_key k =
  let k = match k with "ts" | "level" | "msg" -> "olog." ^ k | _ -> k in
  logfmt_quote k

let logfmt_value = function
  | Value.String s -> logfmt_quote s
  | Value.Int n -> string_of_int n
  (* Share the lossless float rendering; the result never needs quoting. *)
  | Value.Float _ as v -> Value.to_string v
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
    List.map
      (fun (k, v) -> logfmt_key k ^ "=" ^ logfmt_value v)
      entry.Entry.fields
  in
  String.concat " " (fixed @ fields) ^ "\n"

(* ── human-readable text ─────────────────────────────────────────────────── *)

(* text is human-readable and one line per entry (FR3); it is deliberately not a
   reversible format. Escape only the line-splitters (newline, CR) so a
   user-controlled newline cannot forge a second line — nothing else is quoted
   or delimited. *)
let text_escape s =
  if not (String.exists (fun c -> c = '\n' || c = '\r') s) then s
  else begin
    let buf = Buffer.create (String.length s) in
    String.iter
      (fun c ->
        match c with
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | c -> Buffer.add_char buf c)
      s;
    Buffer.contents buf
  end

let text entry =
  let ts = Ptime.to_rfc3339 ~tz_offset_s:0 entry.Entry.timestamp in
  let level = String.uppercase_ascii (Level.to_string entry.Entry.level) in
  let fields =
    List.map
      (fun (k, v) -> text_escape (k ^ "=" ^ Value.to_string v))
      entry.Entry.fields
  in
  String.concat " " ([ ts; level; text_escape entry.Entry.message ] @ fields)
  ^ "\n"
