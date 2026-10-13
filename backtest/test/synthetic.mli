(** Helpers building synthetic leader histories with known answers. *)

open! Core

val leader : Hl_copy_core.Address.t
val follower : Hl_copy_core.Address.t
val btc : Market_data.Symbol.t
val eth : Market_data.Symbol.t
val hour_ms : int

(** A leader fill at [time_ms]; [size] signed (positive buys). *)
val fill
  :  ?closed_pnl:string
  -> ?fee:string
  -> time_ms:int
  -> Market_data.Symbol.t
  -> string
  -> string
  -> Hl_copy_core.Fill.t

(** A leader whose equity is [equity] for the whole history. *)
val input : ?equity:float -> Hl_copy_core.Fill.t list -> Hl_copy_backtest.Input.t

(** BTC (5 size decimals) and ETH (4). *)
val specs : Hl_copy_backtest.Specs.t

val params
  :  ?caps:Hl_copy_core.Caps.t
  -> ?mode:Hl_copy_core.Scale.Mode.t
  -> ?slippage_bps:float
  -> ?fee_bps:float
  -> ?start_equity:string
  -> unit
  -> Hl_copy_backtest.Backtest.Params.t

(** The result without its curve and positions, as a sexp. *)
val print_summary : Hl_copy_backtest.Backtest.Result.t -> unit
