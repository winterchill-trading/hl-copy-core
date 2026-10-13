(** Sizing: how big the follower's position should be for a given leader position.

    With [l] the leader's signed position size, [E_l] the leader's equity and [E_f] the
    follower's equity:

    - [Equity_ratio]: [l * E_f / E_l], so both accounts carry the same leverage.
    - [Multiplier k]: [l * k * E_f / E_l]; [k = 0.5] halves the leader's leverage. [k] is
      clamped to [[0, 100]]; NaN gives [0].
    - [Fixed_notional n]: every open leader position maps to [n] USD of notional on the
      same side, whatever its size: [sign(l) * n / mark].

    The equity modes give zero for a non-positive [E_l] or [E_f]. The result is truncated
    toward zero to 10^-8; rounding to the venue's lot is {!Rounding}'s job. *)

open! Core

module Mode : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Equity_ratio
        | Multiplier of float
        | Fixed_notional of Usd.Stable.V1.t
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    | Equity_ratio
    | Multiplier of float
    | Fixed_notional of Usd.t
  [@@deriving bin_io, sexp, compare, equal]

  val quickcheck_generator : t Quickcheck.Generator.t
end

(** The follower's signed target size. It has the sign of [leader_size] (or is zero).
    [mark] is only used by [Fixed_notional]. *)

(** Whether the mode needs the leader's equity ([Equity_ratio] and [Multiplier]). *)
val needs_leader_equity : Mode.t -> bool

val target_size
  :  leader_size:Market_data.Size.t
  -> leader_equity:Usd.t
  -> follower_equity:Usd.t
  -> mark:Market_data.Price.t
  -> mode:Mode.t
  -> Market_data.Size.t
