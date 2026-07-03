type sink = {
  name : string;
  emit : Entry.t list -> (unit, string) result;
  flush : unit -> (unit, string) result;
  close : unit -> (unit, string) result;
}

type timestamp_fallback = Fail | Mark_invalid

module Config = struct
  type t = {
    min_level : Level.t;
    queue_depth : int;
    sinks : sink list;
    timestamp_fallback : timestamp_fallback;
  }

  let make ~min_level ~queue_depth ~sinks ?(timestamp_fallback = Mark_invalid)
      () =
    if queue_depth < 1 then
      Error
        (Printf.sprintf "Config.make: queue_depth must be >= 1, got %d"
           queue_depth)
    else Ok { min_level; queue_depth; sinks; timestamp_fallback }
end

type diagnostics = {
  name : string;
  queue_depth : int;
  queue_capacity : int;
  emit_count : int;
  drop_count : int;
  drops_queue_full : int;
  drops_after_shutdown : int;
  drops_on_cancel : int;
  is_shutdown : bool;
}

type state = Running | Stopping | Stopped
(* Lifecycle state machine. Transitions are monotonic — forward only:
   Running -> Stopping -> Stopped. Written via [compare_and_set] except the
   worker's terminal set to [Stopped] in its [finally]. Replaces the former
   [closed : bool Atomic.t] plus implicit "worker alive iff not closed"
   invariant that two code paths could break independently. *)

(* [Shutdown] carries no resolver: every shutdown caller awaits [stopped],
   which the worker resolves on every exit path. *)
type msg = Log of Entry.t | Flush of unit Eio.Promise.u | Shutdown

type t = {
  name : string;
  config : Config.t;
  queue : msg Eio.Stream.t;
  mutex : Eio.Mutex.t;
      (* Serialises the producer state-check-and-add with the [shutdown] CAS and
         the cancellation [Stopped]-set, so an accepted entry is never lost: it
         is either enqueued (and later emitted) or the producer observes a
         non-[Running] state and counts a drop. The worker never holds it while
         performing sink I/O (RFC 0013 F5). Multi-domain safety (PRD FR2) rests
         on [Eio.Mutex] guarding its state with a [Stdlib.Mutex] and [Eio.Stream]
         being documented thread-safe (verified, Eio 1.3) — so the
         [Domain_manager] conservation tests are race-free, not accidental. *)
  emit_count : int Atomic.t;
      (* The accounting counters. There is no stored drop total: [diagnostics]
         derives it as the sum of the three cause counters, so
         [drop_count = Σ causes] holds in every snapshot by construction —
         a stored total incremented separately could be observed out of sync
         with its causes between the two increments. *)
  drops_queue_full : int Atomic.t;
  drops_after_shutdown : int Atomic.t;
  drops_on_cancel : int Atomic.t;
  state : state Atomic.t;
  stopped : unit Eio.Promise.t;
      (* resolved by the worker's [finally] on every exit path — the single,
         always-resolved join point for [flush]/[shutdown] liveness *)
  stopped_r : unit Eio.Promise.u;
  now : unit -> Ptime.t option;
      (* now: closure capturing the injected clock; avoids storing the polymorphic
     [> Eio.Time.clock_ty] type bound in a concrete record field. Returns [None]
     when the clock reading is unrepresentable as a [Ptime.t]; the timestamp
     policy is applied by the caller, not here (RFC 0013 F6). *)
}

(* Exhaustive lifecycle predicate, colocated with [state]: a new constructor
   becomes a compile error here rather than a silent misclassification. *)
let is_shutting_down = function Running -> false | Stopping | Stopped -> true
let is_enabled t level = Level.compare level t.config.min_level >= 0

(* [Mark_invalid] policy (RFC 0013 F6): when the clock reading is
   unrepresentable, keep the entry but stamp [Ptime.epoch] and tag it with the
   reserved [olog.invalid_timestamp] marker so the corruption is machine-
   detectable downstream. Returns the timestamp to stamp and the marker fields
   to append (empty when the reading was valid). *)
let resolve_timestamp = function
  | Some ts -> (ts, [])
  | None -> (Ptime.epoch, [ ("olog.invalid_timestamp", Value.bool true) ])

(* Best-effort fallback line for a sink failure, written to the raw process
   stderr (ADR 0006 semantics, relocated from Output.protect to the worker).
   Wrapped so a broken fd 2 cannot cascade. *)
