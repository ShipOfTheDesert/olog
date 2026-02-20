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
  output.write [ make_entry "hello"; make_entry "world" ];
  let content = Buffer.contents buf in
  let lines = String.split_on_char '\n' (String.trim content) in
  Alcotest.(check int) "two entries written as two lines" 2 (List.length lines)

(* F7: write processes entries in list order *)
let test_make_write_order () =
  let buf = Buffer.create 128 in
  let flow = Eio.Flow.buffer_sink buf in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  output.write [ make_entry "alpha"; make_entry "beta" ];
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
  output.close ()

(* F6: write must not propagate exceptions when the underlying flow raises *)
let test_make_write_error_safety () =
  let flow = make_raising_flow () in
  let output = Output.make ~name:"test" ~formatter:Formatter.text flow in
  output.write [ make_entry "msg" ]

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
  output.close ()

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
  output.close ()

(* ── Group 4: Output.to_sink ────────────────────────────────────────────── *)

(* F15: emit calls output.write with a singleton list *)
let test_to_sink_emit () =
  let written = ref [] in
  let output : Output.t =
    {
      Output.name = "test";
      write = (fun entries -> written := !written @ entries);
      close = (fun () -> ());
    }
  in
  let sink = Output.to_sink output in
  let entry = make_entry "hello" in
  sink.Logger.emit entry;
  Alcotest.(check int) "write called with one entry" 1 (List.length !written);
  Alcotest.(check string)
    "correct entry message" "hello" (List.hd !written).Entry.message

(* F15: flush is a no-op *)
let test_to_sink_flush_noop () =
  let output : Output.t =
    { Output.name = "test"; write = (fun _ -> ()); close = (fun () -> ()) }
  in
  let sink = Output.to_sink output in
  sink.Logger.flush ()

(* F15: close calls output.close *)
let test_to_sink_close () =
  let closed = ref false in
  let output : Output.t =
    {
      Output.name = "test";
      write = (fun _ -> ());
      close = (fun () -> closed := true);
    }
  in
  let sink = Output.to_sink output in
  sink.Logger.close ();
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
          Alcotest.test_case "write does not propagate exceptions" `Quick
            test_make_write_error_safety;
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
          Alcotest.test_case "flush is no-op" `Quick test_to_sink_flush_noop;
          Alcotest.test_case "close calls output.close" `Quick
            test_to_sink_close;
        ] );
    ]
