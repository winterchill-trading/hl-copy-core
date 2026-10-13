open! Core
open Hl_copy_core
open Hl_copy_backtest
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Price = Market_data.Price

let leader = Address.of_string "0x00000000000000000000000000000000000000aa"
let follower = Address.of_string "0x00000000000000000000000000000000000000bb"
let btc = Symbol.of_string "BTC"
let eth = Symbol.of_string "ETH"
let hour_ms = 3_600_000

let fill ?(closed_pnl = "0") ?(fee = "0") ~time_ms symbol size price =
  let size = Size.of_string size in
  { Fill.time_ns = time_ms * 1_000_000
  ; symbol
  ; side = (if Size.is_negative size then Sell else Buy)
  ; size = Size.abs size
  ; price = Price.of_string price
  ; fee = Usd.of_string fee
  ; closed_pnl = Usd.of_string closed_pnl
  ; cloid = None
  }
;;

let input ?(equity = 100_000.) fills =
  { Input.leader
  ; fills
  ; curve = [ { Hl_leaderboard.Equity_curve.Point.time_ms = 0; equity } ]
  ; curve_source = `Portfolio_month
  }
;;

let specs =
  Map.of_alist_exn
    (module Symbol)
    [ btc, Rounding.Spec.hyperliquid_perp ~sz_decimals:5
    ; eth, Rounding.Spec.hyperliquid_perp ~sz_decimals:4
    ]
;;

let params
  ?(caps = Caps.none)
  ?(mode = Scale.Mode.Equity_ratio)
  ?(slippage_bps = 0.)
  ?(fee_bps = 0.)
  ?(start_equity = "10000")
  ()
  =
  { Backtest.Params.follow = Follower_config.create ~mode ~caps ~follower ~leader ()
  ; start_equity = Usd.of_string start_equity
  ; slippage_bps
  ; fee_bps
  ; specs
  }
;;

let print_summary (r : Backtest.Result.t) =
  let r =
    { r with
      curve = ([] : Backtest.Point.t list)
    ; return_ = Float.round_decimal r.return_ ~decimal_digits:6
    ; max_drawdown = Float.round_decimal r.max_drawdown ~decimal_digits:6
    ; skip_rate = Float.round_decimal r.skip_rate ~decimal_digits:6
    ; leader_return = Float.round_decimal r.leader_return ~decimal_digits:6
    ; leader_max_drawdown = Float.round_decimal r.leader_max_drawdown ~decimal_digits:6
    }
  in
  print_s [%sexp (r : Backtest.Result.t)]
;;
