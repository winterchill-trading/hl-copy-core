(** A no-trade band around the follower's target: rebalance only when the gap between what
    the follower holds and its capped target costs more to carry than to close.

    The rule is the one-period mean-variance trade-off with transaction costs. With [g]
    the gap in USD notional ([(target - current) * mark]), [E] the follower's equity, [c]
    the one-way cost as a fraction of notional ({!cost_bps}: fee plus expected slippage),
    [s] the symbol's return volatility over the time a gap stays open ([vol_bps]) and
    [gamma] the risk aversion, a trade [q] (USD) is chosen to minimise

    {v
      c |q| + eta q^2 / E + gamma s^2 (g - q)^2 / (2 E)
    v}

    where the middle term is the quadratic (impact) cost, [eta = 0] for {!Cost_model.t}
    [Proportional]. The solution has closed-form band edges:

    - half-width [h = c E / (gamma s^2)] (USD notional, so [c / (gamma s^2)] as a fraction
      of equity): inside [|g| <= h] nothing trades;
    - outside it the follower trades [phi (|g| - h)] toward the target, with
      [phi = gamma s^2 / (gamma s^2 + 2 eta)]: to the near band edge under proportional
      costs ([phi = 1]), part of the way under quadratic costs.

    The band widens with cost and narrows with risk aversion and volatility. With a zero
    cost and no quadratic term the band is empty and the target is returned unchanged, so
    such a band plans exactly what no band plans (property-tested in [test/]).

    A leader close (target zero) is always copied in full: trading to a band edge would
    leave the follower holding a position the leader no longer has. *)

open! Core

module Slippage : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Fixed_bps of float
        | Impact of { fallback_bps : float }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  (** Expected slippage of a rebalancing order, in basis points of its notional. *)
  type t = Stable.V1.t =
    | Fixed_bps of float (** a configured estimate *)
    | Impact of { fallback_bps : float }
    (** estimated by the caller from the order book (execution-algos' [Impact] walk), set
        per symbol with [Mirror.on_slippage_estimate]; [fallback_bps] until one is known *)
  [@@deriving bin_io, sexp, compare, equal]
end

module Cost_model : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Proportional
        | Quadratic of { impact : float }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    | Proportional (** fee and slippage proportional to the notional: trade to the edge *)
    | Quadratic of { impact : float }
    (** plus [impact * q^2 / E] for a trade of [q] USD on equity [E]: trade part of the
        way past the edge *)
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable : sig
  module V1 : sig
    type t =
      { fee_bps : float
      ; slippage : Slippage.Stable.V1.t
      ; risk_aversion : float
      ; vol_bps : float
      ; cost_model : Cost_model.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { fee_bps : float (** taker fee, basis points *)
  ; slippage : Slippage.t
  ; risk_aversion : float (** [gamma], positive; higher keeps the follower closer *)
  ; vol_bps : float
  (** return volatility of the symbol over the time a gap is left open, basis points;
      positive *)
  ; cost_model : Cost_model.t
  }
[@@deriving bin_io, sexp, compare, equal]

(** Hyperliquid's base taker fee (4.5 bp), 5 bp of slippage, risk aversion 20, 300 bp of
    volatility (about a day of BTC), proportional costs: a half-width of 5.3% of equity. A
    starting point to tune, not a recommendation. *)
val default : t

(** What is wrong, if anything: non-negative finite costs, positive finite risk aversion
    and volatility, a non-negative quadratic impact. *)
val errors : t -> string list

val validate : t -> unit Or_error.t

(** [fee_bps] plus the slippage: [Fixed_bps], or for [Impact] the [estimate] when given,
    else the fallback. Negative estimates count as zero. *)
val cost_bps : t -> estimate:float option -> float

(** [c E / (gamma s^2)] in USD notional; zero when [equity] is not positive. *)
val half_width : t -> cost_bps:float -> equity:float -> float

(** [phi]: 1 for proportional costs, [gamma s^2 / (gamma s^2 + 2 impact)] for quadratic. *)
val step_fraction : t -> float

module Decision : sig
  type t =
    | Trade of Market_data.Size.t
    (** the target to trade to (the input target when the band is empty, a close, or no
        gap) *)
    | Skip of
        { gap : Market_data.Size.t (** [target - current], signed *)
        ; band : Usd.t (** the half-width *)
        ; saved : Usd.t (** estimated cost of closing the gap, not paid *)
        }
  [@@deriving sexp_of, compare, equal]
end

(** The band applied to one symbol. [current] is the follower's position plus what its
    in-flight orders will add; [target] the capped target. *)
val decide
  :  t
  -> cost_bps:float
  -> equity:Usd.t
  -> mark:Market_data.Price.t
  -> current:Market_data.Size.t
  -> target:Market_data.Size.t
  -> Decision.t
