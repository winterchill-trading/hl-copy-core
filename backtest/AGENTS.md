# backtest/ (AGENTS.md)

The `hl-copy-backtest` package. It estimates what a follower would have earned copying a
leader, from a leaderboard collection directory alone. `lib/` holds `Leader_change`, `Input`,
`Specs`, `Collection`, `Backtest`, `Ranking` and `Report`; `bin/` holds the command; `test/`
holds its tests and fixtures.

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-core/all`
(the package is part of the `hl-copy-core` repository).

Rules that matter here:

- Fills execute at the leader's price moved by the configured slippage, inside the order's IOC
  limit, with the taker fee. The model and its outputs are in the README; change them there too.
- The package reads a collection and never talks to the network.
