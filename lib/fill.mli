(** A fill on a Hyperliquid account, as the copy logic needs it. Built from a
    {!Hl_protocol.User_fill} by the engine; times are nanoseconds since the epoch. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { time_ns : int
      ; symbol : Market_data.Symbol.Stable.V1.t
      ; side : Market_data.Side.Stable.V1.t
      ; size : Market_data.Size.Stable.V1.t (** positive *)
      ; price : Market_data.Price.Stable.V1.t
      ; fee : Usd.Stable.V1.t (** paid, positive; negative for a rebate *)
      ; closed_pnl : Usd.Stable.V1.t (** as reported by the venue, before fees *)
      ; cloid : Cloid.Stable.V1.t option
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { time_ns : int
  ; symbol : Market_data.Symbol.t
  ; side : Market_data.Side.t
  ; size : Market_data.Size.t
  ; price : Market_data.Price.t
  ; fee : Usd.t
  ; closed_pnl : Usd.t
  ; cloid : Cloid.t option
  }
[@@deriving bin_io, sexp, compare, equal]

(** [size] with the sign of [side]: positive for a buy. *)
val signed_size : t -> Market_data.Size.t

val quickcheck_generator : t Quickcheck.Generator.t
