type t = (string * Value.t) list

(* Effect used to retrieve the current fiber's logging context.
   Forked fibers start fresh continuations without this handler, so
   Effect.Unhandled is raised and caught in [current], returning [empty].
   This provides fiber isolation (F7) without using Eio.Fiber.with_binding,
   which inherits bindings to child fibers. *)
type _ Effect.t += GetContext : t Effect.t

let empty = []

(* Internal merge: combines [existing] and [fields] keeping the last
   occurrence of any duplicate key so that [fields] (inner/deeper) wins.
   Algorithm: concatenate, reverse, dedup keeping first seen (= last in
   original order), reverse again. *)
let merge existing fields =
  let combined = existing @ fields in
  let reversed = List.rev combined in
  let seen = Hashtbl.create (List.length reversed) in
  let deduped =
    List.filter
      (fun (k, _) ->
        if Hashtbl.mem seen k then false
        else (
          Hashtbl.add seen k ();
          true))
      reversed
  in
  List.rev deduped

let current () =
  (* If no with_context handler is installed (e.g., called from a forked
     fiber or outside any with_context scope), Effect.Unhandled is raised. *)
  try Effect.perform GetContext with Effect.Unhandled _ -> empty

(* Build the deep handler for a given [merged] context value.
   Defined separately so the [effc] field can carry an explicit polymorphic
   type annotation — required by OCaml's type system for universally
   quantified record fields. *)
let make_handler (merged : t) =
  let effc : type c. c Effect.t -> ((c, _) Effect.Deep.continuation -> _) option
      =
   fun e ->
    match e with
    | GetContext -> Some (fun k -> Effect.Deep.continue k merged)
    | _ -> None
  in
  { Effect.Deep.retc = (fun result -> result); exnc = raise; effc }

let with_context ~fields f =
  if fields = [] then f ()
  else
    let existing = current () in
    let merged = merge existing fields in
    (* Deep handler: every GetContext performed anywhere within f's dynamic
       extent — including after Eio context switches — returns [merged].
       Forked fibers are excluded because they run from fresh Eio continuations
       that do not include this handler. *)
    Effect.Deep.match_with f () (make_handler merged)