let report_sink_error name msg =
  try Printf.eprintf "[olog error] %s: %s\n%!" name msg with _ -> ()

(* Run one sink operation under the result contract (ADR 0007 continue-on-
   failure). [Eio.Cancel.Cancelled] is always re-raised so the worker can shut
   down; every other outcome is reported and swallowed so one sink's failure
   never stops delivery to the others or to later entries. *)
let run_sink_op name op =
  match op () with
  | Ok () -> ()
  | Error msg -> report_sink_error name msg
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> report_sink_error name (Printexc.to_string exn)

let worker_loop t =
  let sinks_closed = ref false in
  let close_all () =
    if not !sinks_closed then begin
      sinks_closed := true;
      List.iter
        (fun (sink : sink) -> run_sink_op sink.name (fun () -> sink.close ()))
        t.config.sinks
    end
  in
  let emit_to_sinks entries =
    (* Count the batch as emitted *before* dispatching. Once entries are off
       the queue they must be accounted somewhere; if a sink re-raises
       [Cancelled] mid-dispatch (aborting the worker), counting afterwards
       would leave them neither emitted nor dropped and break conservation.
       This also implements ADR 0007's batch granularity: a failed batch
       still counts as emitted. Counted once per entry, not per sink. *)
    ignore (Atomic.fetch_and_add t.emit_count (List.length entries) : int);
    List.iter
      (fun (sink : sink) -> run_sink_op sink.name (fun () -> sink.emit entries))
      t.config.sinks
  in
  let flush_sinks () =
    List.iter
      (fun (sink : sink) -> run_sink_op sink.name (fun () -> sink.flush ()))
      t.config.sinks
  in
  let drain_trailing () =
    let rec aux () =
      match Eio.Stream.take_nonblocking t.queue with
      | None -> ()
      (* The producer mutex prevents a Log from following Shutdown in the queue,
         so this arm is defensive — but a straggler is counted as a drop rather
         than silently discarded, preserving conservation (RFC 0013 F5). It is
         attributed to [drops_after_shutdown]: the worker is already processing
         [Shutdown] when it finds the straggler. *)
      | Some (Log _) ->
          Atomic.incr t.drops_after_shutdown;
          aux ()
      | Some (Flush resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
      | Some Shutdown -> aux ()
    in
    aux ()
  in
  let rec loop () = handle (Eio.Stream.take t.queue)
  and handle = function
    | Log entry -> (
        (* Greedy batch drain (FR2, Feature 0018): after the blocking take of a
           [Log], collect further consecutive [Log]s without blocking and emit
           them as one batch per sink. The collection stops at the first
           control message so no entry is written past a [Flush]/[Shutdown]
           barrier enqueued before it — the FIFO ordering ADR 0004 guarantees
           by construction is preserved through the batching. The control
           message that ended the collection is already off the queue, so it is
           handed straight to [handle] after the batch is emitted. *)
        let rec collect acc =
          match Eio.Stream.take_nonblocking t.queue with
          | Some (Log e) -> collect (e :: acc)
          | Some ((Flush _ | Shutdown) as control) ->
              (List.rev acc, Some control)
          | None -> (List.rev acc, None)
        in
        let batch, control = collect [ entry ] in
        emit_to_sinks batch;
        match control with Some msg -> handle msg | None -> loop ())
    | Flush resolver ->
        flush_sinks ();
        Eio.Promise.resolve resolver ();
        loop ()
    | Shutdown ->
        flush_sinks ();
        close_all ();
        drain_trailing ();
        `Stop_daemon
  in
  let drain_on_cancel () =
    Eio.Cancel.protect @@ fun () ->
    (* Publish [Stopped] under the producer mutex before draining: this is the
       barrier that makes cancellation conserve. A producer that already added
       its entry held the mutex before us, so its entry is in the queue and is
       drained below; a producer that arrives after sees [Stopped] and drops.
       No sink I/O runs under the lock (RFC 0013 F5). *)
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        Atomic.set t.state Stopped);
    let rec aux () =
      match Eio.Stream.take_nonblocking t.queue with
      | None -> ()
      | Some (Log entry) ->
          emit_to_sinks [ entry ];
          aux ()
      | Some (Flush resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
      | Some Shutdown -> aux ()
    in
    aux ();
    flush_sinks ()
  in
  (* Publish [Stopped] and account for anything still queued as a drop,
     attributed to [drops_on_cancel]: everything counted here was accepted but
     lost because the worker is terminating without a graceful drain. On the
     normal ([drain_trailing]) and completed-cancellation ([drain_on_cancel])
     exit paths the queue is already empty, so this does nothing; it only does
     work if the worker unwinds via an *unexpected* exception — including a
     sink re-raising [Cancelled] mid-drain, which aborts [drain_on_cancel] —
     with entries still queued, keeping conservation unconditional (RFC 0013
     F5). It counts rather than emits because emitting mid-fault could
     re-enter the failure. Wrapped in
     [Cancel.protect] so a cancelled daemon can still take the mutex; if an
     earlier fault poisoned the mutex, fall back to a lock-free stop — this
     drain must never raise. *)
  let stop_and_count_drain () =
    Eio.Cancel.protect @@ fun () ->
    (try
       Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
           Atomic.set t.state Stopped)
     with Eio.Mutex.Poisoned _ -> Atomic.set t.state Stopped);
    let rec aux () =
      match Eio.Stream.take_nonblocking t.queue with
      | None -> ()
      | Some (Log _) ->
          Atomic.incr t.drops_on_cancel;
          aux ()
      | Some (Flush resolver) ->
          Eio.Promise.resolve resolver ();
          aux ()
      | Some Shutdown -> aux ()
    in
    aux ()
  in
  (* Runs on every exit path — normal [Shutdown], switch cancellation, or an
     unexpected exception. Publishes [Stopped], drains any straggler as a
     counted drop, and resolves [stopped] so no [flush]/[shutdown] caller can
     await a promise that never resolves (RFC 0013 F1, F2). [close_all] is
     idempotent. *)
  let finally () =
    stop_and_count_drain ();
    close_all ();
    Eio.Promise.resolve t.stopped_r ()
  in
  Fun.protect ~finally (fun () ->
      match loop () with
      | `Stop_daemon -> `Stop_daemon
      | exception Eio.Cancel.Cancelled _ ->
          drain_on_cancel ();
          `Stop_daemon)

