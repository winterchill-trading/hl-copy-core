(** Reads the backtest inputs from an hl-leaderboard collection directory (see
    [Hl_leaderboard.Layout]): each leader's raw fill pages, latest account state and
    latest [portfolio], decoded by [Hl_leaderboard.Dataset]. *)

open! Core
open! Async

(** The time a leader's rebuilt equity curve ends at (only used without a [portfolio]):
    its latest account state, else its last fill, else 0. *)
val now_ms : Hl_leaderboard.Dataset.Leader.t -> int

(** Every candidate of the collection with at least one fill, in collection order. *)
val load_all : string -> Input.t list Or_error.t Deferred.t

(** One leader (any address with a fills log). *)
val load_one : string -> Hl_copy_core.Address.t -> Input.t Or_error.t Deferred.t

(** Specs for every coin in [inputs]: [meta]'s, else inferred from all their fills. *)
val specs : ?meta:Hl_protocol.Meta.t -> Input.t list -> Specs.t
