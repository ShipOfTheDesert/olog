(** Immutable log entry records. *)

type src_pos = { file : string; line : int; col : int }
(** Source position information. *)

type t = {
  timestamp : Ptime.t;
  level : Level.t;
  message : string;
  fields : (string * Value.t) list;
  src_pos : src_pos option;
}
(** A single log entry. All fields are immutable. *)

val create :
  level:Level.t ->
  message:string ->
  ?fields:(string * Value.t) list ->
  ?src_pos:src_pos ->
  timestamp:Ptime.t ->
  unit ->
  t
(** [create ~level ~message ~timestamp ()] constructs a log entry. Pure function
    — performs no I/O. Duplicate keys in [fields] are resolved by keeping the
    last occurrence. *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson entry] serializes the entry to JSON. Timestamp is formatted as
    ISO 8601 UTC. [src_pos] is omitted if [None]. *)