let create ~sw ~clock (config : Config.t) name =
  let now () = Eio.Time.now clock |> Ptime.of_float_s in
  (* [Fail] mode probes the clock once at creation and refuses to start a worker
     if the reading is already unrepresentable. A residual failure (clock breaks
     after this probe) cannot be rejected here — [log] must never raise — so it
     falls back to the [Mark_invalid] behaviour (RFC 0013 F6). *)
  let probe =
    match config.timestamp_fallback with
    | Mark_invalid -> Ok ()
    | Fail -> (
        match now () with
        | Some _ -> Ok ()
        | None ->
            Error
              "Logger.create: timestamp_fallback = Fail and the clock yields \
               an unrepresentable timestamp")
  in
  match probe with
  | Error _ as err -> err
  | Ok () ->
      let queue = Eio.Stream.create config.queue_depth in
      let mutex = Eio.Mutex.create () in
      let emit_count = Atomic.make 0 in
      let drops_queue_full = Atomic.make 0 in
      let drops_after_shutdown = Atomic.make 0 in
      let drops_on_cancel = Atomic.make 0 in
      let state = Atomic.make Running in
      let stopped, stopped_r = Eio.Promise.create () in
      let t =
        {
          name;
          config;
          queue;
          mutex;
          emit_count;
          drops_queue_full;
          drops_after_shutdown;
          drops_on_cancel;
          state;
          stopped;
          stopped_r;
          now;
        }
      in
      Eio.Fiber.fork_daemon ~sw (fun () -> worker_loop t);
      Ok t

(* Producer fast path. Under the mutex an accepted entry is enqueued iff the
   logger is [Running] and the queue has room; otherwise it is counted as a
   drop. The critical section performs no sink I/O and never blocks — space is
   checked before the add and only the worker (which solely takes) can change
   the length while the lock is held, so the add always has room. The single
   suspension point is the lock acquire, uncontended on the common path
   (RFC 0013 R1). *)
