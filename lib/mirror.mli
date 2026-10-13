(** The copy state of one follower of one leader, and the plans that keep the follower's
    positions at the scaled, capped image of the leader's.

    Everything here is a pure function of the state and the event: the same events applied
    to the same state give the same plans, byte for byte (client order ids included), so
    the engine can journal events and replay them after a restart.

    Targets are absolute, not deltas. For each symbol the mirror computes the target from
    the leader's current position ({!Scale}, then {!Caps.clamp}), subtracts what the
    follower holds plus what its in-flight orders will add, and orders only the remainder
    (lot-rounded, above the minimum notional). A duplicated or replayed leader update
    therefore plans nothing new while earlier orders are still pending. In-flight orders
    that now point the wrong way, or overshoot, are cancelled.

    Symbols are only traded once the leader has held them ("managed" symbols), so
    positions the follower holds on its own in other symbols are never touched. Leader
    equity changes do not trigger trades by themselves; they apply from the next position
    change or {!rebalance}. *)

open! Core

module Symbol_map : sig
  type 'a t = 'a Map.M(Market_data.Symbol).t [@@deriving bin_io, sexp, compare, equal]
end

module Pending : sig
  module Stable : sig
    module V1 : sig
      type t =
        { cloid : Cloid.Stable.V1.t
        ; symbol : Market_data.Symbol.Stable.V1.t
        ; remaining : Market_data.Size.Stable.V1.t
        ; cancel_requested : bool
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  (** An order sent and not yet known to be closed. *)
  type t = Stable.V1.t =
    { cloid : Cloid.t
    ; symbol : Market_data.Symbol.t
    ; remaining : Market_data.Size.t (** signed: positive for a buy *)
    ; cancel_requested : bool
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Config : sig
  module Stable : sig
    module V1 : sig
      type t =
        { follower : int
        ; mode : Scale.Mode.Stable.V1.t
        ; caps : Caps.Stable.V1.t
        ; slippage_bps : int
        ; specs : Rounding.Spec.Stable.V1.t Symbol_map.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    { follower : int (** non-negative; the high half of every client order id *)
    ; mode : Scale.Mode.t
    ; caps : Caps.t
    ; slippage_bps : int (** IOC limit distance from the mark *)
    ; specs : Rounding.Spec.t Symbol_map.t (** symbols without a spec are not traded *)
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Leader_state : sig
  type t =
    { equity : Usd.t
    ; positions : Market_data.Size.t Symbol_map.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Follower_state : sig
  type t =
    { equity : Usd.t
    ; positions : Market_data.Size.t Symbol_map.t
    ; open_orders : Pending.t list (** orders this mirror placed that are still open *)
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable : sig
  module V1 : sig
    type t =
      { config : Config.Stable.V1.t
      ; leader_equity : Usd.Stable.V1.t
      ; leader_positions : Market_data.Size.Stable.V1.t Symbol_map.t
      ; follower_equity : Usd.Stable.V1.t
      ; day_start_equity : Usd.Stable.V1.t
      ; follower_positions : Market_data.Size.Stable.V1.t Symbol_map.t
      ; pending : Pending.Stable.V1.t list
      ; marks : Market_data.Price.Stable.V1.t Symbol_map.t
      ; managed : Set.M(Market_data.Symbol).t
      ; next_seq : int
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { config : Config.t
  ; leader_equity : Usd.t
  ; leader_positions : Market_data.Size.t Symbol_map.t (** non-zero entries only *)
  ; follower_equity : Usd.t
  ; day_start_equity : Usd.t
  ; follower_positions : Market_data.Size.t Symbol_map.t (** non-zero entries only *)
  ; pending : Pending.t list (** in placement order *)
  ; marks : Market_data.Price.t Symbol_map.t
  ; managed : Set.M(Market_data.Symbol).t
  ; next_seq : int (** sequence number of the next client order id *)
  }
[@@deriving bin_io, sexp, compare, equal]

val create : Config.t -> t

(** {2 Events} *)

module Event : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Leader_position of
            { symbol : Market_data.Symbol.Stable.V1.t
            ; size : Market_data.Size.Stable.V1.t
            ; mark : Market_data.Price.Stable.V1.t
            }
        | Leader_equity of Usd.Stable.V1.t
        | Follower_equity of Usd.Stable.V1.t
        | Mark of
            { symbol : Market_data.Symbol.Stable.V1.t
            ; mark : Market_data.Price.Stable.V1.t
            }
        | Follower_fill of Fill.Stable.V1.t
        | Order_closed of Cloid.Stable.V1.t
        | Resync of
            { leader : Leader_state.t
            ; follower : Follower_state.t
            ; marks : Market_data.Price.Stable.V1.t Symbol_map.t
            }
        | Rebalance
        | Start_day
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  (** One journal entry; {!apply} dispatches to the functions below. *)
  type t = Stable.V1.t =
    | Leader_position of
        { symbol : Market_data.Symbol.t
        ; size : Market_data.Size.t
        ; mark : Market_data.Price.t
        }
    | Leader_equity of Usd.t
    | Follower_equity of Usd.t
    | Mark of
        { symbol : Market_data.Symbol.t
        ; mark : Market_data.Price.t
        }
    | Follower_fill of Fill.t
    | Order_closed of Cloid.t
    | Resync of
        { leader : Leader_state.t
        ; follower : Follower_state.t
        ; marks : Market_data.Price.t Symbol_map.t
        }
    | Rebalance
    | Start_day
  [@@deriving bin_io, sexp, compare, equal]
end

val apply : t -> Event.t -> t * Plan.t

(** The leader's position in [symbol] is now [size] (signed, absolute), at [mark]. Plans
    the follower's side of that symbol. *)
val on_leader_position_change
  :  t
  -> symbol:Market_data.Symbol.t
  -> size:Market_data.Size.t
  -> mark:Market_data.Price.t
  -> t * Plan.t

val on_leader_equity : t -> Usd.t -> t
val on_follower_equity : t -> Usd.t -> t
val on_mark : t -> symbol:Market_data.Symbol.t -> mark:Market_data.Price.t -> t

(** Updates the follower's position, and the pending order with the fill's [cloid] (it is
    dropped once fully filled). Fills of other orders (manual trades) only move the
    position. Plans nothing: an IOC remainder is not chased until the next event. *)
val on_follower_fill : t -> Fill.t -> t

(** The order is done (IOC remainder cancelled, rejected, or cancel confirmed). *)
val on_order_closed : t -> Cloid.t -> t

(** Replaces both accounts with snapshots, the pending orders with [follower.open_orders]
    and merges [marks], then plans every managed symbol. Sets the day's starting equity if
    none was set. *)
val on_resync
  :  t
  -> leader_state:Leader_state.t
  -> follower_state:Follower_state.t
  -> marks:Market_data.Price.t Symbol_map.t
  -> t * Plan.t

(** Plans every managed symbol against the current state. *)
val rebalance : t -> t * Plan.t

(** Starts a new daily-loss window at the current follower equity. *)
val start_day : t -> t

(** {2 Queries} *)

(** [follower_equity - day_start_equity]. *)
val daily_pnl : t -> Usd.t

(** The follower's capped target in [symbol] (before lot rounding), with the notes that
    explain it. *)
val target : t -> Market_data.Symbol.t -> Market_data.Size.t option * Plan.Note.t list
