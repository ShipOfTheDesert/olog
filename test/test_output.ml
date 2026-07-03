(* test/test_output.ml
   Integration tests for Output.{make,stdout,stderr,to_sink}.

   Pure tests (no Eio scheduler) use Eio.Flow.buffer_sink. *)

open Olog

let epoch = Ptime.epoch

let make_entry ?(level = Level.Info) msg =
  Entry.create ~level ~message:msg ~fields:[] ~timestamp:epoch ()

(* ── Raising-flow helper for F6 error-safety tests ──────────────────────── *)

module Raising_sink = struct
  type t = unit

  let single_write () _ = failwith "intentional sink error"
  let copy () ~src:_ = failwith "intentional sink error"
end

let raising_ops = Eio.Flow.Pi.sink (module Raising_sink)
let make_raising_flow () = Eio.Resource.T ((), raising_ops)

(* [write]/[close] now return results; in the happy-path tests any [Error] is a
   test failure, so surface it loudly with its diagnostic message. *)
let write_ok (output : Output.t) entries =
  match output.write entries with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "write failed: %s" msg

let close_ok (output : Output.t) =
  match output.close () with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "close failed: %s" msg

(* ── Group 1: Output.make ────────────────────────────────────────────────── *)

(* F5: Output.t is a concrete record with name, write, close fields *)
let test_make_record_name () =
  let buf = Buffer.create 16 in
  let flow = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"myname" ~formatter:Formatter.text flow in
  Alcotest.(check string) "name field" "myname" output.name

(* F7: write formats each entry and writes to the flow *)
let test_make_write_formats () =
  let buf = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  write_ok output [ make_entry "hello"; make_entry "world" ];
  let content = Buffer.contents buf in
  let lines = String.split_on_char '\n' (String.trim content) in
  Alcotest.(check int) "two entries written as two lines" 2 (List.length lines)

(* F7: write processes entries in list order *)
let test_make_write_order () =
  let buf = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  write_ok output [ make_entry "alpha"; make_entry "beta" ];
  let content = Buffer.contents buf in
  let find_sub haystack needle =
    let hlen = String.length haystack and nlen = String.length needle in
    let rec loop i =
      if i + nlen > hlen then max_int
      else if String.sub haystack i nlen = needle then i
      else loop (i + 1)
    in
    loop 0
  in
  let pos_alpha = find_sub content "alpha" in
  let pos_beta = find_sub content "beta" in
  Alcotest.(check bool) "alpha appears before beta" true (pos_alpha < pos_beta)

(* F7: close is a no-op for make *)
let test_make_close_noop () =
  let buf = Buffer.create 16 in
  let flow = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  close_ok output

(* F3 — write reports a failing flow as [Error _], not by raising (RFC 0013).
   That no exception escapes is proved by this test completing rather than
   crashing the runner. *)
let test_output_write_returns_error_on_io_failure () =
  let flow = make_raising_flow () in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  match output.write [ make_entry "msg" ] with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error from a failing flow"

(* ── Group 2: Output.stdout ─────────────────────────────────────────────── *)

(* F8: stdout name is "stdout" *)
let test_stdout_name () =
  Eio_main.run @@ fun env ->
  let output = Output.stdout ~env ~formatter:Formatter.text () in
  Alcotest.(check string) "name is stdout" "stdout" output.name

(* F8: stdout close is a no-op *)
let test_stdout_close_noop () =
  Eio_main.run @@ fun env ->
  let output = Output.stdout ~env ~formatter:Formatter.text () in
  close_ok output

(* ── Group 3: Output.stderr ─────────────────────────────────────────────── *)

(* F9: stderr name is "stderr" *)
let test_stderr_name () =
  Eio_main.run @@ fun env ->
  let output = Output.stderr ~env ~formatter:Formatter.text () in
  Alcotest.(check string) "name is stderr" "stderr" output.name

