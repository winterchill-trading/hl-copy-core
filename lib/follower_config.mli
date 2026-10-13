(** One follow: a follower account copying one leader. The API writes these as sexp files
    in a directory the engine watches; the engine builds a {!Mirror.Config.t} from each.

    {v
((follower 0x...) (leader 0x...) (mode Equity_ratio)
 (caps ((max_leverage (5)) (max_notional_per_symbol ()) (max_daily_loss (200))
        (allowlist ((BTC ETH))) (min_order_notional 10)))
 (slippage_bps 20) (paused false))
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
end

type t = Stable.V1.t =
  { follower : Address.t (** the user's account, traded through its agent key *)
  ; leader : Address.t
  ; mode : Scale.Mode.t
  ; caps : Caps.t
  ; slippage_bps : int (** IOC limit distance from the reference price *)
  ; paused : bool (** the engine sends nothing for a paused follow; positions are kept *)
  }
[@@deriving bin_io, sexp, compare, equal]

(** 20 basis points. *)
val default_slippage_bps : int

val create
  :  ?mode:Scale.Mode.t
  -> ?caps:Caps.t
  -> ?slippage_bps:int
  -> follower:Address.t
  -> leader:Address.t
  -> unit
  -> t

(** Rejects negative or above-1000 slippage, a non-finite or negative leverage or
    multiplier, negative caps, and a follower equal to the leader. *)
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
