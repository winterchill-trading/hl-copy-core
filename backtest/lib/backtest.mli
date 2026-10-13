(** Replays a leader's recorded fills through {!Hl_copy_core.Mirror} and fills the
    follower's orders from the same record, to estimate what copying would have earned.

    For each leader position change ({!Leader_change}), in time order:

    + At the first change of a new UTC day the daily-loss window restarts
      ({!Hl_copy_core.Mirror.start_day}).
    + The change's price becomes the coin's mark; the follower's equity
      ([start + realized - fees + unrealized at the marks]) and the leader's equity (its
      curve at that time) are given to the mirror.
    + The mirror plans the follower's IOC orders (scaling, caps, lot and tick rounding).
    + Each order fills in full at the change's price moved [slippage_bps] against the
      follower, if that is inside the order's IOC limit; otherwise it is not filled.
      Every fill pays [fee_bps] of its notional.
    + One equity curve point is recorded.

    Positions are marked to the leader's fill prices, so a coin's mark moves only when the
    leader trades it. Funding, liquidations, partial fills and latency are not modelled;
    a change that the mirror plans nothing for is counted as skipped when a cap, the lot
    or the minimum notional caused it. *)

open! Core

module Params : sig
  type t =
    { follow : Hl_copy_core.Follower_config.t
    (** mode, caps and IOC slippage; the leader is the replayed one *)
    ; start_equity : Hl_copy_core.Usd.t
    ; slippage_bps : float
    (** execution price distance from the leader's price, against the follower *)
    ; fee_bps : float
    ; specs : Hl_copy_core.Rounding.Spec.t Hl_copy_core.Mirror.Symbol_map.t (** see {!Specs} *)
    }
  [@@deriving sexp_of]

  (** 4.5: Hyperliquid's base-tier perpetual taker fee. *)
  val default_fee_bps : float

  (** 5. *)
  val default_slippage_bps : float
end

module Point : sig
  type t =
    { time_ms : int
    ; equity : float (** the follower's *)
    ; leader_equity : float (** the leader's curve at that time; 0 when unknown *)
    }
  [@@deriving sexp, compare, equal]
end

module Result : sig
  type t =
    { leader : Hl_copy_core.Address.t
    ; start_ms : int (** first leader change; 0 when there is none *)
    ; end_ms : int
    ; start_equity : Hl_copy_core.Usd.t
    ; end_equity : Hl_copy_core.Usd.t
    ; pnl : Hl_copy_core.Usd.t (** [end_equity - start_equity] *)
    ; return_ : float (** [pnl / start_equity] *)
    ; max_drawdown : float (** of the follower curve, as a fraction of the peak *)
    ; realized : Hl_copy_core.Usd.t
    ; unrealized : Hl_copy_core.Usd.t
    ; fees : Hl_copy_core.Usd.t
    ; turnover : Hl_copy_core.Usd.t (** sum of filled notional *)
    ; orders : int (** IOC orders placed *)
    ; unfilled_orders : int (** orders whose limit the slipped price was beyond *)
    ; leader_changes : int
    ; changes_traded : int (** changes that placed at least one order *)
    ; changes_capped : int (** traded changes with a cap note *)
    ; changes_skipped : int
    (** changes with no order and a note: cap, lot, minimum notional, missing spec *)
    ; skip_rate : float (** [changes_skipped / leader_changes] *)
    ; reasons : (string * int) list
    (** per note reason, the number of changes it appeared in, by name *)
    ; leader_return : float
    (** the leader's curve from [start_ms] to [end_ms]; 0 without a curve *)
    ; leader_max_drawdown : float
    ; leader_fill_pnl : Hl_copy_core.Usd.t
    (** the leader's [closedPnl - fee] over the replayed fills *)
    ; leader_mtm_pnl : Hl_copy_core.Usd.t
    (** the leader's fills booked like the follower's (average entry, real fees, marked
        at the same final prices): what the follower copies, before scaling and costs *)
    ; leader_mtm_return : float
    (** [leader_mtm_pnl] over the leader's curve equity at [start_ms]; 0 without one *)
    ; positions : (Market_data.Symbol.t * Market_data.Size.t) list (** at the end *)
    ; curve : Point.t list (** one point per leader change, oldest first *)
    }
  [@@deriving sexp_of]
end

val run : Params.t -> Input.t -> Result.t

(** The name a note reason is counted under in [Result.reasons]: [below_min_notional],
    [below_lot], [not_allowlisted], [daily_loss], [symbol_notional], [leverage],
    [no_spec], [no_mark] or [no_leader_equity]. *)
val reason_name : Hl_copy_core.Plan.Note.Reason.t -> string

(** Largest fall from a running peak, as a fraction of the peak; 0 for fewer than two
    points or a non-positive peak. *)
val max_drawdown : float list -> float
