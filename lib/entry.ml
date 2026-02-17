type src_pos = { file : string; line : int; col : int }

type t = {
  timestamp : Ptime.t;
  level : Level.t;
  message : string;
  fields : (string * Value.t) list;
  src_pos : src_pos option;
}

let dedup_fields fields =
  let rev = List.rev fields in
  let seen = Hashtbl.create (List.length rev) in
  List.filter
    (fun (k, _) ->
      if Hashtbl.mem seen k then false
      else begin
        Hashtbl.add seen k ();
        true
      end)
    rev
  |> List.rev

let create ~level ~message ?(fields = []) ?src_pos ~timestamp () =
  { timestamp; level; message; fields = dedup_fields fields; src_pos }

let src_pos_to_yojson sp =
  `Assoc
    [ ("file", `String sp.file); ("line", `Int sp.line); ("col", `Int sp.col) ]

let to_yojson t =
  let ts = Ptime.to_rfc3339 ~tz_offset_s:0 t.timestamp in
  let fields_json =
    `Assoc (List.map (fun (k, v) -> (k, Value.to_yojson v)) t.fields)
  in
  let base =
    [
      ("timestamp", `String ts);
      ("level", Level.to_yojson t.level);
      ("message", `String t.message);
      ("fields", fields_json);
    ]
  in
  let assoc =
    match t.src_pos with
    | None -> base
    | Some sp -> base @ [ ("src_pos", src_pos_to_yojson sp) ]
  in
  `Assoc assoc
