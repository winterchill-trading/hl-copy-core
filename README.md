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
| `Follower_config` | One follow (follower, leader, mode, caps, slippage, paused) as a sexp file; builds the `Mirror.Config.t`. |
| `Score` | Leader score from fills and an equity curve. |
| `Fill`, `Usd`, `Cloid`, `Address` | Shared records and binable wrappers of the wire types. |

## Sizing (`Scale`)

With `l` the leader's signed position, `E_l` the leader's equity and `E_f` the
follower's:

| Mode | Target |
| --- | --- |
| `Equity_ratio` | `l * E_f / E_l`: both accounts carry the same leverage |
| `Multiplier k` | `l * k * E_f / E_l`: `k = 0.5` halves the leader's leverage (k clamped to [0, 100]) |
| `Fixed_notional n` | `sign(l) * n / mark`: `n` USD per open leader position, whatever its size |

For the equity modes the mirror skips a symbol with a `No_leader_equity` note while the
leader's equity is unknown, instead of closing.

## Caps (`Caps`)

Applied in order to the scaled target. Apart from the daily loss limit, caps only limit
growth; they never force the follower below what it already holds on the same side, so
mark moves alone do not trade.

1. Allowlist: symbols not listed are never traded.
2. Daily loss: once `E_f - E_day_start <= -max_daily_loss`, every target is zero: the
   follower closes out and stays flat until `Mirror.start_day` (next UTC day or a manual
   resume).
3. Notional per symbol: `|target| * mark <= max_notional_per_symbol`.
4. Leverage: `(other_notional + |target| * mark) / E_f <= max_leverage`.
5. The order `target - current` is truncated to the lot; under one lot or under
   `min_order_notional` (10 USD by default) it is dropped, except a full close.

## Rounding (`Rounding`)

Sizes truncate toward zero to the lot. Hyperliquid perps (`Spec.hyperliquid_perp
~sz_decimals`): lot `10^-sz_decimals`, at most `6 - sz_decimals` price decimals and five
significant figures (integer prices always valid). IOC limits sit `slippage_bps` (20 by default in `Follower_config`) through
the reference price the engine passes as `mark` (best bid or ask, or the mid) and are rounded toward the mark (buys down, sells up), so rounding never widens
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

## Backtest (`hl-copy-backtest`)

A second package in this repository, `hl-copy-backtest` (library `Hl_copy_backtest` in
`backtest/lib`, binary `hl-copy-backtest`), estimates what a follower would have earned
copying a leader, from recorded data only. It reads an
[hl-leaderboard](https://github.com/winterchill-trading/hl-leaderboard) collection
directory through that package's `Dataset` and `Rank` modules, so it sees exactly the
fills and equity curve the leader score sees: perpetual fills only, with a synthetic
opening fill for every coin already held when the history starts, and the `portfolio`
month curve (or the curve rebuilt from fills). It depends on `hl-leaderboard`, which
depends on `hl-copy-core`, so CI builds the two packages in separate jobs.

```sh
# One leader: a text summary; -out adds backtest.json (with the curve) and Parquet
hl-copy-backtest -dir data -leader 0x... [-config follow.sexp] [-equity 10000] \
  [-slippage-bps 5] [-fee-bps 4.5] [-meta meta.json] [-out out/]

# Every leader in the directory, ranked by follower pnl; prints the top N
hl-copy-backtest -dir data -leaders 20 [same flags]

# Exact size decimals: save the perpetuals meta once (a read-only info request)
curl -s https://api.hyperliquid.xyz/info -H 'Content-Type: application/json' \
  -d '{"type":"meta"}' > meta.json
```

`-config` takes a follow file as the API writes it (`Follower_config`: mode, caps, IOC
slippage; its leader is replaced by the replayed one). Without it the follow is
`Equity_ratio`, no caps but the 10 USD minimum order, and a 20 bps IOC limit.

### Model

The leader's fills become position changes (`Leader_change`: fills of one coin, side
and millisecond are one order, priced at their volume-weighted average). For each
change, oldest first:

1. On the first change of a new UTC day the daily-loss window restarts
   (`Mirror.start_day`).
2. The change's price becomes the coin's mark. The follower's equity
   (`start + realized - fees + unrealized at the marks`) and the leader's (its curve at
   that time, the latest point before it) go to the mirror.
3. `Mirror.on_leader_position_change` plans the follower's IOC orders: scaling, caps,
   lot and tick rounding, minimum notional.
