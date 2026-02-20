type t = { name : string; write : Entry.t list -> unit; close : unit -> unit }

(* ── Error safety ─────────────────────────────────────────────────────────── *)

(* Write a best-effort error line to process stderr.
   Uses Printf.eprintf rather than Eio.Stdenv.stderr because Output.make has
   no access to env; Stdlib stderr is the raw process stream and acceptable for
   error reporting (not subject to the NF4 prohibition on file access). *)
let write_fallback_error name exn =
  try Printf.eprintf "[olog error] %s: %s\n%!" name (Printexc.to_string exn)
  with _ -> ()

(* Wrap write body; re-raise Eio cancellation so the worker can shut down. *)
let protect name f =
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> write_fallback_error name exn

(* ── Output.make ─────────────────────────────────────────────────────────── *)

let make ~name ~formatter flow =
  {
    name;
    write =
      (fun entries ->
        protect name (fun () ->
            List.iter (fun e -> Eio.Flow.copy_string (formatter e) flow) entries));
    close = (fun () -> ());
  }

(* ── Output.stdout / Output.stderr ──────────────────────────────────────── *)

let stdout ~env ~formatter () =
  make ~name:"stdout" ~formatter (Eio.Stdenv.stdout env)

let stderr ~env ~formatter () =
  make ~name:"stderr" ~formatter (Eio.Stdenv.stderr env)

(* ── Output.to_sink ──────────────────────────────────────────────────────── *)

let to_sink output =
  {
    Logger.emit = (fun entry -> output.write [ entry ]);
    flush = (fun () -> ());
    close = (fun () -> output.close ());
  }
