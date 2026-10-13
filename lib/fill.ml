open! Core
module Symbol = Market_data.Symbol
module Side = Market_data.Side
module Size = Market_data.Size
module Price = Market_data.Price

module Stable = struct
  module V1 = struct
    type t =
      { time_ns : int
      ; symbol : Symbol.Stable.V1.t
      ; side : Side.Stable.V1.t
      ; size : Size.Stable.V1.t
      ; price : Price.Stable.V1.t
      ; fee : Usd.Stable.V1.t
      ; closed_pnl : Usd.Stable.V1.t
      ; cloid : Cloid.Stable.V1.t option
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let signed_size t =
  match t.side with
  | Buy -> t.size
  | Sell -> Size.neg t.size
;;

let quickcheck_generator =
  let open Quickcheck.Generator.Let_syntax in
  let%map time_ns = Int.gen_incl 0 1_000_000_000_000
  and symbol = Quickcheck.Generator.of_list [ "BTC"; "ETH"; "SOL" ]
  and side = Quickcheck.Generator.of_list Side.all
  and size = Int.gen_incl 1 100_000_000
  and price = Int.gen_incl 1_000_000_000 10_000_000_000_000
  and fee = Int.gen_incl 0 10_000_000
  and closed_pnl = Int.gen_incl (-10_000_000_000) 10_000_000_000 in
  { time_ns
  ; symbol = Symbol.of_string symbol
  ; side
  ; size = Size.of_units size
  ; price = Price.of_units price
  ; fee = Usd.of_units fee
  ; closed_pnl = Usd.of_units closed_pnl
  ; cloid = None
  }
;;
