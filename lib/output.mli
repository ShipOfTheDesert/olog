(** Output destinations for log entries.

    An {!t} is a named vtable record: a pair of functions for writing batches of
    entries and releasing resources. Built-in constructors cover stdout, stderr,
    file (size-based rotation), and HTTP (batched POST).

    {!t.write} never propagates exceptions — I/O errors are caught and a
    best-effort error line is written to the process stderr. Use {!to_sink} to
    adapt an {!t} for use with {!Logger.Config.sinks}. *)

type t = {
  name : string;
      (** Human-readable name, used in error messages and diagnostics. *)
  write : Entry.t list -> unit;
      (** Write a batch of entries to the destination. Must not raise — see
          module documentation. Called by the logger worker fiber. *)
  close : unit -> unit;
      (** Release underlying resources. Called once at teardown by {!Logger}'s
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

    [close ()] is a no-op.

    @param max_bytes Must be a positive integer. *)

val http :
  net:_ Eio.Net.t ->
  formatter:Formatter.t ->
  uri:string ->
  ?headers:(string * string) list ->
  unit ->
  t
(** [http ~net ~formatter ~uri ?headers ()] creates an output that POSTs each
    batch of entries as a single HTTP request.

    The request body is the concatenation of [formatter entry] for each entry in
    the batch. [Content-Type] is [text/plain; charset=utf-8]. Additional
    [headers] are appended verbatim.

    On network error or non-2xx response, entries are dropped and the error is
    reported to fallback stderr per the error-safety contract. [close] is a
    no-op. *)

val to_sink : t -> Logger.sink
(** [to_sink output] adapts [output] for use with {!Logger.Config.sinks}.

    Mapping:
    - [emit entry] → [output.write [entry]]
    - [flush ()] → no-op
    - [close ()] → [output.close ()] *)
