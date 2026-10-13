(** A leader's fill history as a sequence of position changes.

    Hyperliquid reports one fill per maker an order trades against, all with the same
    time, coin and side. The copy engine sees the position after the order, not each
    fill, so consecutive fills of one coin with the same millisecond and side are one
    change. Positions are tracked from zero: the history must start flat in every coin
    (hl-leaderboard's [Rank.scored_fills] inserts a synthetic opening fill where it does
    not). *)

open! Core

type t =
  { time_ms : int
  ; symbol : Market_data.Symbol.t
  ; size : Market_data.Size.t (** the leader's signed position after the change *)
  ; price : Market_data.Price.t (** volume-weighted price of the grouped fills *)
  ; traded : Market_data.Size.t (** signed size of the grouped fills *)
  ; fills : int
  }
[@@deriving sexp, compare, equal]

(** Fills oldest first; the result is oldest first. *)
val of_fills : Hl_copy_core.Fill.t list -> t list
