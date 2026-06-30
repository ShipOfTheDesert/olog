type t = String of string | Int of int | Float of float | Bool of bool | Null

(* Render a float as the shortest decimal string that parses back to the same
   value: try increasing precision and keep the first that round-trips. This is
   lossless (FR4) without printing noise digits for common values. Float.equal
   is NaN-safe (it equates nan with nan) and distinguishes -0.0 from 0.0, so
   the IEEE specials ("nan"/"inf"/"-inf"/"-0") round-trip too. *)
let float_to_string f =
  let round_trips s = Float.equal (float_of_string s) f in
  let s15 = Printf.sprintf "%.15g" f in
  if round_trips s15 then s15
  else
    let s16 = Printf.sprintf "%.16g" f in
    if round_trips s16 then s16 else Printf.sprintf "%.17g" f

let string s = String s
let int n = Int n
let float f = if Float.is_finite f then Float f else String (float_to_string f)
let bool b = Bool b
let null = Null

let to_string = function
  | String s -> s
  | Int n -> string_of_int n
  | Float f -> float_to_string f
  | Bool b -> string_of_bool b
  | Null -> "null"

let to_yojson = function
  | String s -> `String s
  | Int n -> `Int n
  | Float f -> `Float f
  | Bool b -> `Bool b
  | Null -> `Null

let of_yojson = function
  | `String s -> Ok (String s)
  | `Int n -> Ok (Int n)
  | `Float f -> Ok (float f)
  | `Bool b -> Ok (Bool b)
  | `Null -> Ok Null
  | `List _ -> Error "unsupported JSON type: array"
  | `Assoc _ -> Error "unsupported JSON type: object"
  | `Intlit _ -> Error "unsupported JSON type: intlit"
  | `Tuple _ -> Error "unsupported JSON type: tuple"
  | `Variant _ -> Error "unsupported JSON type: variant"
