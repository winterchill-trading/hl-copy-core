(** Leader scoring from a fill history and an equity curve. Deterministic: the inputs are
    sorted first, so the same fills in any order give the same score.

    With fills sorted by time (ties broken by the whole record):

    - [pnl] = sum of [closed_pnl - fee] over all fills.
    - [return_] = [pnl / E_0], with [E_0] the first equity point (0 if [E_0 <= 0] or no
      curve).
    - [max_drawdown] = max over the curve of [(peak - equity) / peak], with [peak] the
      running maximum; clamped to [[0, 1]], 0 while the peak is not positive.
    - Round trips: per symbol, a trip opens when the position leaves zero and closes when
      it returns to zero or flips (a flip closes one trip and opens the next at the same
      time). A trip's pnl is the sum of [closed_pnl - fee] of its fills.
    - [trade_count] = closed round trips; [win_rate] = trips with pnl > 0 over
      [trade_count] (0 with no trips); [avg_hold_ns] = mean trip duration.
    - [consistency]: the span from the first to the last timestamp (equity points, or
      fills without a curve) is cut into [windows] equal windows (default 4); it is the
      share of windows whose fills sum to a positive [closed_pnl - fee]. 0 for an empty
      span.
    - [score] =
      [return_ * (1 - max_drawdown) * (0.5 + 0.5 * consistency) * min(1, trade_count / 20)]. *)

open! Core

module Equity_point : sig
  type t =
    { time_ns : int
    ; equity : Usd.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable : sig
  module V1 : sig
    type t =
      { pnl : Usd.Stable.V1.t
      ; return_ : float
      ; max_drawdown : float
      ; win_rate : float
      ; trade_count : int
      ; avg_hold_ns : int
      ; consistency : float
      ; score : float
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { pnl : Usd.t
  ; return_ : float
  ; max_drawdown : float
  ; win_rate : float
  ; trade_count : int
  ; avg_hold_ns : int
  ; consistency : float
  ; score : float
  }
[@@deriving bin_io, sexp, compare, equal]

(** Trips needed for full weight in [score]. *)
val full_activity_trades : int

val compute : ?windows:int -> fills:Fill.t list -> equity:Equity_point.t list -> unit -> t

(** The parts, exposed for tests and for the leaderboard's own columns. *)

val max_drawdown : Equity_point.t list -> float

module Trip : sig
  type t =
    { symbol : Market_data.Symbol.t
    ; opened_ns : int
    ; closed_ns : int
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

(** Closed round trips, in closing order. *)
val round_trips : Fill.t list -> Trip.t list
