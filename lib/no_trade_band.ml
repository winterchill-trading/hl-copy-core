open! Core
module Size = Market_data.Size
module Price = Market_data.Price

module Slippage = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Fixed_bps of float
        | Impact of { fallback_bps : float }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Cost_model = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Proportional
        | Quadratic of { impact : float }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Stable = struct
  module V1 = struct
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

include Stable.V1

let default =
  { fee_bps = 4.5
  ; slippage = Fixed_bps 5.
  ; risk_aversion = 20.
  ; vol_bps = 300.
  ; cost_model = Proportional
  }
;;

let errors t =
  let non_negative name x =
    Option.some_if
      ((not (Float.is_finite x)) || Float.(x < 0.))
      (name ^ " not a non-negative number")
  in
  let positive name x =
    Option.some_if ((not (Float.is_finite x)) || Float.(x <= 0.)) (name ^ " not positive")
  in
  List.filter_opt
    [ non_negative "fee_bps" t.fee_bps
    ; (match t.slippage with
       | Fixed_bps b -> non_negative "slippage" b
       | Impact { fallback_bps } -> non_negative "slippage fallback_bps" fallback_bps)
    ; positive "risk_aversion" t.risk_aversion
    ; positive "vol_bps" t.vol_bps
    ; (match t.cost_model with
       | Proportional -> None
       | Quadratic { impact } -> non_negative "impact" impact)
    ]
;;

let validate t =
  match errors t with
  | [] -> Ok ()
  | errors -> Or_error.error_s [%message "invalid no-trade band" (errors : string list)]
;;

let cost_bps t ~estimate =
  let slippage =
    match t.slippage, estimate with
    | Fixed_bps b, _ -> b
    | Impact _, Some e -> e
    | Impact { fallback_bps }, None -> fallback_bps
  in
  t.fee_bps +. Float.max 0. slippage
;;

(* [gamma s^2] with [s] as a fraction. *)
let risk t =
  let s = t.vol_bps /. 10_000. in
  t.risk_aversion *. s *. s
;;

let half_width t ~cost_bps ~equity =
  if Float.(equity <= 0.) then 0. else cost_bps /. 10_000. *. equity /. risk t
;;

let impact t =
  match t.cost_model with
  | Proportional -> 0.
  | Quadratic { impact } -> impact
;;

let step_fraction t =
  let r = risk t in
  r /. (r +. (2. *. impact t))
;;

module Decision = struct
  type t =
    | Trade of Size.t
    | Skip of
        { gap : Size.t
        ; band : Usd.t
        ; saved : Usd.t
        }
  [@@deriving sexp_of, compare, equal]
end

let usd x = (Usd.of_float [@alert "-lossy"]) x

let decide t ~cost_bps ~equity ~mark ~current ~target : Decision.t =
  let gap = Size.(target - current) in
  let equity = Usd.to_float equity in
  let h = half_width t ~cost_bps ~equity in
  let phi = step_fraction t in
  if Size.is_zero target || Size.is_zero gap || Float.(h = 0. && phi = 1.)
  then Trade target
  else (
    let gap_usd = Float.abs (Size.to_float gap *. Price.to_float mark) in
    if Float.(gap_usd <= h)
    then (
      let saved =
        (cost_bps /. 10_000. *. gap_usd)
        +. if Float.(equity > 0.) then impact t *. gap_usd *. gap_usd /. equity else 0.
      in
      Skip { gap; band = usd h; saved = usd saved })
    else (
      (* Move [phi (|g| - h)] of the [|g|] toward the target, in size units so the
         rounding stays on the size grid. *)
      let fraction = phi *. (gap_usd -. h) /. gap_usd in
      let move = Float.iround_nearest_exn (fraction *. Float.of_int (Size.to_units gap)) in
      Trade Size.(current + of_units move)))
;;
