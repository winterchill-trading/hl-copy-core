# hl-copy-core

Pure copy-trading logic for Hyperliquid followers: position sizing, risk caps, lot and
tick rounding, mirroring plans, leader scoring and per-leader PnL. No network, no clock,
no mutable state: every function maps a state and an event to a new state and a plan,
so an engine can journal the events and replay them after a restart.

Every persisted type has a `Stable.V1` with `bin_io` and `sexp`. Sizes, prices and USD
amounts are fixed-point decimals (10^-8 units) from `market-data` and `exchange-core`;
symbols are Hyperliquid coin names (`BTC`, `ETH`).

## Modules

| Module | What it does |
| --- | --- |
| `Scale` | Follower target size from the leader's position and both equities. |
| `Caps` | Allowlist, daily loss, notional per symbol, leverage, minimum order; explains every clamp. |
| `Rounding` | Lot and tick rounding, Hyperliquid's 5 significant figures, IOC limit prices. |
| `Plan` | IOC places and cancels, plus notes explaining caps and skips. |
| `Mirror` | Per-follower state machine: leader updates, fills, closes, resync, rebalance. |
| `Pnl` | Follower PnL attributed per leader (average-entry books). |
| `Score` | Leader score from fills and an equity curve. |
| `Fill`, `Usd`, `Cloid`, `Address` | Shared records and binable wrappers of the wire types. |

## Sizing (`Scale`)

With `l` the leader's signed position, `E_l` the leader's equity and `E_f` the
follower's:

| Mode | Target |
| --- | --- |
| `Equity_ratio` | `l * E_f / E_l` |
| `Multiplier m` | `l * m` (m clamped to [0, 1000]) |
| `Fixed_notional a` | `l * min(a, E_f) / E_l`: copy as if the follower had `a` to allocate |

A non-positive `E_l` gives zero (the mirror skips the symbol with a `No_leader_equity`
note instead of closing).

## Caps (`Caps`)

Applied in order to the scaled target. Caps only limit growth; they never force the
follower below what it already holds on the same side, so mark moves alone do not
trade.

1. Allowlist: symbols not listed are never traded.
2. Daily loss: once `E_f - E_day_start <= -max_daily_loss`, only reduce or close.
3. Notional per symbol: `|target| * mark <= max_notional_per_symbol`.
4. Leverage: `(other_notional + |target| * mark) / E_f <= max_leverage`.
5. The order `target - current` is truncated to the lot; under one lot or under
   `min_order_notional` (10 USD by default) it is dropped, except a full close.

## Rounding (`Rounding`)

Sizes truncate toward zero to the lot. Hyperliquid perps (`Spec.hyperliquid_perp
~sz_decimals`): lot `10^-sz_decimals`, at most `6 - sz_decimals` price decimals and five
significant figures (integer prices always valid). IOC limits sit `slippage_bps` through
the mark and are rounded toward the mark (buys down, sells up), so rounding never widens
the bound.

## Mirroring (`Mirror`)

Targets are absolute. For a symbol the mirror computes the capped target, subtracts the
follower's position and the in-flight orders that still move toward the target (oldest
first, never passing it), cancels the in-flight orders that point the wrong way or
overshoot, and places one IOC order for the remainder. Consequences:

- a duplicated or replayed leader update plans nothing new while earlier orders are in
  flight (property-tested);
- replaying a journal of `Mirror.Event.t` from the same start gives the same states and
  plans, client order ids included (`Cloid.create ~follower ~seq`);
- once every order has filled, a rebalance places nothing and the follower is within one
  lot (or the minimum notional) of the target (property-tested);
- only symbols the leader has held are traded, so the follower's own positions elsewhere
  are left alone.

Leader equity changes apply from the next position change or `rebalance`.

Cost of one leader update (`bench/main.exe`, Apple M-series, `-quota 1`):

| Symbols | No-op update | Update placing one order |
| ---: | ---: | ---: |
| 1 | 186 ns, 89 words | 481 ns, 191 words |
| 20 | 1.26 us, 125 words | 1.55 us, 227 words |
| 100 | 7.28 us, 161 words | 7.59 us, 263 words |

The growth with the symbol count is the leverage cap's sum over the other positions.
`test/test_mirror_alloc.ml` pins the minor words.

## PnL attribution (`Pnl`)

One average-entry book per leader and symbol. A fill with the position (or from flat)
moves the entry to `(|s| * a + |q| * p) / |s + q|`; a fill against it realizes
`min(|q|, |s|) * (p - a) * sign(s)` and any excess opens at `p`. Unrealized is
`s * (mark - a)`; net is `realized + unrealized - fees`.

## Leader score (`Score`)

From the leader's fills and equity curve, sorted first so input order does not matter:

- `pnl = sum(closed_pnl - fee)`; `return_ = pnl / E_0` (first equity point).
- `max_drawdown = max((peak - equity) / peak)` over the curve, in [0, 1].
- Round trips per symbol: open when the position leaves zero, close when it returns to
  zero or flips. `trade_count` counts closed trips, `win_rate` the share with positive
  pnl, `avg_hold_ns` their mean duration.
- `consistency`: the covered time span is cut into `windows` (default 4) equal windows;
  the share of windows with positive `closed_pnl - fee`.
- `score = return_ * (1 - max_drawdown) * (0.5 + 0.5 * consistency) * min(1, trade_count / 20)`.

## Build

```
dune build
dune test
dune exec bench/main.exe -- -quota 2
```
