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
}

type msg = Log of Entry.t | Flush of unit Eio.Promise.u

type t = {
  name : string;
  config : Config.t;
  queue : msg Eio.Stream.t;
  drop_count : int Atomic.t;
  now : unit -> Ptime.t;
      (* now: closure capturing the injected clock; avoids storing the polymorphic
     [> Eio.Time.clock_ty] type bound in a concrete record field. *)
}

let is_enabled t level = Level.compare level t.config.min_level >= 0

let worker_loop t =
  let close_all () =
    List.iter (fun sink -> try sink.close () with _ -> ()) t.config.sinks
  in
  let emit_to_sinks entry =
    List.iter (fun sink -> try sink.emit entry with _ -> ()) t.config.sinks
  in
  let flush_all resolver =
    List.iter (fun sink -> try sink.flush () with _ -> ()) t.config.sinks;
    Eio.Promise.resolve resolver ()
  in
  let rec loop () =
    let msg = Eio.Stream.take t.queue in
    (match msg with
    | Log entry -> emit_to_sinks entry
    | Flush resolver -> flush_all resolver);
    loop ()
  in
  Fun.protect ~finally:close_all (fun () -> loop ())

let create ~sw ~clock (config : Config.t) name =
  let now () =
    Eio.Time.now clock |> Ptime.of_float_s |> Option.value ~default:Ptime.epoch
  in
  let queue = Eio.Stream.create config.queue_depth in
  let drop_count = Atomic.make 0 in
  let t = { name; config; queue; drop_count; now } in
  Eio.Fiber.fork_daemon ~sw (fun () -> worker_loop t);
  t

let log t ~level ?fields ?src_pos message =
  if is_enabled t level then begin
    let timestamp = t.now () in
    let entry = Entry.create ~level ~message ?fields ?src_pos ~timestamp () in
    (* TOCTOU: a concurrent fiber may enqueue between the length check and add,
       causing add to briefly suspend. Accepted approximation for a drop-model
       logger; see RFC 0003 §Risks. *)
    if Eio.Stream.length t.queue < t.config.queue_depth then
      Eio.Stream.add t.queue (Log entry)
    else Atomic.incr t.drop_count
  end

let flush t =
  let promise, resolver = Eio.Promise.create () in
  (* [add] blocks until space is available — acceptable for a deliberate
     synchronisation point. See RFC 0003 §Risks for flush-after-cancel. *)
  Eio.Stream.add t.queue (Flush resolver);
  Eio.Promise.await promise

let diagnostics t =
  {
    name = t.name;
    queue_depth = Eio.Stream.length t.queue;
    queue_capacity = t.config.queue_depth;
    drop_count = Atomic.get t.drop_count;
  }
