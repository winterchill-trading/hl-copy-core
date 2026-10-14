# bench/ (AGENTS.md)

`main.exe` benchmarks one leader update through `Mirror` at 1, 20 and 100 symbols, and the cost
of placing an order.

Run from the repository root: `opam exec --switch 5.2.0+ox -- dune exec bench/main.exe -- -quota 2`.

Rules that matter here:

- Numbers in the README were measured on one laptop. Quote the machine next to any new number.
- Words per call are the figure to watch; `test/` pins them, so a bench-driven change must
  update the pin with a comment on why.
