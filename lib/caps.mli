(** Per-follower risk caps, applied to a scaled target before an order is planned.

    Caps only ever limit growth: a cap never forces the follower below the position it
    already holds on the same side, so mark moves alone never create trades. In order:

    + Allowlist: a symbol not on [allowlist] (when one is set) is not traded at all.
    + Daily loss: once [daily_pnl <= -max_daily_loss] the follower may only reduce or
      close, not grow or flip.
    + Notional per symbol: [|target| * mark <= max_notional_per_symbol].
    + Leverage: [(other_notional + |target| * mark) <= max_leverage * equity].
    + The order [target - current] is truncated to the lot; an order under one lot or
      under [min_order_notional] (except a full close) is dropped. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { max_leverage : float option
      ; max_notional_per_symbol : Usd.Stable.V1.t option
      ; max_daily_loss : Usd.Stable.V1.t option
      ; allowlist : Market_data.Symbol.Stable.V1.t list option
      ; min_order_notional : Usd.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { max_leverage : float option
  ; max_notional_per_symbol : Usd.t option
  ; max_daily_loss : Usd.t option
  ; allowlist : Market_data.Symbol.t list option (** [None]: every symbol *)
  ; min_order_notional : Usd.t
  }
[@@deriving bin_io, sexp, compare, equal]

(** No caps; [min_order_notional] is Hyperliquid's 10 USD. *)
val none : t

module Reason : sig
  module Stable : sig
    module V1 : sig
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

  type t = Stable.V1.t =
    | Not_allowlisted
    | Daily_loss_reached of
        { daily_pnl : Usd.t
        ; limit : Usd.t
        }
    | Symbol_notional of
        { wanted : Usd.t
        ; limit : Usd.t
        } (** [wanted] is the notional of the target before clamping *)
    | Leverage of
        { wanted : float
        ; limit : float
        } (** [wanted] is the account leverage the target would have given *)
    | Below_lot
    | Below_min_notional of
        { notional : Usd.t
        ; min : Usd.t
        }
  [@@deriving bin_io, sexp, compare, equal]
end

module Context : sig
  type t =
    { symbol : Market_data.Symbol.t
    ; mark : Market_data.Price.t
    ; current : Market_data.Size.t
    (** signed position, including in-flight orders expected to fill *)
    ; equity : Usd.t
    ; other_notional : Usd.t
    (** sum of [|size| * mark] over the follower's other symbols *)
    ; daily_pnl : Usd.t
    }
  [@@deriving sexp_of]
end

module Decision : sig
  type t =
    { target : Market_data.Size.t (** after caps, before lot rounding *)
    ; order : Market_data.Size.t option
    (** signed order size, a lot multiple; [None] when nothing should trade *)
    ; reasons : Reason.t list (** every cap that changed the outcome, in order *)
    }
  [@@deriving sexp_of]
end

(** The allowlist, daily-loss, notional and leverage steps: the capped target and the
    caps that changed it. *)
val clamp
  :  t
  -> Context.t
  -> target:Market_data.Size.t
  -> Market_data.Size.t * Reason.t list

(** The lot and minimum-notional step: the order from [current] to [target], or [None]
    with the reason it was dropped (no reason when [target = current]). *)
val order
  :  t
  -> spec:Rounding.Spec.t
  -> mark:Market_data.Price.t
  -> current:Market_data.Size.t
  -> target:Market_data.Size.t
  -> Market_data.Size.t option * Reason.t option

(** [clamp], then [order] from [ctx.current]. *)
val apply
  :  t
  -> Context.t
  -> spec:Rounding.Spec.t
  -> target:Market_data.Size.t
  -> Decision.t

(** [|size| * price], truncated. *)
val notional : Market_data.Size.t -> Market_data.Price.t -> Usd.t
