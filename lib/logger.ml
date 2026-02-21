type sink = {
  emit : Entry.t -> unit;
  flush : unit -> unit;
  close : unit -> unit;
}

module Config = struct
  type t = { min_level : Level.t; queue_depth : int; sinks : sink list }

  let default = { min_level = Level.Info; queue_depth = 1024; sinks = [] }
end

type diagnostics = {
  name : string;
  queue_depth : int;
  queue_capacity : int;
  drop_count : int;
  is_shutdown : bool;
}

type msg =
  | Log of Entry.t
  | Flush of unit Eio.Promise.u
  | Shutdown of unit Eio.Promise.u

type t = {
  name : string;
  config : Config.t;
  queue : msg Eio.Stream.t;
  drop_count : int Atomic.t;
  closed : bool Atomic.t;
      (* mutable: shutdown flag for post-shutdown drop guard *)
  now : unit -> Ptime.t;
      (* now: closure capturing the injected clock; avoids storing the polymorphic
     [> Eio.Time.clock_ty] type bound in a concrete record field. *)
}

let is_enabled t level = Level.compare level t.config.min_level >= 0

let worker_loop t =
  let sinks_closed = ref false in
  let close_all () =
    if not !sinks_closed then begin
      sinks_closed := true;
      List.iter (fun sink -> try sink.close () with _ -> ()) t.config.sinks
    end
  in
  let emit_to_sinks entry =
    List.iter (fun sink -> try sink.emit entry with _ -> ()) t.config.sinks
  in
  let flush_sinks () =
    List.iter (fun sink -> try sink.flush () with _ -> ()) t.config.sinks
  in
  let drain_trailing () =
    let rec aux () =
      match Eio.Stream.take_nonblocking t.queue with
      | None -> ()
      | Some (Log _) -> aux ()
      | Some (Flush resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
      | Some (Shutdown resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
    in
    aux ()
  in
  let rec loop () =
    let msg = Eio.Stream.take t.queue in
    match msg with
    | Log entry ->
        emit_to_sinks entry;
        loop ()
    | Flush resolver ->
        flush_sinks ();
        Eio.Promise.resolve resolver ();
        loop ()
    | Shutdown resolver ->
        flush_sinks ();
        close_all ();
        Eio.Promise.resolve resolver ();
        drain_trailing ();
        `Stop_daemon
  in
  let drain_on_cancel () =
    Eio.Cancel.protect @@ fun () ->
    let rec aux () =
      match Eio.Stream.take_nonblocking t.queue with
      | None -> ()
      | Some (Log entry) ->
          emit_to_sinks entry;
          aux ()
      | Some (Flush resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
      | Some (Shutdown resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
    in
    aux ();
    flush_sinks ()
  in
  Fun.protect ~finally:close_all (fun () ->
      match loop () with
      | `Stop_daemon -> `Stop_daemon
      | exception Eio.Cancel.Cancelled _ ->
          drain_on_cancel ();
          `Stop_daemon)

let create ~sw ~clock (config : Config.t) name =
  let now () =
    Eio.Time.now clock |> Ptime.of_float_s |> Option.value ~default:Ptime.epoch
  in
  let queue = Eio.Stream.create config.queue_depth in
  let drop_count = Atomic.make 0 in
  let closed = Atomic.make false in
  let t = { name; config; queue; drop_count; closed; now } in
  Eio.Fiber.fork_daemon ~sw (fun () -> worker_loop t);
  t

let log t ~level ?fields ?src_pos message =
  if Atomic.get t.closed then Atomic.incr t.drop_count
  else if is_enabled t level then begin
    let ctx = Context.current () in
    let merged_fields =
      match (ctx, fields) with
      | [], None -> None
      | [], Some f -> Some f
      | ctx, None -> Some ctx
      | ctx, Some f -> Some (ctx @ f)
    in
    let timestamp = t.now () in
    let entry =
      Entry.create ~level ~message ?fields:merged_fields ?src_pos ~timestamp ()
    in
    (* TOCTOU: a concurrent fiber may enqueue between the length check and add,
       causing add to briefly suspend. Accepted approximation for a drop-model
       logger; see RFC 0003 §Risks. *)
    if Eio.Stream.length t.queue < t.config.queue_depth then
      Eio.Stream.add t.queue (Log entry)
    else Atomic.incr t.drop_count
  end

let log_exn t ~level exn bt ?fields ?src_pos message =
  if Atomic.get t.closed then Atomic.incr t.drop_count
  else if is_enabled t level then begin
    let exn_fields =
      [
        ("exn.name", Value.String (Printexc.exn_slot_name exn));
        ("exn.message", Value.String (Printexc.to_string exn));
        ("exn.backtrace", Value.String (Printexc.raw_backtrace_to_string bt));
      ]
    in
    let ctx = Context.current () in
    let merged =
      match (ctx, fields) with
      | [], None -> exn_fields
      | [], Some user -> user @ exn_fields
      | ctx, None -> ctx @ exn_fields
      | ctx, Some user -> ctx @ user @ exn_fields
    in
    let timestamp = t.now () in
    let entry =
      Entry.create ~level ~message ~fields:merged ?src_pos ~timestamp ()
    in
    if Eio.Stream.length t.queue < t.config.queue_depth then
      Eio.Stream.add t.queue (Log entry)
    else Atomic.incr t.drop_count
  end

let flush t =
  if Atomic.get t.closed then ()
  else begin
    let promise, resolver = Eio.Promise.create () in
    (* [add] blocks until space is available — acceptable for a deliberate
       synchronisation point. See RFC 0003 §Risks for flush-after-cancel. *)
    Eio.Stream.add t.queue (Flush resolver);
    Eio.Promise.await promise
  end

let shutdown t =
  if Atomic.get t.closed then ()
  else begin
    Atomic.set t.closed true;
    let promise, resolver = Eio.Promise.create () in
    Eio.Stream.add t.queue (Shutdown resolver);
    Eio.Promise.await promise
  end

let diagnostics t =
  {
    name = t.name;
    queue_depth = Eio.Stream.length t.queue;
    queue_capacity = t.config.queue_depth;
    drop_count = Atomic.get t.drop_count;
    is_shutdown = Atomic.get t.closed;
  }