let enqueue_or_drop t entry =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match Atomic.get t.state with
      | Running when Eio.Stream.length t.queue < t.config.queue_depth ->
          Eio.Stream.add t.queue (Log entry)
      | Running -> Atomic.incr t.drops_queue_full
      | Stopping | Stopped -> Atomic.incr t.drops_after_shutdown)

let log t ~level ?fields ?src_pos message =
  if is_enabled t level then begin
    let ctx = Context.current () in
    let merged_fields =
      match (ctx, fields) with
      | [], None -> None
      | [], Some f -> Some f
      | ctx, None -> Some ctx
      | ctx, Some f -> Some (ctx @ f)
    in
    let timestamp, ts_fields = resolve_timestamp (t.now ()) in
    (* The reserved marker is appended last so it wins over any user field of the
       same (reserved) name, mirroring how [exn.] fields take precedence. *)
    let merged_fields =
      match (merged_fields, ts_fields) with
      | m, [] -> m
      | None, extra -> Some extra
      | Some m, extra -> Some (m @ extra)
    in
    let entry =
      Entry.create ~level ~message ?fields:merged_fields ?src_pos ~timestamp ()
    in
    enqueue_or_drop t entry
  end

let log_exn t ~level exn bt ?fields ?src_pos message =
  if is_enabled t level then begin
    let exn_fields =
      [
        ("exn.name", Value.string (Printexc.exn_slot_name exn));
        ("exn.message", Value.string (Printexc.to_string exn));
        ("exn.backtrace", Value.string (Printexc.raw_backtrace_to_string bt));
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
    let timestamp, ts_fields = resolve_timestamp (t.now ()) in
    (* Guard the append so the common (valid-clock) path does not copy [merged]
       just to concatenate an empty list. *)
    let merged =
      match ts_fields with [] -> merged | _ :: _ -> merged @ ts_fields
    in
    let entry =
      Entry.create ~level ~message ~fields:merged ?src_pos ~timestamp ()
    in
    enqueue_or_drop t entry
  end

let flush t =
  match Atomic.get t.state with
  | Stopping | Stopped -> ()
  | Running ->
      let promise, resolver = Eio.Promise.create () in
      (* [add] blocks until space is available — acceptable for a deliberate
         synchronisation point. *)
      Eio.Stream.add t.queue (Flush resolver);
      (* Await whichever comes first: the worker fulfilling this flush, or the
         worker dying (switch cancellation between the check and the take). The
         [stopped] arm guarantees liveness (RFC 0013 F1, R4); the abandoned
         [Flush] resolver is harmlessly resolved by the worker's drain. *)
      Eio.Fiber.first
        (fun () -> Eio.Promise.await promise)
        (fun () -> Eio.Promise.await t.stopped)

let shutdown t =
  (* The CAS runs under the mutex so it is atomic with respect to producers:
     once the winner publishes [Stopping], every producer that next takes the
     mutex observes a non-[Running] state and drops — so no [Log] can ever
     follow [Shutdown] in the queue, the property conservation depends on.
     [Shutdown] is added outside the lock (the add may block on a full queue,
     and holding the lock across that block could deadlock the cancellation
     drain, which also needs the mutex). A [flush] that read [Running] just
     before the CAS may still enqueue a [Flush] after [Shutdown]; that is
     harmless — the worker stops at [Shutdown] and [drain_trailing] resolves the
     straggler — so [Shutdown] is the last *Log-bearing* message, not literally
     the last message. Winner, losers, and post-mortem callers all await
     [stopped] — the worker's [finally] resolves it on every exit path
     (RFC 0013 F2). *)
  let won =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        Atomic.compare_and_set t.state Running Stopping)
  in
  if won then Eio.Stream.add t.queue Shutdown;
  Eio.Promise.await t.stopped

let diagnostics t =
  let drops_queue_full = Atomic.get t.drops_queue_full in
  let drops_after_shutdown = Atomic.get t.drops_after_shutdown in
  let drops_on_cancel = Atomic.get t.drops_on_cancel in
  {
    name = t.name;
    queue_depth = Eio.Stream.length t.queue;
    queue_capacity = t.config.queue_depth;
    emit_count = Atomic.get t.emit_count;
    drop_count = drops_queue_full + drops_after_shutdown + drops_on_cancel;
    drops_queue_full;
    drops_after_shutdown;
    drops_on_cancel;
    is_shutdown = is_shutting_down (Atomic.get t.state);
  }
