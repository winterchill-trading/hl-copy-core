open! Core
module Symbol = Market_data.Symbol
module Size = Market_data.Size

module Equity_point = struct
  type t =
    { time_ns : int
    ; equity : Usd.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable = struct
  module V1 = struct
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

include Stable.V1

let full_activity_trades = 20
let net (f : Fill.t) = Usd.(f.closed_pnl - f.fee)

let max_drawdown points =
  let points = List.sort points ~compare:Equity_point.compare in
  let _, worst =
    List.fold points ~init:(None, 0.) ~f:(fun (peak, worst) (p : Equity_point.t) ->
      let peak =
        match peak with
        | Some pk when Usd.(pk >= p.equity) -> pk
        | _ -> p.equity
      in
      let worst =
        if Usd.is_positive peak
        then (
          let dd = Usd.(to_float (peak - p.equity)) /. Usd.to_float peak in
          Float.max worst (Float.min dd 1.))
        else worst
      in
      Some peak, worst)
  in
  worst
;;

module Trip = struct
  type t =
    { symbol : Symbol.t
    ; opened_ns : int
    ; closed_ns : int
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

module Open_trip = struct
  type t =
    { size : Size.t
    ; opened_ns : int
    ; pnl : Usd.t
    }
end

let same_side a b =
  (Size.is_positive a && Size.is_positive b) || (Size.is_negative a && Size.is_negative b)
;;

let round_trips fills =
  let fills = List.sort fills ~compare:Fill.compare in
  let _, closed =
    List.fold
      fills
      ~init:(Map.empty (module Symbol), [])
      ~f:(fun (open_, closed) (f : Fill.t) ->
        let q = Fill.signed_size f in
        let cur =
          Option.value
            (Map.find open_ f.symbol)
            ~default:{ Open_trip.size = Size.zero; opened_ns = f.time_ns; pnl = Usd.zero }
        in
        let cur =
          if Size.is_zero cur.size then { cur with opened_ns = f.time_ns } else cur
        in
        let size = Size.(cur.size + q) in
        let pnl = Usd.(cur.pnl + net f) in
        if Size.is_zero cur.size || same_side size cur.size
        then Map.set open_ ~key:f.symbol ~data:{ cur with size; pnl }, closed
        else (
          let trip =
            { Trip.symbol = f.symbol
            ; opened_ns = cur.opened_ns
            ; closed_ns = f.time_ns
            ; pnl
            }
          in
          let open_ =
            if Size.is_zero size
            then Map.remove open_ f.symbol
            else
              Map.set
                open_
                ~key:f.symbol
                ~data:{ Open_trip.size; opened_ns = f.time_ns; pnl = Usd.zero }
          in
          open_, trip :: closed))
  in
  List.rev closed
;;

let consistency ~windows ~fills ~equity =
  let times =
    match equity with
    | [] -> List.map fills ~f:(fun (f : Fill.t) -> f.time_ns)
    | _ -> List.map equity ~f:(fun (p : Equity_point.t) -> p.time_ns)
  in
  match
    List.min_elt times ~compare:Int.compare, List.max_elt times ~compare:Int.compare
  with
  | Some t0, Some t1 when t1 > t0 && windows > 0 ->
    let span = t1 - t0 in
    let buckets = Array.create ~len:windows Usd.zero in
    List.iter fills ~f:(fun (f : Fill.t) ->
      if f.time_ns >= t0 && f.time_ns <= t1
      then (
        (* [span] and the offset fit in 63 bits for any real timestamp; the product would
           not, hence the float. *)
        let i =
          Float.iround_down_exn
            (Float.of_int (f.time_ns - t0) /. Float.of_int span *. Float.of_int windows)
        in
        let i = Int.min i (windows - 1) in
        buckets.(i) <- Usd.(buckets.(i) + net f)));
    let positive = Array.count buckets ~f:Usd.is_positive in
    Float.of_int positive /. Float.of_int windows
  | _ -> 0.
;;

let compute ?(windows = 4) ~fills ~equity () =
  let fills = List.sort fills ~compare:Fill.compare in
  let equity = List.sort equity ~compare:Equity_point.compare in
  let pnl = List.fold fills ~init:Usd.zero ~f:(fun acc f -> Usd.(acc + net f)) in
  let return_ =
    match equity with
    | p :: _ when Usd.is_positive p.equity -> Usd.to_float pnl /. Usd.to_float p.equity
    | _ -> 0.
  in
  let max_drawdown = max_drawdown equity in
  let trips = round_trips fills in
  let trade_count = List.length trips in
  let wins = List.count trips ~f:(fun t -> Usd.is_positive t.pnl) in
  let win_rate =
    if trade_count = 0 then 0. else Float.of_int wins /. Float.of_int trade_count
  in
  let avg_hold_ns =
    if trade_count = 0
    then 0
    else List.sum (module Int) trips ~f:(fun t -> t.closed_ns - t.opened_ns) / trade_count
  in
  let consistency = consistency ~windows ~fills ~equity in
  let activity =
    Float.min 1. (Float.of_int trade_count /. Float.of_int full_activity_trades)
  in
  let score =
    return_ *. (1. -. max_drawdown) *. (0.5 +. (0.5 *. consistency)) *. activity
  in
  { pnl; return_; max_drawdown; win_rate; trade_count; avg_hold_ns; consistency; score }
;;
