(** Asynchronous structured logger backed by a bounded queue and a dedicated
    worker fiber.

    A logger decouples log callers from I/O: {!log} enqueues an {!Entry.t} and
    returns immediately. A worker daemon fiber drains the queue and dispatches
    entries to {!sink} implementations in the order they appear in {!Config.t}.
    If the queue is full, entries are dropped and counted — callers are never
    suspended.

    Accounting is conservative: every entry accepted by {!log}/{!log_exn} — one
    at or above the configured minimum level — is either {e emitted} (counted in
    [diagnostics.emit_count]) or {e dropped} (counted in
    [diagnostics.drop_count], attributed to exactly one of the per-cause
    counters), never silently lost. This holds under concurrent load from many
    fibers and under switch cancellation. An entry counts as emitted at the
    moment the worker hands its batch to the sinks — the count is taken before
    the sinks run, so a delivery aborted mid-dispatch still counts as emitted; a
    per-sink failure is reported to process stderr, not re-queued.

    The worker's lifetime is tied to the [Eio.Switch.t] passed to {!create}; it
    terminates when {!shutdown} is called or when the switch closes. Call
    {!shutdown} before the switch closes to guarantee that all enqueued entries
    are delivered. If the switch closes without a prior {!shutdown}, the worker
    makes a best-effort attempt to drain remaining entries. *)

type sink = {
  name : string;
      (** Identifies the sink in the worker's fallback error reports. *)
  emit : Entry.t list -> (unit, string) result;
      (** Called by the worker fiber with a non-empty batch of entries, in
          enqueue order. May perform I/O. Expected failures are reported as
          [Error msg] covering the whole batch; the worker logs one fallback
          line to process stderr and continues with later entries — a failed
          batch is not retried. A sink that raises instead (a contract
          violation) is also tolerated — the worker reports it and survives —
          but [Eio.Cancel.Cancelled] is always re-raised, never swallowed. *)
  flush : unit -> (unit, string) result;
      (** Flush any buffered output. Called after all preceding entries have
          been emitted when {!val:flush} is invoked on the logger. Same
          error-reporting contract as {!emit}. *)
  close : unit -> (unit, string) result;
      (** Release resources. Called once when the switch closes. Same
          error-reporting contract as {!emit}. *)
}
(** An output destination — a record of a [name] and three functions handling
    emission, flushing, and teardown. Each operation reports expected failures
    as [Error msg] rather than raising. Compose multiple sinks via
    {!Config.sinks}. *)

(** Policy for handling a clock whose reading cannot be represented as a
    [Ptime.t]. *)
type timestamp_fallback =
  | Fail
      (** Probe the clock at {!create}; reject an already-broken clock by
          returning [Error]. *)
  | Mark_invalid
      (** On an unrepresentable timestamp, stamp [Ptime.epoch] and append the
          reserved field [("olog.invalid_timestamp", Value.bool true)]. *)

module Config : sig
  type t = private {
    min_level : Level.t;
        (** Minimum level accepted. Entries below this level are discarded
            before any queue allocation. *)
    queue_depth : int;
        (** Maximum number of entries in the async queue. When full, new entries
            are dropped and the drop counter is incremented. Always a positive
            integer (enforced by {!make}). *)
    sinks : sink list;
        (** Output destinations, called in list order for each emitted entry. *)
    timestamp_fallback : timestamp_fallback;
        (** Policy applied when the clock yields an unrepresentable timestamp.
        *)
  }
  (** Logger configuration. The record is [private]: construct values via
      {!make}, which validates [queue_depth]. *)

  val make :
    min_level:Level.t ->
    queue_depth:int ->
    sinks:sink list ->
    ?timestamp_fallback:timestamp_fallback ->
    unit ->
    (t, string) result
  (** [make ~min_level ~queue_depth ~sinks ?timestamp_fallback ()] builds a
      validated {!t}. Returns [Error] if [queue_depth < 1]. [timestamp_fallback]
      defaults to {!Mark_invalid}. *)
end

type diagnostics = {
  name : string;  (** Human-readable logger identifier. *)
  queue_depth : int;
      (** Current number of entries in the queue at snapshot time. *)
  queue_capacity : int;  (** Configured maximum queue size. *)
  emit_count : int;
      (** Total number of entries handed to the sinks since the logger was
          created, counted once per entry regardless of the number of sinks. A
          batch whose delivery fails still counts as emitted — the failure is
          reported to process stderr, not re-queued. *)
  drop_count : int;
      (** Total number of entries dropped since the logger was created. Equal to
          [drops_queue_full + drops_after_shutdown + drops_on_cancel] in every
          snapshot — the total is derived from the cause counters at snapshot
          time. *)
  drops_queue_full : int;
      (** Entries dropped because the queue was full when they were submitted
          (backpressure). *)
  drops_after_shutdown : int;
      (** Entries dropped because they were submitted after the logger had begun
          terminating — via {!shutdown} or switch cancellation. *)
  drops_on_cancel : int;
      (** Entries accepted but lost because the worker terminated without a
          graceful drain: switch cancellation whose best-effort drain was cut
          short, or an unexpected worker failure. *)
  is_shutdown : bool;
      (** [true] after {!shutdown} has been called. When [true], {!log} and
          {!log_exn} are no-ops and {!val:flush} returns immediately. *)
}
(** A point-in-time snapshot of a logger's internal metrics. Conservation is
    externally checkable: entries accepted by {!log}/{!log_exn} equal
    [emit_count + drop_count] once the logger has terminated. *)

type t
(** An asynchronous structured logger. Opaque — use {!create} to construct. *)

val create :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  Config.t ->
  string ->
  (t, string) result
(** [create ~sw ~clock config name] creates a new logger named [name].
    Initialises a bounded queue of [config.queue_depth] entries, the emit and
    per-cause drop counters at zero, and forks a worker daemon fiber under [sw].
    The worker drains the queue, calling each sink in [config.sinks] for every
    entry. When [sw] closes, the worker calls [sink.close ()] on each sink
    before terminating.

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

    The entry's fields are the merge of the current fiber-local context (see
    [Context.current]) and any user-supplied [~fields]. Call-site fields
    override context fields on key collision.

    The [olog.] field-name prefix is reserved for the logger itself (as the
    [exn.] prefix is reserved for {!log_exn}); user-supplied fields with this
    prefix may be overwritten. The logger emits
    [("olog.invalid_timestamp", Value.bool true)] when the clock yields an
    unrepresentable timestamp under the {!Mark_invalid} policy.

    If [level] is below the logger's minimum level, returns immediately without
    calling [Context.current] or allocating an [Entry.t]. If the queue is full,
    the entry is dropped and counted in [diagnostics.drops_queue_full] — the
    calling fiber is never suspended.

    @param level Log severity.
    @param fields
      Structured key-value pairs (default [[]]). Override context fields with
      the same key.
    @param src_pos
      Source location, typically injected by a PPX (default [None]).
    @param message Human-readable log message. *)

