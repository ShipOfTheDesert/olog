(** Pure log entry formatters.

    A {!t} is a function from {!Entry.t} to [string]. Each built-in formatter
    produces a newline-terminated line. Formatters are composable: supply one to
    any {!Output} constructor. Formatters have no Eio dependency and may be
    tested without a scheduler. *)

type t = Entry.t -> string
(** A formatter converts a single log entry to a newline-terminated string. *)

val json : t
(** [json entry] serialises [entry] as a single compact JSON object followed by
    ['\n'] (JSON Lines format). The object is exactly {!Entry.to_yojson}
    rendered by [Yojson.Safe.to_string]: one JSON serializer per type, so the
    line cannot drift from the canonical envelope.

    Keys: ["timestamp"] (ISO 8601 UTC), ["level"], ["message"], and ["fields"] —
    an object holding every {!Entry.fields} entry serialised via
    {!Value.to_yojson}. Nesting the structured fields under ["fields"] keeps the
    top-level keys collision-free even when a user field is named ["level"],
    ["message"], or ["timestamp"]. If [entry.src_pos] is [Some p], a ["src_pos"]
    object with ["file"], ["line"], and ["col"] is appended.

    [json] is total: it never raises. A non-finite float field value (NaN,
    [infinity], [neg_infinity]) cannot reach here as a [Float] — {!Value.float}
    coerces it to a [String] (["nan"]/["inf"]/["-inf"]) at construction — so a
    [Float] is always finite and has a standard-JSON representation. *)

val logfmt : t
(** [logfmt entry] serialises [entry] in logfmt format as exactly one line
    followed by ['\n'], remaining unambiguously parseable for arbitrary message
    and field content — including newlines, double-quotes, and backslashes.

    Fixed keys appear first: [ts] (ISO 8601 UTC), [level], [msg]; structured
    fields follow as space-separated [key=value] pairs. A value is double-quoted
    when it contains whitespace, [=], a double-quote, a backslash, or a
    line-splitter (newline or carriage return). Inside quotes, backslash and
    double-quote are backslash-escaped and newline, carriage return, and tab
    become their two-character escapes. Because a backslash forces quoting, an
    unquoted value never contains an escape character, so a parser reverses the
    format with one rule: unquoted is literal, quoted is unescaped. Non-string
    values are rendered with {!Value.to_string} (floats losslessly) and never
    need quoting.

    The unambiguous-parse guarantee covers field {e values} and the message, not
    field {e keys}: keys are emitted raw, and [ts]/[level]/[msg] are always
    present, so a field whose key contains a space, [=], a quote, or a
    line-splitter — or equals a fixed key — can forge or duplicate a token. Keys
    are assumed to be identifiers distinct from the fixed keys (true for all
    PPX-generated fields). Escaping keys and resolving fixed-key collisions is a
    tracked follow-up (see ROADMAP), the logfmt analogue of the JSON
    duplicate-key fix. *)

val text : t
(** [text entry] serialises [entry] as a human-readable line followed by ['\n'].

    Format: [<ISO8601> <LEVEL> <message>[ key=value ...]] Level is upper-cased.
    Fields follow the message as space-separated [key=value] pairs rendered with
    {!Value.to_string} (floats losslessly). Newlines and carriage returns in the
    message and in each field token are escaped to their two-character forms so
    every entry is exactly one line, closing the log-forging vector. [text] is
    deliberately {e not} a reversible format: it adds no message quoting or
    field delimiting — use {!json} or {!logfmt} for machine parsing. *)
