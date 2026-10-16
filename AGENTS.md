# AGENTS.md (hl-copy-core)

## Purpose

Pure copy-trading logic: position scaling, risk caps, rounding to exchange lots and ticks, the
mirroring state machine that turns leader and follower state into order plans, leader scoring
and per-leader pnl. No network, no clock and no mutable state, except the agent key files.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_copy_core` library: `Scale`, `Caps`, `Rounding`, `No_trade_band`, `Mirror`, `Plan`, `Score`, `Pnl`, `Follower_config`, `Key_store` ([lib/AGENTS.md](lib/AGENTS.md)) |
| `backtest/` | The `hl-copy-backtest` package: replays a leader's changes through `Mirror` from a leaderboard collection ([backtest/AGENTS.md](backtest/AGENTS.md)) |
| `bench/` | `main.exe`, the cost of one `Mirror` update ([bench/AGENTS.md](bench/AGENTS.md)) |
| `test/` | Quickcheck properties of `Mirror`, the allocation pin, and expect tests ([test/AGENTS.md](test/AGENTS.md)) |
| `README.md` | The formulas, the mirroring rules, the backtest model and outputs |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-core/all @hl-copy-core/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-copy-core` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

Benchmark: `dune exec bench/main.exe -- -quota 2`. Backtest: `dune exec hl-copy-backtest -- -help`.

Format only this repository, after the tests pass:
`dune build --root .. @hl-copy-core/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, ppx_jane
  derivations, expect tests and Base_quickcheck properties.
- Persisted types (journals, config files) live in `Stable.V1` with `sexp` and `bin_io`. A
  changed format is a new version, never an edit in place.
- Every function maps state and an event to a new state and a plan. Do not add a clock, a
  random source or a network call to this library.
- Mirroring properties are quickcheck properties: duplicated updates plan nothing new,
  replayed journals give the same plans and client ids, and a rebalance after full fills
  plans nothing. Keep them passing when you change `Mirror`. The no-trade band has its
  own: an empty band (zero cost, no quadratic term) plans exactly what no band plans, and
  the half-width is monotone in cost. A follow without a band must keep planning byte for
  byte what it planned before bands existed.
- The allocation pin in `test/` measures words; read how it pins them before changing it
  (see the cross-platform rule in the root workspace guide).
- Odoc on every public value; comments at every pinned number, saying what and why.

## Dependencies and dependents

- Depends on `fixed-decimal`, `exchange-core`, `hl-protocol`, `hl-client`, `market-data`,
  `parquet` and `venue-net`. The pin order is in `.github/workflows/ci.yml`.
- Used by `../hl-copy-engine` (mirror state, key store), `../hl-copy-api` (follower config,
  key store) and `../hl-leaderboard` (score).
- Spec: `../specs/repos/hl-copy-core.md`; the design is in `../specs/design/copytrading.md`.

## CI

`.github/workflows/ci.yml` builds and tests `hl-copy-core` with `--only-packages`, then does the
same for `hl-copy-backtest` in a second job where `hl-copy-core` is pinned at the commit under
test, so the backtest builds against the library being tested. `obj-magic` calls the shared reusable workflow from `infra`.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- `Fixed_decimal.mul_units` and `div_units` wrap silently out of range. Bound the ratios in
  quickcheck generators, or the property fails for reasons unrelated to the code under test.
- `Map.M(...)` over a market-data symbol derives `bin_io` directly; no hand-written codec is
  needed for it.
- The leverage cap sums over every position, so one `Mirror.apply` gets slower as the symbol
  count grows. Measure with `bench/` before you add a per-symbol loop.
- The agent key store seals keys with ChaCha20 and HMAC-SHA256 (encrypt-then-MAC), because the
  switch's cryptokit has no AEAD. Do not replace it without a new format version.
- A new field in `Mirror.t` adds a word to every record copy, and the allocation pin in
  `test/test_mirror_alloc.ml` moves with it; say so in the comment there.
- `Plan`, `Mirror.Config`, `Mirror` and `Follower_config` are on `Stable.V2`/`V3`: the
  engine journals plans and follow configs, so a new note reason or config field is a new
  version with `of_v*`/`to_v*`, never an edit in place.
- Scripted edits: assert the text to replace exists first, and run the formatter on the text
  before matching, since it reflows comments.

## Where to read more

- `README.md`, `../specs/repos/hl-copy-core.md`, `../specs/design/copytrading.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md`
- Skill: `../oxcaml-claude-skills/skills/oxcaml-performance` before changing `Mirror` for speed

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Publish, tag or release.
- Commit credentials or key material; keys come from the environment and the key store only.
- Print secrets or keys.
