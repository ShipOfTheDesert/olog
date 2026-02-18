(* F2 *)
let test_empty_is_empty_list () =
  Alcotest.(check bool) "empty is []" true (Olog.Context.empty = [])

(* F3: current () outside any Eio context or with_context scope returns empty *)
let test_current_outside_eio () =
  let ctx = Olog.Context.current () in
  Alcotest.(check bool) "outside Eio returns empty" true (ctx = [])

(* F3 *)
let test_current_no_binding () =
  Eio_main.run @@ fun _ ->
  let ctx = Olog.Context.current () in
  Alcotest.(check bool) "no binding means empty" true (ctx = [])

(* F3 *)
let test_current_inside_with_context () =
  Eio_main.run @@ fun _ ->
  let fields = [ ("req_id", Olog.Value.String "abc") ] in
  Olog.Context.with_context ~fields (fun () ->
      let ctx = Olog.Context.current () in
      Alcotest.(check bool) "context non-empty" true (ctx <> []);
      Alcotest.(check bool)
        "req_id = abc" true
        (List.assoc_opt "req_id" ctx = Some (Olog.Value.String "abc")))

(* F4 *)
let test_fields_visible () =
  Eio_main.run @@ fun _ ->
  let fields =
    [ ("user_id", Olog.Value.Int 42); ("region", Olog.Value.String "eu") ]
  in
  Olog.Context.with_context ~fields (fun () ->
      let ctx = Olog.Context.current () in
      Alcotest.(check bool)
        "user_id present" true
        (List.assoc_opt "user_id" ctx = Some (Olog.Value.Int 42));
      Alcotest.(check bool)
        "region present" true
        (List.assoc_opt "region" ctx = Some (Olog.Value.String "eu")))

(* F4: context restored after normal return *)
let test_context_restored_return () =
  Eio_main.run @@ fun _ ->
  let fields = [ ("k", Olog.Value.String "v") ] in
  Olog.Context.with_context ~fields (fun () -> ());
  let ctx = Olog.Context.current () in
  Alcotest.(check bool) "context empty after return" true (ctx = [])

(* F4: context restored after exception *)
let test_context_restored_raise () =
  Eio_main.run @@ fun _ ->
  let fields = [ ("k", Olog.Value.String "v") ] in
  (try Olog.Context.with_context ~fields (fun () -> raise Exit)
   with Exit -> ());
  let ctx = Olog.Context.current () in
  Alcotest.(check bool) "context empty after raise" true (ctx = [])

(* F8: with_context ~fields:[] must not create a binding *)
let test_empty_fields_noop () =
  Eio_main.run @@ fun _ ->
  Olog.Context.with_context ~fields:[] (fun () ->
      let ctx = Olog.Context.current () in
      Alcotest.(check bool) "empty fields — ctx still empty" true (ctx = []))

(* F5: inner value wins on duplicate key *)
let test_inner_wins_duplicate () =
  Eio_main.run @@ fun _ ->
  let outer = [ ("a", Olog.Value.Int 1) ] in
  let inner = [ ("a", Olog.Value.Int 2) ] in
  Olog.Context.with_context ~fields:outer (fun () ->
      Olog.Context.with_context ~fields:inner (fun () ->
          let ctx = Olog.Context.current () in
          Alcotest.(check bool)
            "inner a=2 wins" true
            (List.assoc_opt "a" ctx = Some (Olog.Value.Int 2))))

(* F9: distinct fields accumulate across nesting levels *)
let test_nested_accumulate () =
  Eio_main.run @@ fun _ ->
  let outer = [ ("x", Olog.Value.Int 1) ] in
  let inner = [ ("y", Olog.Value.Int 2) ] in
  Olog.Context.with_context ~fields:outer (fun () ->
      Olog.Context.with_context ~fields:inner (fun () ->
          let ctx = Olog.Context.current () in
          Alcotest.(check bool) "x present" true (List.mem_assoc "x" ctx);
          Alcotest.(check bool) "y present" true (List.mem_assoc "y" ctx)))

(* F9: three-level nesting — deepest value wins for duplicate key *)
let test_nested_deepest_wins () =
  Eio_main.run @@ fun _ ->
  let l1 = [ ("k", Olog.Value.Int 1) ] in
  let l2 = [ ("k", Olog.Value.Int 2) ] in
  let l3 = [ ("k", Olog.Value.Int 3) ] in
  Olog.Context.with_context ~fields:l1 (fun () ->
      Olog.Context.with_context ~fields:l2 (fun () ->
          Olog.Context.with_context ~fields:l3 (fun () ->
              let ctx = Olog.Context.current () in
              Alcotest.(check bool)
                "deepest k=3 wins" true
                (List.assoc_opt "k" ctx = Some (Olog.Value.Int 3)))))

(* F7: forked fiber starts with empty context; parent context is unchanged *)
let test_fiber_isolation () =
  Eio_main.run @@ fun _ ->
  let fields = [ ("trace_id", Olog.Value.String "xyz") ] in
  Olog.Context.with_context ~fields (fun () ->
      let child_ctx = ref [] in
      Eio.Switch.run (fun sw ->
          Eio.Fiber.fork ~sw (fun () -> child_ctx := Olog.Context.current ()));
      Alcotest.(check bool) "child context is empty" true (!child_ctx = []);
      let parent_ctx = Olog.Context.current () in
      Alcotest.(check bool)
        "parent trace_id intact" true
        (List.assoc_opt "trace_id" parent_ctx = Some (Olog.Value.String "xyz")))

let () =
  Alcotest.run "Context"
    [
      ( "type",
        [
          Alcotest.test_case "empty is empty list" `Quick
            test_empty_is_empty_list;
        ] );
      ( "current",
        [
          Alcotest.test_case "returns empty outside any Eio context" `Quick
            test_current_outside_eio;
          Alcotest.test_case "returns empty when no binding set" `Quick
            test_current_no_binding;
          Alcotest.test_case "returns fields inside with_context" `Quick
            test_current_inside_with_context;
        ] );
      ( "with_context",
        [
          Alcotest.test_case "fields visible during callback" `Quick
            test_fields_visible;
          Alcotest.test_case "context restored after callback returns" `Quick
            test_context_restored_return;
          Alcotest.test_case "context restored after callback raises" `Quick
            test_context_restored_raise;
          Alcotest.test_case "empty fields does not set binding" `Quick
            test_empty_fields_noop;
          Alcotest.test_case "inner field wins on duplicate key" `Quick
            test_inner_wins_duplicate;
          Alcotest.test_case "nested calls accumulate distinct fields" `Quick
            test_nested_accumulate;
          Alcotest.test_case "nested deepest value wins for duplicate" `Quick
            test_nested_deepest_wins;
        ] );
      ( "fiber isolation",
        [
          Alcotest.test_case "forked fiber starts with empty context" `Quick
            test_fiber_isolation;
        ] );
    ]
