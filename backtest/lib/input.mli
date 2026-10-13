(** What the backtest replays for one leader, read from an hl-leaderboard collection. *)

open! Core

type t =
  { leader : Hl_copy_core.Address.t
  ; fills : Hl_copy_core.Fill.t list
  (** perpetual fills, oldest first, starting flat in every coin *)
  ; curve : Hl_leaderboard.Equity_curve.t (** the leader's equity, oldest first *)
  ; curve_source : [ `Portfolio_month | `Fills ]
  }
[@@deriving sexp_of]

(** The same inputs [hl-leaderboard rank] scores: perpetual fills with a synthetic opening
    fill for each coin already held when the history starts ([Rank.scored_fills]), and
    the [portfolio] month curve, or the curve rebuilt from fills when there is none
    ([Rank.equity_curve]). [now_ms] is the time of the latest account state, used only by
    the rebuilt curve. *)
val of_leader : now_ms:int -> Hl_leaderboard.Dataset.Leader.t -> t

(** [equity_at t] is the leader's equity lookup: at [time_ms], the latest curve point at
    or before it, or the first point for earlier times; [None] for an empty curve. Build
    it once per replay (it sorts the curve into an array). *)
val equity_at : t -> time_ms:int -> float option
