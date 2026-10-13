open! Core
module Size = Market_data.Size

module Mode = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Equity_ratio
        | Multiplier of float
        | Fixed_notional of Usd.Stable.V1.t
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let quickcheck_generator =
    Quickcheck.Generator.union
      [ Quickcheck.Generator.return Equity_ratio
      ; Quickcheck.Generator.map (Float.gen_incl 0. 3.) ~f:(fun m -> Multiplier m)
      ; Quickcheck.Generator.map (Int.gen_incl 0 1_000_000_000_000_000) ~f:(fun u ->
          Fixed_notional (Usd.of_units u))
      ]
  ;;
end

let max_multiplier = 100.

module P = Fixed_decimal.Product (Size) (Market_data.Price) (Usd)

(* [leader_size * capital / leader_equity], with the ratio taken first so no intermediate
   overflows for any in-range equity. *)
let ratio_size ~leader_size ~leader_equity ~capital =
  if Usd.(leader_equity <= zero) || Usd.(capital <= zero)
  then Size.zero
  else (
    let ratio =
      Fixed_decimal.div_units (Usd.to_units capital) (Usd.to_units leader_equity)
    in
    Size.of_units (Fixed_decimal.mul_units (Size.to_units leader_size) ratio))
;;

let needs_leader_equity : Mode.t -> bool = function
  | Equity_ratio | Multiplier _ -> true
  | Fixed_notional _ -> false
;;

let target_size ~leader_size ~leader_equity ~follower_equity ~mark ~(mode : Mode.t) =
  match mode with
  | Equity_ratio -> ratio_size ~leader_size ~leader_equity ~capital:follower_equity
  | Multiplier k ->
    if Float.is_nan k || Float.(k <= 0.)
    then Size.zero
    else (
      let k = Float.min k max_multiplier in
      let k_units = Float.iround_nearest_exn (k *. Float.of_int Size.units_per_one) in
      let s = ratio_size ~leader_size ~leader_equity ~capital:follower_equity in
      Size.of_units (Fixed_decimal.mul_units (Size.to_units s) k_units))
  | Fixed_notional n ->
    if Size.is_zero leader_size
       || (not (Market_data.Price.is_positive mark))
       || not (Usd.is_positive n)
    then Size.zero
    else (
      let s = P.div n mark in
      if Size.is_negative leader_size then Size.neg s else s)
;;
