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
    (>= 1.7)))))

(package
 (name olog_ppx)
 (synopsis "PPX for automatic source-location injection in olog log calls")
 (description
  "Provides [%%log.LEVEL] extension points that expand to guarded Logger.log
   calls with compile-time source location and automatic Value wrapping for
   literal field values.")
 (depends
  (ppxlib
   (>= 0.32))
  (olog
   (= :version))
  (eio_main
   (and
    :with-test
    (>= 1.0)))
  (alcotest
   (and
    :with-test
    (>= 1.7)))
  (yojson
   (and
    :with-test
    (>= 2.1)))))
