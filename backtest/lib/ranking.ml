open! Core
module Result = Backtest.Result

let compare (a : Result.t) (b : Result.t) =
  let copyable (r : Result.t) = r.leader_changes > 0 in
  match Bool.compare (copyable b) (copyable a) with
  | 0 ->
    (match Hl_copy_core.Usd.compare b.pnl a.pnl with
     | 0 ->
       (match Float.compare a.max_drawdown b.max_drawdown with
        | 0 -> Hl_copy_core.Address.compare a.leader b.leader
        | c -> c)
     | c -> c)
  | c -> c
;;

let run params inputs = List.map inputs ~f:(Backtest.run params) |> List.sort ~compare
