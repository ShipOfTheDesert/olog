(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches of
    entries and releasing resources. Built-in constructors cover stdout, stderr,
    and file (size-based rotation).

    {!t.write} never propagates exceptions — I/O errors are caught and a
    best-effort error line is written to the process stderr. Use {!to_sink} to
    adapt an {!t} for use with [Logger.Config.sinks]. *)

type t = {
  name : string;
      (** Human-readable name, used in error messages and diagnostics. *)
  write : Entry.t list -> unit;
      (** Write a batch of entries to the destination. Must not raise — see
          module documentation. Called by the logger worker fiber. *)
  close : unit -> unit;
      (** Release underlying resources. Called once at teardown by the logger
          worker via {!to_sink}. Must not raise. *)
}
(** An output destination — a named pair of write and close functions. *)

val make : name:string -> formatter:Formatter.t -> _ Eio.Flow.sink -> t
(** [make ~name ~formatter flow] creates an output that formats each entry with
    [formatter] and writes the resulting strings to [flow].

    [close ()] is a no-op — the caller retains ownership of [flow]. Exceptions
    from [flow] writes are caught per the error-safety contract. *)

val stdout :
  env:< stdout : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
(** [stdout ~env ~formatter ()] writes formatted entries to [env]'s standard
    output. [name = "stdout"]. [close] is a no-op. *)

val stderr :
  env:< stderr : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
(** [stderr ~env ~formatter ()] writes formatted entries to [env]'s standard
    error. [name = "stderr"]. [close] is a no-op. *)

val file :
  env:_ ->
  formatter:Formatter.t ->
  path:_ Eio.Path.t ->
  max_bytes:int ->
  unit ->
  t
(** [file ~env ~formatter ~path ~max_bytes ()] opens [path] in append mode and
    writes formatted entries.

    When cumulative written bytes reach [max_bytes], the output rotates: the
    current file is renamed to [<path>.1] (overwriting any existing file at that
    name), and a new file is opened at [path]. The byte counter resets after
    each rotation.

    [close ()] is a no-op — the per-write-open design holds no persistent file
    handle. See ADR 0005 for rationale.

    @param env Accepted for API compatibility; not used internally.
    @param max_bytes Must be a positive integer. *)

val to_sink : t -> Logger.sink
(** [to_sink output] adapts [output] for use with [Logger.Config.sinks].

    Mapping:
    - [emit entry] → [output.write [entry]]
    - [flush ()] → no-op
    - [close ()] → [output.close ()] *)
