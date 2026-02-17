(** Log severity levels. *)

(** The type of log severity levels, ordered from least to most severe. *)
type t = Trace | Debug | Info | Warn | Error | Fatal

val compare : t -> t -> int
(** [compare a b] returns a negative integer if [a] is less severe than [b],
    zero if equal, and a positive integer if more severe. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same level. *)

val to_string : t -> string
(** [to_string level] returns the lowercase string representation. E.g.,
    [to_string Info] is ["info"]. *)

val of_string : string -> (t, string) result
(** [of_string s] parses a level from a case-insensitive string. Returns
    [Error s] if [s] is not a valid level name. *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson level] returns [`String (to_string level)]. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** [of_yojson json] parses a level from a JSON string value. *)
