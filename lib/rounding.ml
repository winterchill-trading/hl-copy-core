open! Core
module Size = Market_data.Size
module Price = Market_data.Price

module Spec = struct
  module Stable = struct
    module V1 = struct
      type t =
        { lot : Size.Stable.V1.t
        ; tick : Price.Stable.V1.t
        ; sig_figs : int option
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let pow10 n = Int.pow 10 n

  (* Units are 10^-8, so 10^-d is 10^(8 - d) units. *)
  let units_of_decimals d = pow10 (Int.max 0 (Size.decimals - d))

  let hyperliquid_perp ~sz_decimals =
    { lot = Size.of_units (units_of_decimals sz_decimals)
    ; tick = Price.of_units (units_of_decimals (6 - sz_decimals))
    ; sig_figs = Some 5
    }
  ;;

  let of_asset_meta (m : Hl_protocol.Meta.Asset_meta.t) =
    hyperliquid_perp ~sz_decimals:m.sz_decimals
  ;;

  let of_instrument_info (i : Market_data.Instrument_info.t) =
    { lot = i.lot; tick = i.tick; sig_figs = None }
  ;;
end

let size (spec : Spec.t) s =
  let lot = Size.to_units spec.lot in
  if lot <= 0
  then s
  else (
    let u = Size.to_units s in
    Size.of_units (u - Int.rem u lot))
;;

let delta spec ~current ~target =
  let d = size spec Size.(target - current) in
  if Size.is_zero d then None else Some d
;;

let num_digits n =
  let rec loop n acc = if n < 10 then acc else loop (n / 10) (acc + 1) in
  loop n 1
;;

(* Grid step at price [u] (in units): the tick, or the significant-figure step when it is
   coarser and a multiple of the tick. The significant-figure step is capped at one whole
   unit of price, since integer prices are always valid. *)
let step (spec : Spec.t) u =
  let tick = Int.max 1 (Price.to_units spec.tick) in
  match spec.sig_figs with
  | None -> tick
  | Some figs ->
    let sig_step = Spec.pow10 (Int.max 0 (num_digits u - figs)) in
    let sig_step = Int.min sig_step Price.units_per_one in
    if sig_step > tick && sig_step % tick = 0 then sig_step else tick
;;

let round_to ~step ~dir u =
  let down = u - (u % step) in
  match dir with
  | `Down -> down
  | `Up -> if down = u then u else down + step
;;

let price spec p ~dir =
  let u = Price.to_units p in
  if u <= 0
  then p
  else (
    let r = round_to ~step:(step spec u) ~dir u in
    (* Rounding up can add a digit (99999.5 -> 100000) and rounding down can drop one; the
       result is still on the coarser of the two grids, so one pass is enough. *)
    Price.of_units r)
;;

let ioc_limit spec ~(side : Market_data.Side.t) ~mark ~slippage_bps =
  let u = Price.to_units mark in
  let bps = Int.max 0 slippage_bps in
  match side with
  | Buy -> price spec (Price.of_units (u * (10_000 + bps) / 10_000)) ~dir:`Down
  | Sell ->
    let num = u * Int.max 0 (10_000 - bps) in
    (* ceiling division, so the bound is never widened before rounding up *)
    price spec (Price.of_units ((num + 9_999) / 10_000)) ~dir:`Up
;;
