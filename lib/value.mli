(** Structured log field values. *)

(** The type of values that can appear in structured log fields. The type is
    [private]: construct values through the smart constructors below (which gate
    the [Float] case so it can only ever hold a finite float), but pattern-match
    them freely — the constructors stay visible for deconstruction. *)
type t = private
  | String of string
  | Int of int
  | Float of float
  | Bool of bool
  | Null

val string : string -> t
(** [string s] is the string value [s]. *)

val int : int -> t
(** [int n] is the integer value [n]. *)

val float : float -> t
(** [float f] is the float value [f]. A non-finite [f] (NaN, [infinity],
    [neg_infinity]) has no standard-JSON representation, so it is coerced to a
    [String] carrying its plain-text form (["nan"], ["inf"], or ["-inf"] — the
    same rendering {!to_string} gives finite-or-not). A finite [f] is kept as a
    [Float], rendered losslessly by {!to_string} and {!to_yojson}. This keeps a
    [Float] always finite, so every formatter is total. The coercion is
    deliberately lossy: a coerced special is indistinguishable from a
    user-supplied [string "nan"], [string "inf"], or [string "-inf"]. *)

val bool : bool -> t
(** [bool b] is the boolean value [b]. *)

val null : t
(** [null] is the absent value. *)

val to_string : t -> string
(** [to_string v] returns a plain-text representation of [v]: strings are
    returned as-is; integers and booleans as their decimal / literal form;
    [Null] as ["null"]. A [Float] is always finite (the {!float} constructor
    coerces non-finite inputs to a [String]), so it renders as the shortest
    decimal that parses back to the same value — lossless
    ([float_of_string (to_string (Float f))] equals [f]) — with negative zero as
    ["-0"] (distinct from ["0"]). The IEEE specials still surface as ["nan"],
    ["inf"], and ["-inf"], but as [String] values produced at construction. *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson v] converts a value to its JSON representation. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** [of_yojson json] parses a value from JSON. Returns [Error msg] for
    unsupported JSON types (arrays, objects). *)