4. Each order fills in full at the change's price moved `-slippage-bps` against the
   follower, if that price is inside the order's IOC limit (the follow's
   `slippage_bps` through the mark); otherwise it does not fill. Every fill pays
   `-fee-bps` of its notional (4.5 bp, Hyperliquid's base-tier taker fee).
5. One curve point is recorded.

The follower's books use `Pnl.Position` (average entry). Positions are marked to the
leader's fill prices, so a coin's mark moves only when the leader trades it. Funding,
liquidations, partial fills and latency are not modelled.

Specs come from `-meta` when given; coins missing from it (builder perps such as
`xyz:NVDA`), or every coin without `-meta`, get the fewest size decimals that all
recorded fills of that coin fit (`Specs.infer`). That never rounds finer than the venue,
but with few or round fills it can be much coarser, and orders then drop as
`below_lot`.

### Output

| Field | Meaning |
| --- | --- |
| `pnl`, `return`, `max_drawdown` | Follower equity curve: end minus start, over start, largest fall from a peak |
| `realized`, `unrealized`, `fees`, `turnover` | Books at the end; turnover is the sum of filled notional |
| `orders`, `unfilled_orders` | IOC orders placed; those whose slipped price was beyond the limit |
| `leader_changes`, `changes_traded`, `changes_capped`, `changes_skipped`, `skip_rate` | Leader changes; those that placed an order (with a cap note), and those that placed none because of a cap, the lot, the minimum notional or a missing spec or leader equity |
| `reasons` | Per note reason (`below_min_notional`, `below_lot`, `leverage`, `symbol_notional`, `daily_loss`, `not_allowlisted`, `no_spec`, `no_mark`, `no_leader_equity`), the number of changes it appeared in |
| `leader_mtm_pnl`, `leader_mtm_return` | The leader's own fills on the same books, real fees, same final marks, over its curve equity at the start: what a perfect copy would track before scaling and costs |
| `leader_return`, `leader_max_drawdown` | The leader's curve over the same window |
| `leader_fill_pnl` | `closedPnl - fee` of the replayed fills (includes gains on positions opened before the history) |

`-out DIR` writes `backtest.json` (params and one object per leader, ranked; the curve
as `[[time_ms, equity, leader_equity], ...]` for a single leader), `results.parquet`
(one row per leader) and `curves.parquet` (`address`, `time`, `equity`,
`leader_equity`); columns are listed in `backtest/lib/report.mli`.

### Mainnet sample

hl-leaderboard's read-only collection of 2026-10-13 (34 candidates, 155k fills; see its
README), with the mainnet `meta` of the same day, $10,000 of follower equity and the
defaults (equity ratio, 5 bp slippage, 4.5 bp fee):

```sh
hl-copy-backtest -dir data -leaders 20 -meta meta.json -out backtest/
```

19 leaders had a fill in the 30-day lookback (73,054 changes); the run takes 2 s.

