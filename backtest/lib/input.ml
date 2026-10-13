open! Core
module Rank = Hl_leaderboard.Rank
module Equity_curve = Hl_leaderboard.Equity_curve

type t =
  { leader : Hl_copy_core.Address.t
  ; fills : Hl_copy_core.Fill.t list
  ; curve : Equity_curve.t
  ; curve_source : [ `Portfolio_month | `Fills ]
  }
[@@deriving sexp_of]

let of_leader ~now_ms (leader : Hl_leaderboard.Dataset.Leader.t) =
  let curve, curve_source = Rank.equity_curve ~now_ms leader in
  { leader = leader.address
  ; fills = List.map (Rank.scored_fills leader.fills) ~f:Rank.to_copy_fill
  ; curve
  ; curve_source
  }
;;

let equity_at t =
  let points = Array.of_list t.curve in
  Array.sort points ~compare:(fun (a : Equity_curve.Point.t) b ->
    Int.compare a.time_ms b.time_ms);
  fun ~time_ms ->
    if Array.is_empty points
    then None
    else (
      match
        Array.binary_search
          points
          ~compare:(fun (p : Equity_curve.Point.t) time -> Int.compare p.time_ms time)
          `Last_less_than_or_equal_to
          time_ms
      with
      | Some i -> Some points.(i).equity
      | None -> Some points.(0).equity)
;;
