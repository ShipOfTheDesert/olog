PPX _exn compile-error tests: malformed payloads must produce clear error messages.

Wrong arity — only logger, no exception or message (F11):

  $ cat > err.ml << 'EOF'
  > let () = [%log.error_exn logger]
  > EOF
  $ ./run_ppx_driver.exe --impl err.ml
  File "err.ml", line 1, characters 9-32:
  1 | let () = [%log.error_exn logger]
               ^^^^^^^^^^^^^^^^^^^^^^^
  Error: [log.error_exn]: expected `logger exn "msg"` or `logger exn "msg" [fields]`
  [1]

Non-string third argument (F12):

  $ cat > err.ml << 'EOF'
  > let () = [%log.error_exn logger (Failure "test") 42]
  > EOF
  $ ./run_ppx_driver.exe --impl err.ml
  File "err.ml", line 1, characters 9-52:
  1 | let () = [%log.error_exn logger (Failure "test") 42]
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  Error: [log.error_exn]: the third argument must be a string literal
  [1]
