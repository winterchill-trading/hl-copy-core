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
      ; Quickcheck.Generator.map (Float.gen_incl 0. 10.) ~f:(fun m -> Multiplier m)
      ; Quickcheck.Generator.map (Int.gen_incl 0 1_000_000_000_000_000) ~f:(fun u ->
          Fixed_notional (Usd.of_units u))
      ]
  ;;
end

let max_multiplier = 1000.

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

let target_size ~leader_size ~leader_equity ~follower_equity ~(mode : Mode.t) =
  match mode with
  | Equity_ratio -> ratio_size ~leader_size ~leader_equity ~capital:follower_equity
  | Fixed_notional amount ->
    ratio_size ~leader_size ~leader_equity ~capital:(Usd.min amount follower_equity)
  | Multiplier m ->
    if Float.is_nan m || Float.(m <= 0.)
    then Size.zero
    else (
      let m = Float.min m max_multiplier in
      let m_units = Float.iround_nearest_exn (m *. Float.of_int Size.units_per_one) in
      Size.of_units (Fixed_decimal.mul_units (Size.to_units leader_size) m_units))
;;
