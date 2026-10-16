(** One follow: a follower account copying one leader. The API writes these as sexp files
    in a directory the engine watches; the engine builds a {!Mirror.Config.t} from each.

    {v
((follower 0x...) (leader 0x...) (mode Equity_ratio)
 (caps ((max_leverage (5)) (max_notional_per_symbol ()) (max_daily_loss (200))
        (allowlist ((BTC ETH))) (min_order_notional 10)))
 (slippage_bps 20) (paused false) (algo (Twap (duration_ms 60000) (slices 6)
 (max_participation ()))))
    v}

    [algo] ({!Exec_algo}) is optional in the file and left out when it is [Immediate], so
    files written before it existed read unchanged and a default follow writes the same
    text as before. [band] ({!No_trade_band}, [Stable.V3]) is optional the same way: a
    follow without one has no [band] field, and with one it reads

    {v
 (band ((fee_bps 4.5) (slippage (Fixed_bps 5)) (risk_aversion 20) (vol_bps 300)
        (cost_model Proportional)))
    v} *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { follower : Address.Stable.V1.t
      ; leader : Address.Stable.V1.t
      ; mode : Scale.Mode.Stable.V1.t
      ; caps : Caps.Stable.V1.t
      ; slippage_bps : int
      ; paused : bool
      }
    [@@deriving bin_io, sexp, compare, equal]
  end

  (** [V1] plus the execution algorithm. *)
  module V2 : sig
    type t =
      { follower : Address.Stable.V1.t
      ; leader : Address.Stable.V1.t
      ; mode : Scale.Mode.Stable.V1.t
      ; caps : Caps.Stable.V1.t
      ; slippage_bps : int
      ; paused : bool
      ; algo : Exec_algo.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]

    (** [algo = Immediate]. *)
    val of_v1 : V1.t -> t

    (** Drops [algo]. *)
    val to_v1 : t -> V1.t
  end

  (** [V2] plus the no-trade band. *)
  module V3 : sig
    type t =
      { follower : Address.Stable.V1.t
      ; leader : Address.Stable.V1.t
      ; mode : Scale.Mode.Stable.V1.t
      ; caps : Caps.Stable.V1.t
      ; slippage_bps : int
      ; paused : bool
      ; algo : Exec_algo.Stable.V1.t
      ; band : No_trade_band.Stable.V1.t option
      }
    [@@deriving bin_io, sexp, compare, equal]

    (** [band = None]. *)
    val of_v2 : V2.t -> t

    (** Drops [band]. *)
    val to_v2 : t -> V2.t

    val of_v1 : V1.t -> t
    val to_v1 : t -> V1.t
  end
end

type t = Stable.V3.t =
  { follower : Address.t (** the user's account, traded through its agent key *)
  ; leader : Address.t
  ; mode : Scale.Mode.t
  ; caps : Caps.t
  ; slippage_bps : int (** IOC limit distance from the reference price *)
  ; paused : bool (** the engine sends nothing for a paused follow; positions are kept *)
  ; algo : Exec_algo.t (** how planned orders are executed; [Immediate] by default *)
  ; band : No_trade_band.t option
  (** rebalance only outside a no-trade band; [None] (the default) trades every gap *)
  }
[@@deriving bin_io, sexp, compare, equal]

(** 20 basis points. *)
val default_slippage_bps : int

val create
  :  ?mode:Scale.Mode.t
  -> ?caps:Caps.t
  -> ?slippage_bps:int
  -> ?algo:Exec_algo.t
  -> ?band:No_trade_band.t
  -> follower:Address.t
  -> leader:Address.t
  -> unit
  -> t

(** Rejects negative or above-1000 slippage, a non-finite or negative leverage or
    multiplier, negative caps, an invalid algo ({!Exec_algo.validate}) or band
    ({!No_trade_band.validate}), and a follower equal to the leader. *)
val validate : t -> unit Or_error.t

(** File name for the follow, ["<follower>-<leader>.sexp"]. *)
val file_name : t -> string

val to_file_contents : t -> string

(** Parses and {!validate}s. *)
val of_file_contents : string -> t Or_error.t

(** The high half of this follow's client order ids: the first 15 hex digits (60 bits) of
    the leader's address, so two follows of one account never share an id and the value is
    the same in every process. *)
val cloid_prefix : t -> int

val mirror_config : t -> specs:Rounding.Spec.t Mirror.Symbol_map.t -> Mirror.Config.t
