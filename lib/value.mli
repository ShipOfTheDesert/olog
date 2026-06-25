(** Structured log field values. *)

(** The type of values that can appear in structured log fields. *)
type t = String of string | Int of int | Float of float | Bool of bool | Null

val to_string : t -> string
(** [to_string v] returns a plain-text representation of [v]: strings are
    returned as-is; integers and booleans as their decimal / literal form;
    [Null] as ["null"]. Floats use the shortest decimal that parses back to the
    same value, so rendering is lossless
    ([float_of_string (to_string (Float f))] equals [f]); the IEEE specials
    render as ["nan"], ["inf"], and ["-inf"], and negative zero as ["-0"]
    (distinct from ["0"]). *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson v] converts a value to its JSON representation. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** [of_yojson json] parses a value from JSON. Returns [Error msg] for
    unsupported JSON types (arrays, objects). *)