(* F9: stderr close is a no-op *)
let test_stderr_close_noop () =
  Eio_main.run @@ fun env ->
  let output = Output.stderr ~env ~formatter:Formatter.text () in
  close_ok output

(* ── Group 4: Output.to_sink ────────────────────────────────────────────── *)

(* F15: a singleton emit reaches output.write unchanged *)
let test_to_sink_emit () =
  let written = ref [] in
  let output : Output.t =
    {
      Output.name = "test";
      write =
        (fun entries ->
          written := !written @ entries;
          Ok ());
      close = (fun () -> Ok ());
    }
  in
  let sink = Output.to_sink output in
  let entry = make_entry "hello" in
  (match sink.Logger.emit [ entry ] with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "emit failed: %s" msg);
  Alcotest.(check int) "write called with one entry" 1 (List.length !written);
  Alcotest.(check string)
    "correct entry message" "hello" (List.hd !written).Entry.message

(* FR2 (Feature 0018) — to_sink passes the batch through to [write] unchanged:
   one [write] call per [emit] call, same entries, same order — no per-entry
   collapse. *)
let test_to_sink_passes_batch_through () =
  let batches = ref [] in
  let output : Output.t =
    {
      Output.name = "test";
      write =
        (fun entries ->
          batches := entries :: !batches;
          Ok ());
      close = (fun () -> Ok ());
    }
  in
  let sink = Output.to_sink output in
  let batch = [ make_entry "one"; make_entry "two"; make_entry "three" ] in
  (match sink.Logger.emit batch with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "emit failed: %s" msg);
  match !batches with
  | [ received ] ->
      Alcotest.(check (list string))
        "write receives the full batch in order" [ "one"; "two"; "three" ]
        (List.map (fun (e : Entry.t) -> e.Entry.message) received)
  | received ->
      Alcotest.failf "expected exactly one write call, got %d"
        (List.length received)

(* F15: flush is a no-op *)
let test_to_sink_flush_noop () =
  let output : Output.t =
    {
      Output.name = "test";
      write = (fun _ -> Ok ());
      close = (fun () -> Ok ());
    }
  in
  let sink = Output.to_sink output in
  match sink.Logger.flush () with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "flush: %s" msg

(* F15: close calls output.close *)
let test_to_sink_close () =
  let closed = ref false in
  let output : Output.t =
    {
      Output.name = "test";
      write = (fun _ -> Ok ());
      close =
        (fun () ->
          closed := true;
          Ok ());
    }
  in
  let sink = Output.to_sink output in
  ignore (sink.Logger.close ());
  Alcotest.(check bool) "output.close was called" true !closed

(* ── Runner ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Output"
    [
      ( "Output.make",
        [
          Alcotest.test_case "name field" `Quick test_make_record_name;
          Alcotest.test_case "write formats entries to flow" `Quick
            test_make_write_formats;
          Alcotest.test_case "write preserves entry order" `Quick
            test_make_write_order;
          Alcotest.test_case "close is no-op" `Quick test_make_close_noop;
          Alcotest.test_case "write returns Error on io failure" `Quick
            test_output_write_returns_error_on_io_failure;
        ] );
      ( "Output.stdout",
        [
          Alcotest.test_case "name is stdout" `Quick test_stdout_name;
          Alcotest.test_case "close is no-op" `Quick test_stdout_close_noop;
        ] );
      ( "Output.stderr",
        [
          Alcotest.test_case "name is stderr" `Quick test_stderr_name;
          Alcotest.test_case "close is no-op" `Quick test_stderr_close_noop;
        ] );
      ( "Output.to_sink",
        [
          Alcotest.test_case "emit calls output.write" `Quick test_to_sink_emit;
          Alcotest.test_case "emit passes the batch through to write" `Quick
            test_to_sink_passes_batch_through;
          Alcotest.test_case "flush is no-op" `Quick test_to_sink_flush_noop;
          Alcotest.test_case "close calls output.close" `Quick
            test_to_sink_close;
        ] );
    ]
