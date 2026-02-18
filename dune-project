(lang dune 3.16)

(name olog)

(generate_opam_files true)

(source
 (github yourhandle/olog))

(license ISC)

(authors "Your Name")

(maintainers "Your Name <you@example.com>")

(package
 (name olog)
 (synopsis
  "Production-grade structured async logging for Eio-based OCaml applications")
 (description
  "olog provides structured JSON logging, fiber-local context propagation, async non-blocking emission, and configurable output destinations for OCaml 5 applications built on the Eio concurrency library.")
 (depends
  (ocaml
   (>= 5.2.0))
  (eio
   (>= 1.0))
  (eio_main
   (and
    :with-test
    (>= 1.0)))
  (ptime
   (>= 1.1))
  (yojson
   (>= 2.1))
  (alcotest
   (and
    :with-test
    (>= 1.7)))
  (ppxlib
   (>= 0.32))
  (cohttp-eio
   (>= 6.0))))
