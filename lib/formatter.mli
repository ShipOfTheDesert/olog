(** Pure log entry formatters.

    A {!t} is a function from {!Entry.t} to [string]. Each built-in formatter
    produces a newline-terminated line. Formatters are composable: supply one to
    any {!Output} constructor. Formatters have no Eio dependency and may be
    tested without a scheduler. *)

type t = Entry.t -> string
(** A formatter converts a single log entry to a newline-terminated string. *)

val json : t
(** [json entry] serialises [entry] as a compact JSON object followed by ['\n']
    (JSON Lines format).

    Fixed keys: ["timestamp"] (ISO 8601 UTC), ["level"] (lower-case),
    ["message"] (string). Each field in {!Entry.fields} appears as an additional
    top-level key serialised via {!Value.to_yojson}. If {!Entry.src_pos} is
    [Some p], a ["src_pos"] object with ["file"], ["line"], and ["col"] is
    included. *)

val logfmt : t
(** [logfmt entry] serialises [entry] in logfmt format followed by ['\n'].

    Fixed keys appear first: [ts], [level], [msg]. Structured fields follow.
    String values containing whitespace, [=], or a double-quote are
    double-quoted; interior double-quotes are escaped with a backslash. *)

val text : t
(** [text entry] serialises [entry] as a human-readable line followed by ['\n'].

    Format: [<ISO8601> <LEVEL> <message>[ key=value ...]] Level is upper-cased.
    Fields follow the message as space-separated [key=value] pairs. Values are
    rendered with {!Value.to_string}. *)
