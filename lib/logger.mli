(** Asynchronous structured logger backed by a bounded queue and a dedicated
    worker fiber.

    A logger decouples log callers from I/O: {!log} enqueues an {!Entry.t} and
    returns immediately. A worker daemon fiber drains the queue and dispatches
    entries to {!sink} implementations in the order they appear in {!Config.t}.
    If the queue is full, entries are dropped and counted — callers are never
    suspended.

    The worker's lifetime is tied to the [Eio.Switch.t] passed to {!create}; it
    terminates automatically when the switch closes. *)

type sink = {
  emit : Entry.t -> unit;
      (** Called by the worker fiber for each log entry. May perform I/O. If
          this raises, the worker catches the exception and continues. *)
  flush : unit -> unit;
      (** Flush any buffered output. Called after all preceding entries have
          been emitted when {!val:flush} is invoked on the logger. *)
  close : unit -> unit;
      (** Release resources. Called once when the switch closes. Exceptions are
          caught and ignored. *)
}
(** An output destination — a record of three functions handling emission,
    flushing, and teardown. Compose multiple sinks via {!Config.sinks}. *)

module Config : sig
  type t = {
    min_level : Level.t;
        (** Minimum level accepted. Entries below this level are discarded
            before any queue allocation. *)
    queue_depth : int;
        (** Maximum number of entries in the async queue. When full, new entries
            are dropped and the drop counter is incremented. Must be a positive
            integer. *)
    sinks : sink list;
        (** Output destinations, called in list order for each emitted entry. *)
  }

  val default : t
  (** [default] is [{min_level = Info; queue_depth = 1024; sinks = []}]. *)
end

type diagnostics = {
  name : string;  (** Human-readable logger identifier. *)
  queue_depth : int;
      (** Current number of entries in the queue at snapshot time. *)
  queue_capacity : int;  (** Configured maximum queue size. *)
  drop_count : int;
      (** Total number of entries dropped since the logger was created. *)
}
(** A point-in-time snapshot of a logger's internal metrics. *)

type t
(** An asynchronous structured logger. Opaque — use {!create} to construct. *)

val create :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> Config.t -> string -> t
(** [create ~sw ~clock config name] creates a new logger named [name].
    Initialises a bounded queue of [config.queue_depth] entries, an atomic drop
    counter at zero, and forks a worker daemon fiber under [sw]. The worker
    drains the queue, calling each sink in [config.sinks] for every entry. When
    [sw] closes, the worker calls [sink.close ()] on each sink before
    terminating.

    @param sw The enclosing switch. The worker is tied to this lifetime.
    @param clock Eio realtime clock used to timestamp each entry at call time.
    @param config Logger configuration (level, queue depth, sinks).
    @param name Human-readable identifier, used in {!val:diagnostics}. *)

val is_enabled : t -> Level.t -> bool
(** [is_enabled logger level] returns [true] iff [level] is at or above the
    logger's configured minimum level.

    Use this to guard expensive field construction at call sites when callers
    build field lists before passing them to {!log}. *)

val log :
  t ->
  level:Level.t ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log logger ~level ~fields ~src_pos message] enqueues an {!Entry.t} for
    async emission.

    If [level] is below the logger's minimum level, returns immediately without
    allocating an [Entry.t]. If the queue is full, the entry is dropped and the
    drop counter is incremented — the calling fiber is never suspended.

    @param level Log severity.
    @param fields Structured key-value pairs (default [[]]).
    @param src_pos
      Source location, typically injected by a PPX (default [None]).
    @param message Human-readable log message. *)

val flush : t -> unit
(** [flush logger] suspends the calling fiber until all entries currently in the
    queue have been processed by the worker and each sink's [flush] function has
    been called.

    Safe to call concurrently with {!log}. *)

val diagnostics : t -> diagnostics
(** [diagnostics logger] returns a point-in-time snapshot of the logger's
    internal metrics. Safe to call from any fiber at any time. *)
