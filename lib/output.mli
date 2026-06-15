(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches of
    entries and releasing resources. Built-in constructors cover stdout and
    stderr.

    {!t.write} reports I/O failures as [Error msg] rather than raising;
    [Eio.Cancel.Cancelled] is the one exception that propagates. The logger
    worker reports the [Error] to process stderr. Use {!to_sink} to adapt an
    {!t} for use with [Logger.Config.sinks]. *)

type t = {
  name : string;
      (** Human-readable name, used in error messages and diagnostics. *)
  write : Entry.t list -> (unit, string) result;
      (** Write a batch of entries to the destination. Returns [Error msg] on
          I/O failure rather than raising (except [Eio.Cancel.Cancelled], which
          propagates). Called by the logger worker fiber. *)
  close : unit -> (unit, string) result;
      (** Release underlying resources. Returns [Error msg] on failure. Called
          once at teardown by the logger worker via {!to_sink}. *)
}
(** An output destination — a named pair of write and close functions, each
    reporting failure as [Error msg]. *)

val make : name:string -> formatter:Formatter.t -> _ Eio.Flow.sink -> t
(** [make ~name ~formatter flow] creates an output that formats each entry with
    [formatter] and writes the resulting strings to [flow].

    [close ()] is a no-op returning [Ok ()] — the caller retains ownership of
    [flow]. Exceptions from [flow] writes are converted to [Error msg];
    [Eio.Cancel.Cancelled] is re-raised so the worker can shut down. *)

val stdout :
  env:< stdout : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
(** [stdout ~env ~formatter ()] writes formatted entries to [env]'s standard
    output. [name = "stdout"]. [close] is a no-op. *)

val stderr :
  env:< stderr : _ Eio.Flow.sink ; .. > -> formatter:Formatter.t -> unit -> t
(** [stderr ~env ~formatter ()] writes formatted entries to [env]'s standard
    error. [name = "stderr"]. [close] is a no-op. *)

val to_sink : t -> Logger.sink
(** [to_sink output] adapts [output] for use with [Logger.Config.sinks].

    Mapping:
    - [emit entry] → [output.write [entry]]
    - [flush ()] → no-op
    - [close ()] → [output.close ()] *)
