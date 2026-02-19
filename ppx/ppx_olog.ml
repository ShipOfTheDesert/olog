open Ppxlib
module B = Ast_builder.Default

(* Map lowercase level name to the Level variant constructor name *)
let level_variant = function
  | "trace" -> "Trace"
  | "debug" -> "Debug"
  | "info" -> "Info"
  | "warn" -> "Warn"
  | "error" -> "Error"
  | "fatal" -> "Fatal"
  | s -> String.capitalize_ascii s

(* Build a Longident path rooted at Olog: ["Level"; "Info"] → Olog.Level.Info *)
let olog_lid ~loc parts =
  let txt =
    List.fold_left (fun acc part -> Ldot (acc, part)) (Lident "Olog") parts
  in
  { txt; loc }

(* Wrap a single value expression according to the auto-wrap rules:
   - int literal        → Olog.Value.Int expr
   - float literal      → Olog.Value.Float expr
   - string literal     → Olog.Value.String expr
   - true / false       → Olog.Value.Bool expr
   - `Int e             → Olog.Value.Int e
   - `Float e           → Olog.Value.Float e
   - `String e          → Olog.Value.String e
   - `Bool e            → Olog.Value.Bool e
   - `Null              → Olog.Value.Null
   - anything else      → unchanged (must already be Value.t)

   Note: Value variants are data constructors, built with pexp_construct. *)
let wrap_value ~loc expr =
  (* Olog.Value.Name or Olog.Value.Name(arg) — always a constructor expression *)
  let mk_ctor name arg_opt =
    B.pexp_construct ~loc (olog_lid ~loc [ "Value"; name ]) arg_opt
  in
  match expr.pexp_desc with
  | Pexp_constant (Pconst_integer _) -> mk_ctor "Int" (Some expr)
  | Pexp_constant (Pconst_float _) -> mk_ctor "Float" (Some expr)
  | Pexp_constant (Pconst_string _) -> mk_ctor "String" (Some expr)
  | Pexp_construct ({ txt = Lident "true"; _ }, None)
  | Pexp_construct ({ txt = Lident "false"; _ }, None) ->
      mk_ctor "Bool" (Some expr)
  | Pexp_variant ("Int", Some arg) -> mk_ctor "Int" (Some arg)
  | Pexp_variant ("Float", Some arg) -> mk_ctor "Float" (Some arg)
  | Pexp_variant ("String", Some arg) -> mk_ctor "String" (Some arg)
  | Pexp_variant ("Bool", Some arg) -> mk_ctor "Bool" (Some arg)
  | Pexp_variant ("Null", None) -> mk_ctor "Null" None
  | _ -> expr

(* Wrap the value slot of a ("key", value) tuple expression *)
let wrap_field ~loc expr =
  match expr.pexp_desc with
  | Pexp_tuple [ key; value ] ->
      let value' = wrap_value ~loc value in
      B.pexp_tuple ~loc:expr.pexp_loc [ key; value' ]
  | _ -> expr (* not a 2-tuple: pass through *)

(* Traverse a list-literal expression and wrap every field pair inside it.
   Handles [e1; e2; ...] which the parser desugars to :: cons chains. *)
let rec wrap_fields_list ~loc expr =
  match expr.pexp_desc with
  | Pexp_construct ({ txt = Lident "[]"; _ }, None) -> expr
  | Pexp_construct (({ txt = Lident "::"; _ } as cons), Some pair) -> (
      match pair.pexp_desc with
      | Pexp_tuple [ head; tail ] ->
          let head' = wrap_field ~loc head in
          let tail' = wrap_fields_list ~loc tail in
          B.pexp_construct ~loc:expr.pexp_loc cons
            (Some (B.pexp_tuple ~loc:pair.pexp_loc [ head'; tail' ]))
      | _ -> expr)
  | _ -> expr (* not a list literal: pass through unchanged *)

(* Expand [%log.LEVEL logger_expr "message"] or
         [%log.LEVEL logger_expr "message" fields_expr]
   into:
     (let __olog_l = logger_expr in
      if Olog.Logger.is_enabled __olog_l Olog.Level.LEVEL then
        Olog.Logger.log __olog_l
          ~level:Olog.Level.LEVEL
          ~src_pos:{ Olog.Entry.file = F; line = L; col = C }
          ~fields:fields_expr
          "message") *)
let expand_log ~loc ~level payload =
  (* Decode the payload expression into (logger, msg_string, fields_opt).
     OCaml's parser groups `f a b` into Pexp_apply(f, [a; b]) — a flat list
     of arguments — so we match on the argument count. *)
  let logger_expr, msg, fields_opt =
    match payload.pexp_desc with
    | Pexp_apply (logger_expr, [ (Nolabel, msg_expr) ]) -> (
        match msg_expr.pexp_desc with
        | Pexp_constant (Pconst_string (msg, _, _)) -> (logger_expr, msg, None)
        | _ ->
            Location.raise_errorf ~loc
              "[log.%s]: the second argument must be a string literal" level)
    | Pexp_apply (logger_expr, [ (Nolabel, msg_expr); (Nolabel, fields_expr) ])
      -> (
        match msg_expr.pexp_desc with
        | Pexp_constant (Pconst_string (msg, _, _)) ->
            (logger_expr, msg, Some fields_expr)
        | _ ->
            Location.raise_errorf ~loc
              "[log.%s]: the second argument must be a string literal" level)
    | _ ->
        Location.raise_errorf ~loc
          "[log.%s]: expected `logger \"msg\"` or `logger \"msg\" [fields]`"
          level
  in
  let variant = level_variant level in
  (* Level variants are constructors, not identifiers *)
  let level_expr =
    B.pexp_construct ~loc (olog_lid ~loc [ "Level"; variant ]) None
  in
  (* Compute column from source location: F6 *)
  let col = loc.loc_start.pos_cnum - loc.loc_start.pos_bol in
  (* Build { Olog.Entry.file = ...; line = ...; col = ... } *)
  let src_pos_expr =
    B.pexp_record ~loc
      [
        ( olog_lid ~loc [ "Entry"; "file" ],
          B.estring ~loc loc.loc_start.pos_fname );
        (olog_lid ~loc [ "Entry"; "line" ], B.eint ~loc loc.loc_start.pos_lnum);
        (olog_lid ~loc [ "Entry"; "col" ], B.eint ~loc col);
      ]
      None
  in
  let fields_expr =
    match fields_opt with
    | None -> B.elist ~loc []
    | Some f -> wrap_fields_list ~loc f
  in
  (* Olog.Logger.log __olog_l ~level:... ~src_pos:... ~fields:... "msg" *)
  let log_call =
    B.pexp_apply ~loc
      (B.pexp_ident ~loc (olog_lid ~loc [ "Logger"; "log" ]))
      [
        (Nolabel, B.evar ~loc "__olog_l");
        (Labelled "level", level_expr);
        (Labelled "src_pos", src_pos_expr);
        (Labelled "fields", fields_expr);
        (Nolabel, B.estring ~loc msg);
      ]
  in
  (* Olog.Logger.is_enabled __olog_l Olog.Level.Xxx *)
  let is_enabled_call =
    B.eapply ~loc
      (B.pexp_ident ~loc (olog_lid ~loc [ "Logger"; "is_enabled" ]))
      [ B.evar ~loc "__olog_l"; level_expr ]
  in
  (* if is_enabled then log_call  (no else: result is unit) *)
  let if_expr = B.pexp_ifthenelse ~loc is_enabled_call log_call None in
  (* let __olog_l = logger_expr in if_expr *)
  let binding =
    B.value_binding ~loc
      ~pat:(B.ppat_var ~loc { txt = "__olog_l"; loc })
      ~expr:logger_expr
  in
  B.pexp_let ~loc Nonrecursive [ binding ] if_expr

let make_extension level_name =
  Extension.declare ("log." ^ level_name) Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (fun ~loc ~path:_ payload -> expand_log ~loc ~level:level_name payload)

let () =
  Driver.register_transformation "olog_ppx"
    ~extensions:
      [
        make_extension "trace";
        make_extension "debug";
        make_extension "info";
        make_extension "warn";
        make_extension "error";
        make_extension "fatal";
      ]
