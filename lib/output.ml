type t = {
  name : string;
  write : Entry.t list -> (unit, string) result;
  close : unit -> (unit, string) result;
}

(* ── Output.make ─────────────────────────────────────────────────────────── *)

(* Convert flow exceptions to [Error] at this boundary so the worker can match
   on a value. [Eio.Cancel.Cancelled] is re-raised so cancellation still
   propagates to the worker; the fallback stderr line now lives in the worker
   (ADR 0006, relocated). *)
let make ~name ~formatter flow =
  {
    name;
    write =
      (fun entries ->
        try
          List.iter (fun e -> Eio.Flow.copy_string (formatter e) flow) entries;
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn));
    close = (fun () -> Ok ());
  }

(* ── Output.stdout / Output.stderr ──────────────────────────────────────── *)

let stdout ~env ~formatter () =
  make ~name:"stdout" ~formatter (Eio.Stdenv.stdout env)

let stderr ~env ~formatter () =
  make ~name:"stderr" ~formatter (Eio.Stdenv.stderr env)

(* ── Output.to_sink ──────────────────────────────────────────────────────── *)

let to_sink output =
  {
    Logger.name = output.name;
    emit = output.write;
    flush = (fun () -> Ok ());
    close = (fun () -> output.close ());
  }
