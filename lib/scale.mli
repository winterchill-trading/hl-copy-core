(** Sizing: how big the follower's position should be for a given leader position.

    With [l] the leader's signed position size, [E_l] the leader's equity and [E_f] the
    follower's equity:

    - [Equity_ratio]: [l * E_f / E_l].
    - [Multiplier m]: [l * m], independent of equity. [m] is clamped to [[0, 1000]]; NaN
      gives [0].
    - [Fixed_notional a]: the follower copies as if its equity were [min a E_f], i.e.
      [l * min(a, E_f) / E_l]. This is the "copy with $a" allocation.

    A non-positive [E_l] (or a non-positive capital for the equity modes) gives zero. The
    result is truncated toward zero to 10^-8; rounding to the venue's lot is {!Rounding}'s
    job. *)

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

(** The follower's signed target size. It has the sign of [leader_size] (or is zero). *)
val target_size
  :  leader_size:Market_data.Size.t
  -> leader_equity:Usd.t
  -> follower_equity:Usd.t
  -> mode:Mode.t
  -> Market_data.Size.t
