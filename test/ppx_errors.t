PPX compile-error tests: malformed payloads must produce clear error messages.

Non-string message in 2-arg form (F6):

  $ cat > err.ml << 'EOF'
  > let () = [%log.info logger 42]
  > EOF
  $ ./run_ppx_driver.exe --impl err.ml
  File "err.ml", line 1, characters 9-30:
  1 | let () = [%log.info logger 42]
               ^^^^^^^^^^^^^^^^^^^^^
  Error: [log.info]: the second argument must be a string literal
  [1]

Non-string message in 3-arg form (F7):

  $ cat > err.ml << 'EOF'
  > let () = [%log.info logger 42 []]
  > EOF
  $ ./run_ppx_driver.exe --impl err.ml
  File "err.ml", line 1, characters 9-33:
  1 | let () = [%log.info logger 42 []]
               ^^^^^^^^^^^^^^^^^^^^^^^^
  Error: [log.info]: the second argument must be a string literal
  [1]

Wrong arity — only logger, no message (F8):

  $ cat > err.ml << 'EOF'
  > let () = [%log.info logger]
  > EOF
  $ ./run_ppx_driver.exe --impl err.ml
  File "err.ml", line 1, characters 9-27:
  1 | let () = [%log.info logger]
               ^^^^^^^^^^^^^^^^^^
  Error: [log.info]: expected `logger "msg"` or `logger "msg" [fields]`
  [1]
