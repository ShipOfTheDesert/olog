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

(* ── Output.file ─────────────────────────────────────────────────────────── *)

(* Build the rotated path: same directory as path, basename ^ ".1". *)
let rotated_path path =
  match Eio.Path.split path with
  | None -> None
  | Some (dir, base) -> Some (Eio.Path.( / ) dir (base ^ ".1"))

(* Output.file uses Eio.Path.with_open_out on each write call (per-write open).
   This avoids the need for a ~sw parameter not present in the RFC interface.
   The file is opened in append mode, written, and closed for each batch.
   The byte counter persists across calls to track cumulative size. *)
let file ~env:_ ~formatter ~path ~max_bytes () =
  let name = match Eio.Path.native path with Some s -> s | None -> "<path>" in
  (* mutable: justified — cumulative byte count must persist across write calls
     to trigger size-based rotation at the right threshold. *)
  let bytes_written = ref 0 in
  {
    name;
    write =
      (fun entries ->
        protect name (fun () ->
            let formatted = List.map formatter entries in
            let total =
              List.fold_left (fun acc s -> acc + String.length s) 0 formatted
            in
            (* Rotate when the previous cumulative total is above zero and adding
               this batch would meet or exceed max_bytes. *)
            if !bytes_written > 0 && !bytes_written + total >= max_bytes then begin
              (match rotated_path path with
              | None ->
                  (* Path cannot be split (no parent directory). Rotation is skipped;
                   the write will still proceed to the original path. *)
                  write_fallback_error name
                    (Failure "rotation skipped: cannot derive rotated path")
              | Some dst -> Eio.Path.rename path dst);
              bytes_written := 0
            end;
            Eio.Path.with_open_out ~append:true ~create:(`If_missing 0o644) path
              (fun flow ->
                List.iter (fun s -> Eio.Flow.copy_string s flow) formatted);
            bytes_written := !bytes_written + total));
    close = (fun () -> ());
  }

(* ── Output.to_sink ──────────────────────────────────────────────────────── *)

let to_sink output =
  {
    Logger.emit = (fun entry -> output.write [ entry ]);
    flush = (fun () -> ());
    close = (fun () -> output.close ());
  }