val log_exn :
  t ->
  level:Level.t ->
  exn ->
  Printexc.raw_backtrace ->
  ?fields:(string * Value.t) list ->
  ?src_pos:Entry.src_pos ->
  string ->
  unit
(** [log_exn t ~level exn bt ?fields ?src_pos msg] logs [msg] at [level] with
    structured exception fields extracted from [exn] and [bt]:

    - [("exn.name", Value.string (Printexc.exn_slot_name exn))]
    - [("exn.message", Value.string (Printexc.to_string exn))]
    - [("exn.backtrace", Value.string (Printexc.raw_backtrace_to_string bt))]

    The entry's fields are the merge of fiber-local context, user-supplied
    [~fields], and exception fields, in that precedence order (exception fields
    win on collision, then user fields, then context fields). The [exn.] key
    prefix is reserved; user-supplied fields with this prefix will be
    overwritten.

    Like {!log}, this function never raises. If [level] is below the logger's
    minimum level, returns immediately without calling [Context.current] or
    capturing any fields. If the internal queue is full the entry is dropped and
    counted in [diagnostics.drops_queue_full].

    {b Backtrace recording:} [bt] is typically obtained by calling
    [Printexc.get_raw_backtrace ()] immediately after catching the exception.
    Backtrace recording must be enabled for this to return a non-empty trace;
    see [Printexc.record_backtrace]. The PPX extensions [[%log.<level>_exn ...]]
    handle this automatically, skipping the backtrace call when recording is
    disabled. *)

val flush : t -> unit
(** [flush logger] suspends the calling fiber until all entries currently in the
    queue have been processed by the worker and each sink's [flush] function has
    been called.

    If the worker has already terminated — whether through {!shutdown} or
    because the enclosing switch was cancelled — [flush] returns promptly
    instead of blocking forever.

    Safe to call concurrently with {!log}. *)

val shutdown : t -> unit
(** [shutdown logger] initiates a graceful shutdown of the logger.

    The calling fiber is suspended until: 1. All entries currently in the queue
    have been emitted to every sink. 2. [sink.flush ()] has been called on every
    configured sink. 3. [sink.close ()] has been called on every configured
    sink.

    After [shutdown] returns, subsequent calls to {!log} and {!log_exn} are
    no-ops — entries are dropped and counted in
    [diagnostics.drops_after_shutdown]. Subsequent calls to {!val:flush} return
    immediately without blocking. {!val:diagnostics} reports
    [is_shutdown = true].

    [shutdown] is idempotent and safe under concurrent invocation: any number of
    fibers, across any number of domains, may call it simultaneously, and every
    caller returns once shutdown has completed. It also returns promptly —
    rather than blocking forever — when the worker has already terminated
    because the enclosing switch was cancelled.

    {b Best-effort drain on unexpected cancellation.} If the enclosing switch is
    cancelled without a prior [shutdown] call, the worker makes a best-effort
    attempt to drain remaining queue entries under [Eio.Cancel.protect] before
    closing sinks. This is not guaranteed to succeed if sink resources have
    already been released by cancellation. For guaranteed delivery, call
    [shutdown] before the switch closes.

    Safe to call concurrently with {!log}. *)

val diagnostics : t -> diagnostics
(** [diagnostics logger] returns a point-in-time snapshot of the logger's
    internal metrics. Safe to call from any fiber at any time. *)
