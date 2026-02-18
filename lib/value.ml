type t = String of string | Int of int | Float of float | Bool of bool | Null

let to_string = function
  | String s -> s
  | Int n -> string_of_int n
  | Float f -> Printf.sprintf "%g" f
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
  | `Float f -> Ok (Float f)
  | `Bool b -> Ok (Bool b)
  | `Null -> Ok Null
  | `List _ -> Error "unsupported JSON type: array"
  | `Assoc _ -> Error "unsupported JSON type: object"
  | `Intlit _ -> Error "unsupported JSON type: intlit"
  | `Tuple _ -> Error "unsupported JSON type: tuple"
  | `Variant _ -> Error "unsupported JSON type: variant"
