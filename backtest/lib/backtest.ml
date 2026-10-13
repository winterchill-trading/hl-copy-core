open! Core
open Hl_copy_core
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Price = Market_data.Price
module Side = Market_data.Side

module Params = struct
  type t =
    { follow : Follower_config.t
    ; start_equity : Usd.t
    ; slippage_bps : float
    ; fee_bps : float
    ; specs : Rounding.Spec.t Mirror.Symbol_map.t
    }
  [@@deriving sexp_of]

  (* Hyperliquid's tier-0 perpetual taker fee is 0.045% of notional. *)
  let default_fee_bps = 4.5
  let default_slippage_bps = 5.
end

module Point = struct
  type t =
    { time_ms : int
    ; equity : float
    ; leader_equity : float
    }
  [@@deriving sexp, compare, equal]
end

module Result = struct
  type t =
    { leader : Address.t
    ; start_ms : int
    ; end_ms : int
    ; start_equity : Usd.t
    ; end_equity : Usd.t
    ; pnl : Usd.t
    ; return_ : float
    ; max_drawdown : float
    ; realized : Usd.t
    ; unrealized : Usd.t
    ; fees : Usd.t
    ; turnover : Usd.t
    ; orders : int
    ; unfilled_orders : int
    ; leader_changes : int
    ; changes_traded : int
    ; changes_capped : int
    ; changes_skipped : int
    ; skip_rate : float
    ; reasons : (string * int) list
    ; leader_return : float
    ; leader_max_drawdown : float
    ; leader_fill_pnl : Usd.t
    ; positions : (Symbol.t * Size.t) list
    ; curve : Point.t list
    }
  [@@deriving sexp_of]
end

let reason_name : Plan.Note.Reason.t -> string = function
  | Capped Not_allowlisted -> "not_allowlisted"
  | Capped (Daily_loss_reached _) -> "daily_loss"
  | Capped (Symbol_notional _) -> "symbol_notional"
  | Capped (Leverage _) -> "leverage"
  | Capped Below_lot -> "below_lot"
  | Capped (Below_min_notional _) -> "below_min_notional"
  | No_mark -> "no_mark"
  | No_spec -> "no_spec"
  | No_leader_equity -> "no_leader_equity"
;;

let max_drawdown values =
  let _, dd =
    List.fold values ~init:(Float.neg_infinity, 0.) ~f:(fun (peak, dd) v ->
      let peak = Float.max peak v in
      let dd = if Float.(peak > 0.) then Float.max dd ((peak -. v) /. peak) else dd in
      peak, dd)
  in
  dd
;;

let day_of_ms ms = ms / 86_400_000

(* The follower's books, one average-entry position per coin. *)
type books =
  { positions : Pnl.Position.t Map.M(Symbol).t
  ; marks : Price.t Map.M(Symbol).t
  }

let book_totals ~start_equity books =
  Map.fold
    books.positions
    ~init:(Usd.zero, Usd.zero, Usd.zero)
    ~f:(fun ~key ~data:(p : Pnl.Position.t) (realized, unrealized, fees) ->
      let u =
        match Map.find books.marks key with
        | Some mark when not (Size.is_zero p.size) -> Pnl.Position.unrealized p ~mark
        | _ -> Usd.zero
      in
      Usd.(realized + p.realized), Usd.(unrealized + u), Usd.(fees + p.fees))
  |> fun (realized, unrealized, fees) ->
  Usd.(start_equity + realized + unrealized - fees), realized, unrealized, fees
;;

let equity ~start_equity books =
  let e, _, _, _ = book_totals ~start_equity books in
  e
;;

let slipped price ~(side : Side.t) ~bps =
  let factor =
    match side with
    | Buy -> 1. +. (bps /. 10_000.)
    | Sell -> 1. -. (bps /. 10_000.)
  in
  (* A simulated price, not a wire value: rounding the float to 10^-8 is fine. *)
  (Price.of_float [@alert "-lossy"]) (Price.to_float price *. factor)
;;

let inside_limit (o : Plan.Order.t) price =
  match o.side with
  | Buy -> Price.(price <= o.limit_px)
  | Sell -> Price.(price >= o.limit_px)
;;

type counters =
  { mutable orders : int
  ; mutable unfilled : int
  ; mutable traded : int
  ; mutable capped : int
  ; mutable skipped : int
  ; mutable turnover : Usd.t
  ; reasons : (string, int) Hashtbl.t
  }

let run (params : Params.t) (input : Input.t) =
  let follow = { params.follow with leader = input.leader } in
  let config = Follower_config.mirror_config follow ~specs:params.specs in
  let leader_equity_at = Input.equity_at input in
  let changes = Leader_change.of_fills input.fills in
  let start_equity = params.start_equity in
  let c =
    { orders = 0
    ; unfilled = 0
    ; traded = 0
    ; capped = 0
    ; skipped = 0
    ; turnover = Usd.zero
    ; reasons = Hashtbl.create (module String)
    }
  in
  let mirror =
    Mirror.on_follower_equity (Mirror.create config) start_equity |> Mirror.start_day
  in
  let books =
    { positions = Map.empty (module Symbol); marks = Map.empty (module Symbol) }
  in
  let execute (mirror, books) (change : Leader_change.t) (action : Plan.Action.t) =
    match action with
    | Cancel { cloid; _ } -> Mirror.on_order_closed mirror cloid, books
    | Place o ->
      c.orders <- c.orders + 1;
      let price = slipped change.price ~side:o.side ~bps:params.slippage_bps in
      if not (inside_limit o price)
      then (
        c.unfilled <- c.unfilled + 1;
        Mirror.on_order_closed mirror o.cloid, books)
      else (
        let notional = Caps.notional o.size price in
        let fee = (Usd.of_float [@alert "-lossy"]) (Usd.to_float notional *. params.fee_bps /. 10_000.) in
        c.turnover <- Usd.(c.turnover + notional);
        let before =
          Option.value (Map.find books.positions o.symbol) ~default:Pnl.Position.flat
        in
        let fill =
          { Fill.time_ns = change.time_ms * 1_000_000
          ; symbol = o.symbol
          ; side = o.side
          ; size = o.size
          ; price
          ; fee
          ; closed_pnl = Usd.zero
          ; cloid = Some o.cloid
          }
        in
        let after = Pnl.Position.apply_fill before fill in
        let fill = { fill with closed_pnl = Usd.(after.realized - before.realized) } in
        let mirror = Mirror.on_follower_fill mirror fill in
        let mirror = Mirror.on_order_closed mirror o.cloid in
        mirror, { books with positions = Map.set books.positions ~key:o.symbol ~data:after })
  in
  let step (mirror, books, day, curve) (change : Leader_change.t) =
    let mirror, day =
      let d = day_of_ms change.time_ms in
      if d <> day then Mirror.start_day mirror, d else mirror, day
    in
    let books =
      { books with marks = Map.set books.marks ~key:change.symbol ~data:change.price }
    in
    let leader_equity = leader_equity_at ~time_ms:change.time_ms in
    let mirror =
      Mirror.on_follower_equity mirror (equity ~start_equity books)
      |> Fn.flip
           Mirror.on_leader_equity
           (Option.value_map leader_equity ~default:Usd.zero ~f:(Usd.of_float [@alert "-lossy"]))
    in
    let mirror, plan =
      Mirror.on_leader_position_change
        mirror
        ~symbol:change.symbol
        ~size:change.size
        ~mark:change.price
    in
    let placed = not (List.is_empty (Plan.places plan)) in
    let has_cap =
      List.exists plan.notes ~f:(fun n ->
        match n.reason with
        | Capped _ -> true
        | No_mark | No_spec | No_leader_equity -> false)
    in
    if placed
    then (
      c.traded <- c.traded + 1;
      if has_cap then c.capped <- c.capped + 1)
    else if not (List.is_empty plan.notes)
    then c.skipped <- c.skipped + 1;
    List.map plan.notes ~f:(fun n -> reason_name n.reason)
    |> List.dedup_and_sort ~compare:String.compare
    |> List.iter ~f:(fun name -> Hashtbl.incr c.reasons name);
    let mirror, books =
      List.fold plan.actions ~init:(mirror, books) ~f:(fun acc a -> execute acc change a)
    in
    let point =
      { Point.time_ms = change.time_ms
      ; equity = Usd.to_float (equity ~start_equity books)
      ; leader_equity = Option.value leader_equity ~default:0.
      }
    in
    mirror, books, day, point :: curve
  in
  let first_day =
    match changes with
    | [] -> 0
    | c :: _ -> day_of_ms c.time_ms
  in
  let _mirror, books, _day, curve =
    List.fold changes ~init:(mirror, books, first_day, []) ~f:step
  in
  let curve = List.rev curve in
  let end_equity, realized, unrealized, fees = book_totals ~start_equity books in
  let start_ms, end_ms =
    match changes, List.last changes with
    | first :: _, Some last -> first.time_ms, last.time_ms
    | _ -> 0, 0
  in
  let leader_values =
    let inside =
      List.filter_map input.curve ~f:(fun (p : Hl_leaderboard.Equity_curve.Point.t) ->
        if p.time_ms > start_ms && p.time_ms < end_ms then Some p.equity else None)
    in
    let at time_ms = Option.to_list (leader_equity_at ~time_ms) in
    if List.is_empty changes then [] else at start_ms @ inside @ at end_ms
  in
  let leader_return =
    match leader_values, List.last leader_values with
    | first :: _, Some last when Float.(first > 0.) -> (last /. first) -. 1.
    | _ -> 0.
  in
  let pnl = Usd.(end_equity - start_equity) in
  let leader_changes = List.length changes in
  { Result.leader = input.leader
  ; start_ms
  ; end_ms
  ; start_equity
  ; end_equity
  ; pnl
  ; return_ =
      (if Usd.is_positive start_equity
       then Usd.to_float pnl /. Usd.to_float start_equity
       else 0.)
  ; max_drawdown =
      max_drawdown
        (Usd.to_float start_equity :: List.map curve ~f:(fun (p : Point.t) -> p.equity))
  ; realized
  ; unrealized
  ; fees
  ; turnover = c.turnover
  ; orders = c.orders
  ; unfilled_orders = c.unfilled
  ; leader_changes
  ; changes_traded = c.traded
  ; changes_capped = c.capped
  ; changes_skipped = c.skipped
  ; skip_rate =
      (if leader_changes = 0
       then 0.
       else Float.of_int c.skipped /. Float.of_int leader_changes)
  ; reasons =
      Hashtbl.to_alist c.reasons |> List.sort ~compare:[%compare: string * int]
  ; leader_return
  ; leader_max_drawdown = max_drawdown leader_values
  ; leader_fill_pnl =
      Usd.sum
        (List.map input.fills ~f:(fun (f : Fill.t) -> Usd.(f.closed_pnl - f.fee)))
  ; positions =
      Map.to_alist books.positions
      |> List.filter_map ~f:(fun (s, (p : Pnl.Position.t)) ->
        if Size.is_zero p.size then None else Some (s, p.size))
  ; curve
  }
;;
