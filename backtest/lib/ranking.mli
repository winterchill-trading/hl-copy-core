(** Every leader of a collection ranked by what one follower configuration would have
    earned copying them: the "follower outcome" ranking, next to hl-leaderboard's score
    of the leaders' own trading. *)

open! Core

(** Best first: higher follower pnl, then lower follower drawdown, then the lower
    address. Leaders with no perpetual position change (nothing to copy) come last. *)
val compare : Backtest.Result.t -> Backtest.Result.t -> int

(** Runs {!Backtest.run} for every input and sorts with {!compare}. *)
val run : Backtest.Params.t -> Input.t list -> Backtest.Result.t list
