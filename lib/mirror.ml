open! Core
module Symbol = Market_data.Symbol
module Side = Market_data.Side
module Size = Market_data.Size
module Price = Market_data.Price

module Symbol_map = struct
  type 'a t = 'a Map.M(Symbol).t [@@deriving bin_io, sexp, compare, equal]
end

module Pending = struct
  module Stable = struct
    module V1 = struct
      type t =
        { cloid : Cloid.Stable.V1.t
        ; symbol : Symbol.Stable.V1.t
        ; remaining : Size.Stable.V1.t
        ; cancel_requested : bool
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Config = struct
  module Stable = struct
    module V1 = struct
      type t =
        { follower : int
        ; mode : Scale.Mode.Stable.V1.t
        ; caps : Caps.Stable.V1.t
        ; slippage_bps : int
        ; specs : Rounding.Spec.Stable.V1.t Symbol_map.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
      type t =
        { follower : int
        ; mode : Scale.Mode.Stable.V1.t
        ; caps : Caps.Stable.V1.t
        ; slippage_bps : int
        ; specs : Rounding.Spec.Stable.V1.t Symbol_map.t
        ; band : No_trade_band.Stable.V1.t option [@sexp.option]
        }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v1 ({ follower; mode; caps; slippage_bps; specs } : V1.t) =
        { follower; mode; caps; slippage_bps; specs; band = None }
      ;;

      let to_v1 { follower; mode; caps; slippage_bps; specs; band = _ } : V1.t =
        { follower; mode; caps; slippage_bps; specs }
      ;;
    end
  end

  include Stable.V2
end

module Leader_state = struct
  type t =
    { equity : Usd.t
    ; positions : Size.t Symbol_map.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Follower_state = struct
  type t =
    { equity : Usd.t
    ; positions : Size.t Symbol_map.t
    ; open_orders : Pending.t list
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable = struct
  module V1 = struct
    type t =
      { config : Config.Stable.V1.t
      ; leader_equity : Usd.Stable.V1.t
      ; leader_positions : Size.Stable.V1.t Symbol_map.t
      ; follower_equity : Usd.Stable.V1.t
      ; day_start_equity : Usd.Stable.V1.t
      ; follower_positions : Size.Stable.V1.t Symbol_map.t
      ; pending : Pending.Stable.V1.t list
      ; marks : Price.Stable.V1.t Symbol_map.t
      ; managed : Set.M(Symbol).t
      ; next_seq : int
      }
    [@@deriving bin_io, sexp, compare, equal]
  end

  module V2 = struct
    type t =
      { config : Config.Stable.V2.t
      ; leader_equity : Usd.Stable.V1.t
      ; leader_positions : Size.Stable.V1.t Symbol_map.t
      ; follower_equity : Usd.Stable.V1.t
      ; day_start_equity : Usd.Stable.V1.t
      ; follower_positions : Size.Stable.V1.t Symbol_map.t
      ; pending : Pending.Stable.V1.t list
      ; marks : Price.Stable.V1.t Symbol_map.t
      ; managed : Set.M(Symbol).t
      ; next_seq : int
      ; slippage_estimates : float Symbol_map.t [@sexp_drop_if Map.is_empty]
      }
    [@@deriving bin_io, sexp, compare, equal]

    let of_v1
      ({ config
       ; leader_equity
       ; leader_positions
       ; follower_equity
       ; day_start_equity
       ; follower_positions
       ; pending
       ; marks
       ; managed
       ; next_seq
       } :
        V1.t)
      =
      { config = Config.Stable.V2.of_v1 config
      ; leader_equity
      ; leader_positions
      ; follower_equity
      ; day_start_equity
      ; follower_positions
      ; pending
      ; marks
      ; managed
      ; next_seq
      ; slippage_estimates = Map.empty (module Symbol)
      }
    ;;
  end
end

include Stable.V2

let create config =
  { config
  ; leader_equity = Usd.zero
  ; leader_positions = Map.empty (module Symbol)
  ; follower_equity = Usd.zero
  ; day_start_equity = Usd.zero
  ; follower_positions = Map.empty (module Symbol)
  ; pending = []
  ; marks = Map.empty (module Symbol)
  ; managed = Set.empty (module Symbol)
  ; next_seq = 0
  ; slippage_estimates = Map.empty (module Symbol)
  }
;;

module Event = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Leader_position of
            { symbol : Symbol.Stable.V1.t
            ; size : Size.Stable.V1.t
            ; mark : Price.Stable.V1.t
            }
        | Leader_equity of Usd.Stable.V1.t
        | Follower_equity of Usd.Stable.V1.t
        | Mark of
            { symbol : Symbol.Stable.V1.t
            ; mark : Price.Stable.V1.t
            }
        | Follower_fill of Fill.Stable.V1.t
        | Order_closed of Cloid.Stable.V1.t
        | Resync of
            { leader : Leader_state.t
            ; follower : Follower_state.t
            ; marks : Price.Stable.V1.t Symbol_map.t
            }
        | Rebalance
        | Start_day
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

let find_size m symbol = Option.value (Map.find m symbol) ~default:Size.zero

let set_size m symbol size =
  if Size.is_zero size then Map.remove m symbol else Map.set m ~key:symbol ~data:size
;;

let same_side a b =
  (Size.is_positive a && Size.is_positive b) || (Size.is_negative a && Size.is_negative b)
;;

let daily_pnl t = Usd.(t.follower_equity - t.day_start_equity)

let other_notional t symbol =
  Map.fold t.follower_positions ~init:Usd.zero ~f:(fun ~key ~data acc ->
    if Symbol.equal key symbol
    then acc
    else (
      match Map.find t.marks key with
      | None -> acc
      | Some mark -> Usd.(acc + Caps.notional data mark)))
;;

let live_pending t symbol =
  List.filter t.pending ~f:(fun (p : Pending.t) ->
    Symbol.equal p.symbol symbol && not p.cancel_requested)
;;

let in_flight pending =
  List.fold pending ~init:Size.zero ~f:(fun acc (p : Pending.t) ->
    Size.(acc + p.remaining))
;;

(* The scaled and clamped target, or why there is none. [current] includes in-flight
   orders. *)
let capped_target t symbol ~current =
  match Map.find t.config.specs symbol with
  | None -> Error Plan.Note.Reason.No_spec
  | Some spec ->
    (match Map.find t.marks symbol with
     | None -> Error Plan.Note.Reason.No_mark
     | Some mark ->
       if Scale.needs_leader_equity t.config.mode && not (Usd.is_positive t.leader_equity)
       then Error No_leader_equity
       else (
         let raw =
           Scale.target_size
             ~leader_size:(find_size t.leader_positions symbol)
             ~leader_equity:t.leader_equity
             ~follower_equity:t.follower_equity
             ~mark
             ~mode:t.config.mode
         in
         let ctx =
           { Caps.Context.symbol
           ; mark
           ; current
           ; equity = t.follower_equity
           ; other_notional = other_notional t symbol
           ; daily_pnl = daily_pnl t
           }
         in
         let target, reasons = Caps.clamp t.config.caps ctx ~target:raw in
         Ok (spec, mark, target, reasons)))
;;

let note symbol reason = { Plan.Note.symbol; reason }

let target t symbol =
  let current =
    Size.(find_size t.follower_positions symbol + in_flight (live_pending t symbol))
  in
  match capped_target t symbol ~current with
  | Error reason -> None, [ note symbol reason ]
  | Ok (_, _, target, reasons) ->
    Some target, List.map reasons ~f:(fun r -> note symbol (Plan.Note.Reason.Capped r))
;;

(* The follow's no-trade band between the capped target and the order: the target to trade
   to, and a [Within_band] note when the band held back an order that would otherwise have
   gone out. Without a band the target is unchanged. *)
let[@inline] apply_band t symbol ~spec ~mark ~current ~target =
  match t.config.band with
  | None -> target, None
  | Some band ->
    let cost_bps =
      No_trade_band.cost_bps band ~estimate:(Map.find t.slippage_estimates symbol)
    in
    (match
       No_trade_band.decide
         band
         ~cost_bps
         ~equity:t.follower_equity
         ~mark
         ~current
         ~target
     with
     | Trade target -> target, None
     | Skip { gap; band; saved } ->
       let would_trade, _ = Caps.order t.config.caps ~spec ~mark ~current ~target in
       ( current
       , Option.map would_trade ~f:(fun _ ->
           note symbol (Plan.Note.Reason.Within_band { gap; band; saved })) ))
;;

let plan_symbol t symbol =
  let pos = find_size t.follower_positions symbol in
  let live = live_pending t symbol in
  let current = Size.(pos + in_flight live) in
  match capped_target t symbol ~current with
  | Error reason -> t, { Plan.actions = []; notes = [ note symbol reason ] }
  | Ok (spec, mark, target, reasons) ->
    let target, band_note = apply_band t symbol ~spec ~mark ~current ~target in
    let need = Size.(target - pos) in
    (* Keep in-flight orders, oldest first, while together they move toward the target
       without passing it; cancel the rest. *)
    let kept, to_cancel =
      List.fold live ~init:(Size.zero, []) ~f:(fun (kept, cancel) (p : Pending.t) ->
        let with_p = Size.(kept + p.remaining) in
        if same_side p.remaining need && Size.(abs with_p <= abs need)
        then with_p, cancel
        else kept, p.cloid :: cancel)
    in
    let to_cancel = List.rev to_cancel in
    let effective = Size.(pos + kept) in
    let order, why = Caps.order t.config.caps ~spec ~mark ~current:effective ~target in
    let notes =
      List.map
        (reasons @ Option.to_list why)
        ~f:(fun r -> note symbol (Plan.Note.Reason.Capped r))
      @ Option.to_list band_note
    in
    let pending =
      List.map t.pending ~f:(fun (p : Pending.t) ->
        if List.mem to_cancel p.cloid ~equal:Cloid.equal
        then { p with cancel_requested = true }
        else p)
    in
    let cancels =
      List.map to_cancel ~f:(fun cloid -> Plan.Action.Cancel { symbol; cloid })
    in
    (match order with
     | None -> { t with pending }, { Plan.actions = cancels; notes }
     | Some d ->
       let cloid = Cloid.create ~follower:t.config.follower ~seq:t.next_seq in
       let side : Side.t = if Size.is_positive d then Buy else Sell in
       let after = Size.(effective + d) in
       let reduce_only =
         Size.(abs after < abs effective)
         && (Size.is_zero after || same_side after effective)
       in
       let order =
         { Plan.Order.cloid
         ; symbol
         ; side
         ; size = Size.abs d
         ; limit_px =
             Rounding.ioc_limit spec ~side ~mark ~slippage_bps:t.config.slippage_bps
         ; reduce_only
         }
       in
       let pending =
         pending @ [ { Pending.cloid; symbol; remaining = d; cancel_requested = false } ]
       in
       ( { t with pending; next_seq = t.next_seq + 1 }
       , { Plan.actions = cancels @ [ Place order ]; notes } ))
;;

let plan_symbols t symbols =
  let t, plans =
    List.fold_map symbols ~init:t ~f:(fun t symbol -> plan_symbol t symbol)
  in
  t, Plan.concat plans
;;

let rebalance t = plan_symbols t (Set.to_list t.managed)

let on_leader_position_change t ~symbol ~size ~mark =
  let t =
    { t with
      leader_positions = set_size t.leader_positions symbol size
    ; marks = Map.set t.marks ~key:symbol ~data:mark
    ; managed = (if Size.is_zero size then t.managed else Set.add t.managed symbol)
    }
  in
  if Set.mem t.managed symbol then plan_symbol t symbol else t, Plan.empty
;;

let on_leader_equity t equity = { t with leader_equity = equity }
let on_follower_equity t equity = { t with follower_equity = equity }
let on_mark t ~symbol ~mark = { t with marks = Map.set t.marks ~key:symbol ~data:mark }

let on_slippage_estimate t ~symbol ~bps =
  { t with slippage_estimates = Map.set t.slippage_estimates ~key:symbol ~data:bps }
;;

let on_follower_fill t (fill : Fill.t) =
  let signed = Fill.signed_size fill in
  let follower_positions =
    set_size
      t.follower_positions
      fill.symbol
      Size.(find_size t.follower_positions fill.symbol + signed)
  in
  let pending =
    match fill.cloid with
    | None -> t.pending
    | Some cloid ->
      List.filter_map t.pending ~f:(fun (p : Pending.t) ->
        if not (Cloid.equal p.cloid cloid)
        then Some p
        else (
          let remaining = Size.(p.remaining - signed) in
          if same_side remaining p.remaining then Some { p with remaining } else None))
  in
  { t with follower_positions; pending }
;;

let on_order_closed t cloid =
  { t with
    pending =
      List.filter t.pending ~f:(fun (p : Pending.t) -> not (Cloid.equal p.cloid cloid))
  }
;;

let on_resync
  t
  ~(leader_state : Leader_state.t)
  ~(follower_state : Follower_state.t)
  ~marks
  =
  let nonzero m = Map.filter m ~f:(fun s -> not (Size.is_zero s)) in
  let leader_positions = nonzero leader_state.positions in
  let t =
    { t with
      leader_equity = leader_state.equity
    ; leader_positions
    ; follower_equity = follower_state.equity
    ; day_start_equity =
        (if Usd.is_zero t.day_start_equity
         then follower_state.equity
         else t.day_start_equity)
    ; follower_positions = nonzero follower_state.positions
    ; pending = follower_state.open_orders
    ; marks = Map.merge_skewed t.marks marks ~combine:(fun ~key:_ _ newer -> newer)
    ; managed = Set.union t.managed (Map.key_set leader_positions)
    }
  in
  rebalance t
;;

let start_day t = { t with day_start_equity = t.follower_equity }

let apply t (event : Event.t) =
  match event with
  | Leader_position { symbol; size; mark } ->
    on_leader_position_change t ~symbol ~size ~mark
  | Leader_equity e -> on_leader_equity t e, Plan.empty
  | Follower_equity e -> on_follower_equity t e, Plan.empty
  | Mark { symbol; mark } -> on_mark t ~symbol ~mark, Plan.empty
  | Follower_fill fill -> on_follower_fill t fill, Plan.empty
  | Order_closed cloid -> on_order_closed t cloid, Plan.empty
  | Resync { leader; follower; marks } ->
    on_resync t ~leader_state:leader ~follower_state:follower ~marks
  | Rebalance -> rebalance t
  | Start_day -> start_day t, Plan.empty
;;
