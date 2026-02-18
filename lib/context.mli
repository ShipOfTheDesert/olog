(** Fiber-local context for structured logging fields.

    A single fiber-local key stores an association list of [(string * Value.t)]
    pairs scoped to the current fiber. Use {!with_context} to add fields for the
    duration of a callback and {!current} to retrieve the accumulated fields in
    the current fiber.

    Context is isolated between fibers: a fiber forked inside [with_context]
    starts with an empty context. *)

type t = (string * Value.t) list
(** An association list of field name–value pairs representing the logging
    context for the current fiber. The list may contain duplicate keys;
    consumers should treat the last occurrence as authoritative. *)

val empty : t
(** The empty context — an empty association list. *)

val current : unit -> t
(** [current ()] returns the context fields in scope for the current
    continuation, or {!empty} if no {!with_context} handler is active.

    Safe to call anywhere in an OCaml 5 program; returns {!empty} when called
    outside any [with_context] scope or from a forked fiber. *)

val with_context : fields:(string * Value.t) list -> (unit -> 'a) -> 'a
(** [with_context ~fields f] runs [f] with [fields] merged into the current
    fiber-local context. Fields in [fields] override any existing fields with
    the same key (deeper context wins). The previous context is restored when
    [f] returns or raises.

    [with_context ~fields:[] f] is equivalent to [f ()]. *)
