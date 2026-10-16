# test/ (AGENTS.md)

Quickcheck properties of `Mirror` (duplicates, replay, rebalance; with a no-trade band: an
empty band plans what no band plans, replays and duplicates, the gap after full fills),
`No_trade_band` (edges, decisions, monotone in cost), the allocation pin
(`test_mirror_alloc.ml`), and expect tests of the other modules.

- Promote expect output with `dune promote` only after reading each diff.
- Generators for fixed-point values must stay in range (see the root pitfalls).
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-core/runtest`.
