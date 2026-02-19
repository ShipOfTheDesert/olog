(* test/test_output.ml
   Integration tests for Output.{make,stdout,stderr,file,to_sink}.

   Pure tests (no Eio scheduler) use Eio.Flow.buffer_sink.
   NF9: Output.file tests use Eio_main.run with a real temp directory from env. *)

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

(* ── Group 4: Output.file ───────────────────────────────────────────────── *)

(* Helper: unique path in /tmp via env#fs *)
let tmp_path env suffix =
  Eio.Path.( / ) env#fs ("/tmp/olog_test_output_" ^ suffix)

let rotated_path env suffix =
  Eio.Path.( / ) env#fs ("/tmp/olog_test_output_" ^ suffix ^ ".1")

let cleanup env suffix =
  (try Eio.Path.unlink (tmp_path env suffix) with _ -> ());
  try Eio.Path.unlink (rotated_path env suffix) with _ -> ()

(* F10: file writes to the given path and creates the file if absent *)
let test_file_write () =
  Eio_main.run @@ fun env ->
  cleanup env "write";
  let path = tmp_path env "write" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:1_000_000 ()
  in
  output.write [ make_entry "hello" ];
  let content = Eio.Path.load path in
  cleanup env "write";
  Alcotest.(check bool) "file contains content" true (String.length content > 0);
  let has_hello =
    let needle = "hello" in
    let nlen = String.length needle and hlen = String.length content in
    let rec loop i =
      i + nlen <= hlen && (String.sub content i nlen = needle || loop (i + 1))
    in
    loop 0
  in
  Alcotest.(check bool) "file contains 'hello'" true has_hello

(* F10: name is the path string representation *)
let test_file_name () =
  Eio_main.run @@ fun env ->
  cleanup env "name";
  let path = tmp_path env "name" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:1000 ()
  in
  output.close ();
  Alcotest.(check bool) "name is non-empty" true (String.length output.name > 0)

(* F10: append mode — a second write does not truncate previous content *)
let test_file_appends_to_existing () =
  Eio_main.run @@ fun env ->
  cleanup env "append";
  let path = tmp_path env "append" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:1_000_000 ()
  in
  output.write [ make_entry "first" ];
  output.write [ make_entry "second" ];
  let content = Eio.Path.load path in
  cleanup env "append";
  let has_first =
    let needle = "first" in
    let nlen = String.length needle and hlen = String.length content in
    let rec loop i =
      i + nlen <= hlen && (String.sub content i nlen = needle || loop (i + 1))
    in
    loop 0
  in
  let has_second =
    let needle = "second" in
    let nlen = String.length needle and hlen = String.length content in
    let rec loop i =
      i + nlen <= hlen && (String.sub content i nlen = needle || loop (i + 1))
    in
    loop 0
  in
  Alcotest.(check bool)
    "first entry still present after second write" true has_first;
  Alcotest.(check bool) "second entry present" true has_second

(* F11: rotation renames current file to <path>.1 and opens a fresh file *)
let test_file_rotation () =
  Eio_main.run @@ fun env ->
  cleanup env "rotate";
  let path = tmp_path env "rotate" in
  (* max_bytes = 10 forces rotation after the first write (entries are ~31 bytes) *)
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:10 ()
  in
  (* First write: creates the file, bytes_written becomes ~31 *)
  output.write [ make_entry "first" ];
  let after_first = Eio.Path.load path in
  (* Second write: triggers rotation (bytes_written + new_bytes >= 10) *)
  output.write [ make_entry "second" ];
  let rotated_exists = Eio.Path.is_file (rotated_path env "rotate") in
  let after_second = Eio.Path.load path in
  cleanup env "rotate";
  Alcotest.(check bool)
    "first write produced content" true
    (String.length after_first > 0);
  Alcotest.(check bool)
    "rotated file exists after second write" true rotated_exists;
  Alcotest.(check bool)
    "new file has content after rotation" true
    (String.length after_second > 0)

(* F11: the rotated file (.1) holds the pre-rotation content *)
let test_file_rotated_holds_pre_rotation_content () =
  Eio_main.run @@ fun env ->
  cleanup env "rotcontent";
  let path = tmp_path env "rotcontent" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:10 ()
  in
  output.write [ make_entry "before" ];
  (* Second write triggers rotation; "before" entry moves to .1 *)
  output.write [ make_entry "after" ];
  let rotated_content = Eio.Path.load (rotated_path env "rotcontent") in
  cleanup env "rotcontent";
  let has_before =
    let needle = "before" in
    let nlen = String.length needle and hlen = String.length rotated_content in
    let rec loop i =
      i + nlen <= hlen
      && (String.sub rotated_content i nlen = needle || loop (i + 1))
    in
    loop 0
  in
  Alcotest.(check bool)
    "rotated file contains pre-rotation entry" true has_before

(* F11: byte counter resets after rotation; a third write goes to the new file *)
let test_file_rotation_counter_resets () =
  Eio_main.run @@ fun env ->
  cleanup env "reset";
  let path = tmp_path env "reset" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:10 ()
  in
  output.write [ make_entry "one" ];
  (* triggers rotation *)
  output.write [ make_entry "two" ];
  (* write to fresh file *)
  output.write [ make_entry "three" ];
  let content = Eio.Path.load path in
  cleanup env "reset";
  let has_three =
    let needle = "three" in
    let nlen = String.length needle and hlen = String.length content in
    let rec loop i =
      i + nlen <= hlen && (String.sub content i nlen = needle || loop (i + 1))
    in
    loop 0
  in
  Alcotest.(check bool) "third write lands in current file" true has_three

(* F12: file close is a no-op (per-write-open design has no persistent handle) *)
let test_file_close_noop () =
  Eio_main.run @@ fun env ->
  cleanup env "close";
  let path = tmp_path env "close" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:1000 ()
  in
  output.close ()

(* F6: write error safety — write does not raise even if the path is invalid *)
let test_file_write_error_safety () =
  Eio_main.run @@ fun env ->
  let path = Eio.Path.( / ) env#fs "/tmp/no_such_dir_olog_xyz/test.txt" in
  let output =
    Output.file ~env ~formatter:Formatter.text ~path ~max_bytes:10 ()
  in
  output.write [ make_entry "msg" ]

(* ── Group 5: Output.to_sink ────────────────────────────────────────────── *)

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
      ( "Output.file",
        [
          Alcotest.test_case "writes to path" `Quick test_file_write;
          Alcotest.test_case "appends to existing file" `Quick
            test_file_appends_to_existing;
          Alcotest.test_case "name is path string" `Quick test_file_name;
          Alcotest.test_case "rotates at max_bytes" `Quick test_file_rotation;
          Alcotest.test_case "rotated file holds pre-rotation content" `Quick
            test_file_rotated_holds_pre_rotation_content;
          Alcotest.test_case "byte counter resets after rotation" `Quick
            test_file_rotation_counter_resets;
          Alcotest.test_case "close is no-op" `Quick test_file_close_noop;
          Alcotest.test_case "write does not propagate exceptions" `Quick
            test_file_write_error_safety;
        ] );
      ( "Output.to_sink",
        [
          Alcotest.test_case "emit calls output.write" `Quick test_to_sink_emit;
          Alcotest.test_case "flush is no-op" `Quick test_to_sink_flush_noop;
          Alcotest.test_case "close calls output.close" `Quick
            test_to_sink_close;
        ] );
    ]
