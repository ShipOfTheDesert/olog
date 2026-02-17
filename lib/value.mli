(** Structured log field values. *)

(** The type of values that can appear in structured log fields. *)
type t = String of string | Int of int | Float of float | Bool of bool | Null

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson v] converts a value to its JSON representation. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** [of_yojson json] parses a value from JSON. Returns [Error msg] for
    unsupported JSON types (arrays, objects). *)
