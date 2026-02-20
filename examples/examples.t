Example smoke tests: verify examples run and produce expected output.
Timestamps are normalised to TIMESTAMP for deterministic comparison.

basic.ml — text formatter, direct Logger API:

  $ ./basic.exe 2>&1 | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TIMESTAMP/g'
  TIMESTAMP INFO server starting
  TIMESTAMP WARN low disk space free_mb=42
  TIMESTAMP ERROR connection failed host=db.local
  diagnostics: name=basic queue_depth=0 drop_count=0

structured.ml — JSON formatter, PPX, context fields:

  $ ./structured.exe 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"TIMESTAMP"/g'
  {"timestamp":"TIMESTAMP","level":"info","message":"server started","request_id":"req-abc123","port":8080,"src_pos":{"file":"examples/structured.ml","line":14,"col":2}}
  {"timestamp":"TIMESTAMP","level":"info","message":"request received","request_id":"req-abc123","method":"GET","path":"/health","src_pos":{"file":"examples/structured.ml","line":15,"col":2}}
  {"timestamp":"TIMESTAMP","level":"warn","message":"slow response","request_id":"req-abc123","duration_ms":523,"threshold_ms":500,"src_pos":{"file":"examples/structured.ml","line":17,"col":2}}
