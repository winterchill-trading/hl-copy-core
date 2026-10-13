(lang dune 3.17)

(name hl-copy-core)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/hl-copy-core))

(package
 (name hl-copy-core)
 (synopsis
  "Pure copy-trading logic: sizing, risk caps, rounding, mirroring plans and leader scoring")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  cryptokit
  ppx_jane
  bin_prot
  fixed-decimal
  exchange-core
  hl-protocol
  market-data
  (core_bench :with-test)))
