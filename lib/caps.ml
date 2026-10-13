open! Core
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Price = Market_data.Price

module Stable = struct
  module V1 = struct
    type t =
      { max_leverage : float option
      ; max_notional_per_symbol : Usd.Stable.V1.t option
      ; max_daily_loss : Usd.Stable.V1.t option
      ; allowlist : Symbol.Stable.V1.t list option
      ; min_order_notional : Usd.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let none =
  { max_leverage = None
  ; max_notional_per_symbol = None
  ; max_daily_loss = None
  ; allowlist = None
  ; min_order_notional = Usd.of_int 10
  }
;;

module Reason = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Not_allowlisted
        | Daily_loss_reached of
            { daily_pnl : Usd.Stable.V1.t
            ; limit : Usd.Stable.V1.t
            }
        | Symbol_notional of
            { wanted : Usd.Stable.V1.t
            ; limit : Usd.Stable.V1.t
            }
        | Leverage of
            { wanted : float
            ; limit : float
            }
        | Below_lot
        | Below_min_notional of
            { notional : Usd.Stable.V1.t
            ; min : Usd.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Context = struct
  type t =
    { symbol : Symbol.t
    ; mark : Price.t
    ; current : Size.t
    ; equity : Usd.t
    ; other_notional : Usd.t
    ; daily_pnl : Usd.t
    }
  [@@deriving sexp_of]
end

module Decision = struct
  type t =
    { target : Size.t
    ; order : Size.t option
    ; reasons : Reason.t list
    }
  [@@deriving sexp_of]
end

module P = Fixed_decimal.Product (Size) (Price) (Usd)

let notional size price = P.mul (Size.abs size) price

let same_side a b =
  (Size.is_positive a && Size.is_positive b) || (Size.is_negative a && Size.is_negative b)
;;

(* The largest size the follower may hold on [target]'s side: [cap_size], or what it
   already holds there if that is more. *)
let clamp_magnitude ~current ~target ~cap_size =
  let held = if same_side current target then Size.abs current else Size.zero in
  let allowed = Size.max cap_size held in
  if Size.(abs target <= allowed)
  then target
  else if Size.is_negative target
  then Size.neg allowed
  else allowed
;;

let clamp t (ctx : Context.t) ~target =
  let reasons = Queue.create () in
  let allowed =
    match t.allowlist with
    | None -> true
    | Some l -> List.mem l ctx.symbol ~equal:Symbol.equal
  in
  if not allowed
  then ctx.current, [ Reason.Not_allowlisted ]
  else (
    let target =
      match t.max_daily_loss with
      | Some limit when Usd.(ctx.daily_pnl <= neg limit) ->
        if not (Size.is_zero target)
        then
          Queue.enqueue
            reasons
            (Reason.Daily_loss_reached { daily_pnl = ctx.daily_pnl; limit });
        Size.zero
      | _ -> target
    in
    let price_positive = Price.is_positive ctx.mark in
    let target =
      match t.max_notional_per_symbol with
      | Some limit when price_positive ->
        let wanted = notional target ctx.mark in
        if Usd.(wanted <= limit)
        then target
        else (
          let cap_size = P.div limit ctx.mark in
          let clamped = clamp_magnitude ~current:ctx.current ~target ~cap_size in
          if not (Size.equal clamped target)
          then Queue.enqueue reasons (Reason.Symbol_notional { wanted; limit });
          clamped)
      | _ -> target
    in
    let target =
      match t.max_leverage with
      | Some limit when price_positive && Usd.is_positive ctx.equity ->
        let wanted_notional = Usd.(ctx.other_notional + notional target ctx.mark) in
        let wanted = Usd.to_float wanted_notional /. Usd.to_float ctx.equity in
        if Float.(wanted <= limit)
        then target
        else (
          let room =
            Usd.(of_float (limit *. to_float ctx.equity) - ctx.other_notional)
            [@alert "-lossy"]
          in
          let cap_size =
            if Usd.is_positive room then P.div room ctx.mark else Size.zero
          in
          let clamped = clamp_magnitude ~current:ctx.current ~target ~cap_size in
          if not (Size.equal clamped target)
          then Queue.enqueue reasons (Reason.Leverage { wanted; limit });
          clamped)
      | _ -> target
    in
    target, Queue.to_list reasons)
;;

let order t ~spec ~mark ~current ~target =
  match Rounding.delta spec ~current ~target with
  | None -> None, if Size.equal target current then None else Some Reason.Below_lot
  | Some d ->
    let full_close = Size.is_zero target in
    let n = notional d mark in
    if (not full_close) && Usd.(n < t.min_order_notional)
    then
      None, Some (Reason.Below_min_notional { notional = n; min = t.min_order_notional })
    else Some d, None
;;

let apply t (ctx : Context.t) ~spec ~target =
  let target, reasons = clamp t ctx ~target in
  let order, why = order t ~spec ~mark:ctx.mark ~current:ctx.current ~target in
  { Decision.target; order; reasons = reasons @ Option.to_list why }
;;
