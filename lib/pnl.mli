(** Follower PnL attributed per leader.

    The engine attributes each follower fill to the leader whose mirror placed the order
    (by client order id). Each leader gets a virtual book per symbol, kept with average
    entry price accounting:

    - a fill on the side of the position (or from flat) moves the average entry to
      [(|s| * a + |q| * p) / |s + q|];
    - a fill against it realizes [min(|q|, |s|) * (p - a) * sign(s)]; any excess opens a
      new position at [p].

    Unrealized PnL is [s * (mark - a)]; net is [realized + unrealized - fees]. The books
    are virtual: two leaders copied on one symbol net out on the venue but not here. *)

open! Core

module Position : sig
  module Stable : sig
    module V1 : sig
      type t =
        { size : Market_data.Size.Stable.V1.t
        ; avg_entry : Market_data.Price.Stable.V1.t
        ; realized : Usd.Stable.V1.t
        ; fees : Usd.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    { size : Market_data.Size.t (** signed *)
    ; avg_entry : Market_data.Price.t (** zero when flat *)
    ; realized : Usd.t (** before fees *)
    ; fees : Usd.t
    }
  [@@deriving bin_io, sexp, compare, equal]

  val flat : t
  val apply_fill : t -> Fill.t -> t
  val unrealized : t -> mark:Market_data.Price.t -> Usd.t
end

module Summary : sig
  type t =
    { leader : Address.t
    ; realized : Usd.t
    ; unrealized : Usd.t
    ; fees : Usd.t
    ; net : Usd.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable : sig
  module V1 : sig
    type t = Position.Stable.V1.t Map.M(Market_data.Symbol).t Map.M(Address).t
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Position.t Map.M(Market_data.Symbol).t Map.M(Address).t
[@@deriving bin_io, sexp, compare, equal]

val empty : t
val on_fill : t -> leader:Address.t -> Fill.t -> t
val position : t -> leader:Address.t -> Market_data.Symbol.t -> Position.t

(** One summary per leader, in address order. Symbols without a mark count zero unrealized
    PnL. *)
val summary : t -> marks:Market_data.Price.t Map.M(Market_data.Symbol).t -> Summary.t list
