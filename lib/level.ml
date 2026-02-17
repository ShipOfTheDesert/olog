type t = Trace | Debug | Info | Warn | Error | Fatal

let to_int = function
  | Trace -> 0
  | Debug -> 1
  | Info -> 2
  | Warn -> 3
  | Error -> 4
  | Fatal -> 5

let compare a b = Int.compare (to_int a) (to_int b)
let equal a b = compare a b = 0

let to_string = function
  | Trace -> "trace"
  | Debug -> "debug"
  | Info -> "info"
  | Warn -> "warn"
  | Error -> "error"
  | Fatal -> "fatal"

let of_string s =
  match String.lowercase_ascii s with
  | "trace" -> Ok Trace
  | "debug" -> Ok Debug
  | "info" -> Ok Info
  | "warn" -> Ok Warn
  | "error" -> Ok Error
  | "fatal" -> Ok Fatal
  | _ -> Error s

let to_yojson t = `String (to_string t)

let of_yojson = function
  | `String s -> of_string s
  | json ->
      Error
        (Format.asprintf "expected a JSON string, got %s"
           (Yojson.Safe.to_string json))
