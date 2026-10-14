# lib/ (AGENTS.md)

The `hl_copy_core` library. Pure modules: `Scale` (sizing), `Caps` (limits and their reasons),
`Rounding` (lots, ticks, significant figures), `Mirror` (per-follower state and plans), `Plan`,
`Score` (leader score), `Pnl`, `Follower_config` (validated sexp config), `Key_store` (sealed
agent keys on disk).

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-core/all`.

Rules that matter here:

- No I/O apart from `Key_store`. A new function that needs the clock takes the time as an argument.
- Each public function has an `.mli` entry with odoc that states its units (lots, ticks, USD).
- Rounding sizes toward zero to the lot; a delta below one lot plans nothing. Keep that rule.