| Rank | Leader | Window (days) | Follower pnl | Return | Max drawdown | Fees | Turnover | Orders | Changes | Skipped | Leader marked return | Leader curve return | Leader curve max drawdown |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `0xdd53c5297309130ab5fe5623dc905752e3342b13` | 0.4 | 1228.84 | 12.29% | 1.06% | 16.37 | 36367.06 | 203 | 5715 | 96.45% | 11.54% | -5.73% | 5.73% |
| 2 | `0x5b5d51203a0f9079f8aeb098a6523a13f298c060` | 1.2 | 1051.85 | 10.52% | 1.25% | 25.00 | 55562.08 | 298 | 4739 | 93.71% | 10.99% | 23.57% | 0.00% |
| 3 | `0x237152b038d88f4156a0cd71090462de7e3f0883` | 21.2 | 527.63 | 5.28% | 1.01% | 60.41 | 134240.68 | 44 | 44 | 0.00% | 7.66% | 29.42% | 1.55% |
| 4 | `0xfc27136e42af1732ddc9ce2605ea9bff1b959d9d` | 0.1 | 72.33 | 0.72% | 2.11% | 13.33 | 29621.77 | 419 | 6624 | 93.66% | 1.01% | 0.00% | 0.00% |
| 5 | `0x77375a8c9d13bf79afb2a87f1b0ac1dfd5f5bf66` | 27.7 | 0.00 | 0.00% | 0.00% | 0.00 | 0.00 | 0 | 29 | 79.31% | 0.00% | 57.53% | 13.42% |
| 6 | `0xbdfa4f4492dd7b7cf211209c4791af8d52bf5c50` | 0.7 | -0.38 | -0.00% | 0.00% | 0.14 | 317.16 | 31 | 3262 | 99.05% | -0.00% | -8.59% | 8.59% |
| 7 | `0xeadc152ac1014ace57c6b353f89adf5faffe9d55` | 3.0 | -0.79 | -0.01% | 0.01% | 0.38 | 834.96 | 2 | 4 | 25.00% | -0.00% | 46.02% | 0.00% |
| 8 | `0xb83de012dba672c76a7dbbbf3e459cb59d7d6e36` | 0.1 | -3.87 | -0.04% | 0.15% | 0.57 | 1261.70 | 21 | 3932 | 99.47% | -0.03% | -0.33% | 0.33% |
| 9 | `0x3dc908374e11623d8eb9f07dfc7a2e5e803a54b0` | 0.3 | -22.93 | -0.23% | 1.76% | 7.12 | 15832.24 | 259 | 2984 | 91.32% | -0.07% | 0.00% | 0.00% |
| 10 | `0xecb63caa47c7c4e77f60f1ce858cf28dc2b82b00` | 0.1 | -43.53 | -0.44% | 0.47% | 6.23 | 13848.75 | 173 | 6507 | 97.34% | -0.30% | 0.00% | 0.00% |
| 11 | `0x936cf4fb95c30ce83f658b5bbb247e4bb381bb0f` | 0.1 | -92.14 | -0.92% | 1.03% | 6.32 | 14034.07 | 174 | 5124 | 96.60% | -0.78% | 0.36% | 0.00% |
| 12 | `0xb695651daa495f59dd2725c6fe98322d8b51a92d` | 3.7 | -128.53 | -1.29% | 7.83% | 31.98 | 71057.39 | 918 | 6108 | 84.95% | -0.53% | 1.01% | 12.20% |
| 13 | `0xf02d16a272a842f8bac1d9a9e773aba1933454c6` | 2.7 | -133.74 | -1.34% | 13.50% | 14.93 | 33167.68 | 211 | 830 | 74.58% | -0.39% | 1.08% | 0.00% |
| 14 | `0x45d26f28196d226497130c4bac709d808fed4029` | 27.1 | -378.56 | -3.79% | 4.41% | 8.72 | 19382.90 | 124 | 3157 | 96.07% | -3.53% | -13.43% | 48.42% |
| 15 | `0x30afce2f6842bf183c7e3fe7162e279ff0b6393e` | 0.2 | -519.15 | -5.19% | 6.38% | 14.61 | 32459.57 | 584 | 2722 | 78.55% | -4.90% | -1.03% | 1.03% |
| 16 | `0x7fdafde5cfb5465924316eced2d3715494c517d1` | 0.2 | -1045.83 | -10.46% | 11.67% | 24.55 | 54544.50 | 549 | 7594 | 92.77% | -10.40% | 0.00% | 0.00% |
| 17 | `0xfe7ce058edc7cfcde9ef8262ba51f8d4796ab7ae` | 0.7 | -1329.76 | -13.30% | 56.59% | 222.14 | 493652.93 | 673 | 5836 | 88.47% | -5.21% | -193.36% | 193.36% |
| 18 | `0x8def9f50456c6c4e37fa5d3d57f108ed23992dae` | 4.4 | -1961.80 | -19.62% | 24.68% | 15.37 | 34155.57 | 1033 | 4291 | 75.93% | -18.24% | -15.93% | 21.76% |
| 19 | `0x880ac484a1743862989a441d6d867238c7aa311c` | 9.3 | -2840.34 | -28.40% | 58.05% | 37.16 | 82568.49 | 955 | 3552 | 73.09% | -22.45% | 32.25% | 34.69% |

- Leaders hold 1.7 to 157 million USD of equity at the start of their window, so at
  10,000 USD most of their changes scale
  below the 10 USD minimum order or one lot: the median skip rate is 91%
  (`below_min_notional` 53,287 changes, `below_lot` 8,086). At 100,000 USD it is 68%,
  and the pnl column scales by ten (sum over the 19: -5,621 USD at 10k, -56,383 at 100k).
- Where little is skipped, the follower tracks the leader's marked return minus costs
  (rank 3: 5.28% against 7.66%, 60 USD of fees on 134k of turnover in 44 orders). With
  most changes skipped, the follower still holds the scaled image of the leader's
  position once it grows past the minimum, so the two returns stay close.
- Window is from the first to the last fill: 10,000 fills are an hour or two for the
  busiest accounts. The leader curve is the `portfolio` month window, sampled every few
  hours, so it reads 0 over windows shorter than its spacing. Rank 17's curve (the
  window's first account value plus cumulative pnl) falls below zero; the mirror skips
  its changes as `no_leader_equity` while it is not positive.
- With caps (`max_leverage 3`, `max_notional_per_symbol 5000`, `max_daily_loss 500`) the
  sum over the 19 is -2,495 USD and 5 end positive; the daily loss cap flattens the
  follower on 6,037 changes.

## Build

```
dune build
dune test
dune exec bench/main.exe -- -quota 2
dune exec hl-copy-backtest -- -help
```
