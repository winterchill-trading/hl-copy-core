# Changes

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning once released.

## Unreleased

### Added

- `No_trade_band`: rebalance a symbol only when the gap to the target is outside a band
  derived from the estimated cost (fee plus a configured slippage, or a per-symbol
  estimate from the book) and a risk aversion; closed-form edges for proportional costs,
  a quadratic-cost variant that trades part of the way past the edge.
- `Follower_config.Stable.V3` with an optional `band`; left out of the file when unset,
  so V2 files read unchanged and a follow without a band writes the same text.
- `Mirror.Config.Stable.V2` and `Mirror.Stable.V2` (band and slippage estimates),
  `Mirror.on_slippage_estimate`.
- `Plan.Stable.V2`: a `Within_band` note with the gap, the half-width and the cost saved;
  `Plan.Stable.V2.to_v1` drops it.

### Changed

- One leader update allocates two more words (the mirror record has one more field).

## 0.1.0

- Scaling, caps, rounding, the mirror, plans, PnL attribution, leader score, follower
  config with execution algorithms, the agent key store, and the `hl-copy-backtest`
  package.
