Example smoke tests: verify examples run and produce expected output.
Timestamps are normalised to TIMESTAMP for deterministic comparison.

basic.ml — text formatter, direct Logger API:

  $ ./basic.exe 2>&1 | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TIMESTAMP/g'
  TIMESTAMP INFO server starting
  TIMESTAMP WARN low disk space free_mb=42
  TIMESTAMP ERROR connection failed host=db.local
  diagnostics: name=basic queue_depth=0 drop_count=0 is_shutdown=false

structured.ml — JSON formatter, PPX, context fields:

  $ ./structured.exe 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  {"timestamp":"TIMESTAMP","level":"info","message":"server started","fields":{"request_id":"req-abc123","port":8080},"src_pos":{"file":"examples/structured.ml","line":24,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"request received","fields":{"request_id":"req-abc123","method":"GET","path":"/health"},"src_pos":{"file":"examples/structured.ml","line":25,"col":2}}
  {"timestamp":"TIMESTAMP","level":"warn","message":"slow response","fields":{"request_id":"req-abc123","duration_ms":523,"threshold_ms":500},"src_pos":{"file":"examples/structured.ml","line":27,"col":2}}

context_propagation.ml — nested context, override, fiber isolation:

  $ ./context_propagation.exe 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  {"timestamp":"TIMESTAMP","level":"info","message":"handling request","fields":{"request_id":"req-001","endpoint":"/users"},"src_pos":{"file":"examples/context_propagation.ml","line":31,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"authorized user","fields":{"request_id":"req-001","user_id":42},"src_pos":{"file":"examples/context_propagation.ml","line":35,"col":2}}
  {"timestamp":"TIMESTAMP","level":"warn","message":"retrying with new correlation id","fields":{"user_id":42,"request_id":"req-002-retry"},"src_pos":{"file":"examples/context_propagation.ml","line":40,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"background task started","fields":{"task":"cleanup"},"src_pos":{"file":"examples/context_propagation.ml","line":45,"col":6}}
  {"timestamp":"TIMESTAMP","level":"info","message":"background task running","fields":{"task_id":"bg-007"},"src_pos":{"file":"examples/context_propagation.ml","line":49,"col":19}}
  {"timestamp":"TIMESTAMP","level":"info","message":"request complete","fields":{"user_id":42,"request_id":"req-002-retry","status":200},"src_pos":{"file":"examples/context_propagation.ml","line":52,"col":2}}

error_handling.ml — manual log_exn and PPX log_exn:

  $ ./error_handling.exe 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  {"timestamp":"TIMESTAMP","level":"error","message":"database connection failed","fields":{"host":"db.prod.internal","attempt":1,"exn.name":"Dune__exe__Error_handling.Connection_refused","exn.message":"Dune__exe__Error_handling.Connection_refused(\"refused by db.prod.internal:5432\")","exn.backtrace":""}}
  {"timestamp":"TIMESTAMP","level":"error","message":"replica connection failed","fields":{"host":"db.replica.internal","attempt":2,"exn.name":"Dune__exe__Error_handling.Connection_refused","exn.message":"Dune__exe__Error_handling.Connection_refused(\"refused by db.replica.internal:5432\")","exn.backtrace":""},"src_pos":{"file":"examples/error_handling.ml","line":45,"col":5}}

custom_output.ml — Output.make with buffer sink, dual destinations:

  $ ./custom_output.exe 2>&1 | sed -E -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TIMESTAMP/g' -e 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  TIMESTAMP INFO event one key=value
  TIMESTAMP WARN event two count=42
  
  --- captured buffer (325 bytes) ---
  {"timestamp":"TIMESTAMP","level":"info","message":"event one","fields":{"key":"value"},"src_pos":{"file":"examples/custom_output.ml","line":40,"col":2}}
  {"timestamp":"TIMESTAMP","level":"warn","message":"event two","fields":{"count":42},"src_pos":{"file":"examples/custom_output.ml","line":41,"col":2}}

ppx_showcase.ml — all levels, auto-wrapping, variants, exn:

  $ ./ppx_showcase.exe 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  {"timestamp":"TIMESTAMP","level":"info","message":"server started","fields":{"port":8080,"host":"0.0.0.0"},"src_pos":{"file":"examples/ppx_showcase.ml","line":32,"col":2}}
  {"timestamp":"TIMESTAMP","level":"debug","message":"initializing subsystems","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":35,"col":2}}
  {"timestamp":"TIMESTAMP","level":"trace","message":"metrics snapshot","fields":{"cpu_pct":42.5,"healthy":true,"gpu_pct":0.0},"src_pos":{"file":"examples/ppx_showcase.ml","line":38,"col":2}}
  {"timestamp":"TIMESTAMP","level":"trace","message":"trace level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":43,"col":2}}
  {"timestamp":"TIMESTAMP","level":"debug","message":"debug level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":44,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"info level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":45,"col":2}}
  {"timestamp":"TIMESTAMP","level":"warn","message":"warn level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":46,"col":2}}
  {"timestamp":"TIMESTAMP","level":"error","message":"error level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":47,"col":2}}
  {"timestamp":"TIMESTAMP","level":"fatal","message":"fatal level","fields":{},"src_pos":{"file":"examples/ppx_showcase.ml","line":48,"col":2}}
  {"timestamp":"TIMESTAMP","level":"error","message":"operation timed out","fields":{"timeout_ms":5000,"exn.name":"Dune__exe__Ppx_showcase.Timeout","exn.message":"Dune__exe__Ppx_showcase.Timeout","exn.backtrace":""},"src_pos":{"file":"examples/ppx_showcase.ml","line":53,"col":5}}
  {"timestamp":"TIMESTAMP","level":"info","message":"request complete","fields":{"status":200,"latency_ms":123.456},"src_pos":{"file":"examples/ppx_showcase.ml","line":57,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"user logged out","fields":{"next_url":null},"src_pos":{"file":"examples/ppx_showcase.ml","line":62,"col":2}}
