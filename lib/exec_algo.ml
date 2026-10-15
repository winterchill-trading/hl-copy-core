open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Immediate
      | Twap of
          { duration_ms : int
          ; slices : int
          ; max_participation : float option
          }
      | Vwap of
          { duration_ms : int
          ; slices : int
          ; max_participation : float option
          }
      | Pov of
          { participation : float
          ; max_duration_ms : int
          }
      | Passive of
          { display : float
          ; timeout_ms : int
          }
      | Adaptive of
          { small_ratio : float
          ; depth_bps : int
          ; max_behind_bps : int
          ; max_drift_bps : int
          ; timeout_ms : int
          }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let default = Immediate

let name = function
  | Immediate -> "immediate"
  | Twap _ -> "twap"
  | Vwap _ -> "vwap"
  | Pov _ -> "pov"
  | Passive { display; _ } when Float.(display < 1.) -> "iceberg"
  | Passive _ -> "passive"
  | Adaptive _ -> "adaptive"
;;

let errors t =
  let pos name x = Option.some_if (x <= 0) (name ^ " must be positive") in
  let frac name x =
    Option.some_if
      (Float.is_nan x || Float.(x <= 0.) || Float.(x > 1.))
      (name ^ " must be in (0, 1]")
  in
  let errors =
    match t with
    | Immediate -> []
    | Twap { duration_ms; slices; max_participation }
    | Vwap { duration_ms; slices; max_participation } ->
      [ pos "duration" duration_ms
      ; pos "slices" slices
      ; Option.bind max_participation ~f:(frac "max_participation")
      ]
    | Pov { participation; max_duration_ms } ->
      [ frac "participation" participation; pos "max_duration" max_duration_ms ]
    | Passive { display; timeout_ms } ->
      [ frac "display" display; pos "timeout" timeout_ms ]
    | Adaptive { small_ratio; depth_bps; max_behind_bps; max_drift_bps; timeout_ms } ->
      [ Option.some_if
          (Float.is_nan small_ratio || Float.(small_ratio <= 0.))
          "small_ratio must be positive"
      ; pos "depth_bps" depth_bps
      ; pos "max_behind_bps" max_behind_bps
      ; pos "max_drift_bps" max_drift_bps
      ; pos "timeout" timeout_ms
      ]
  in
  List.filter_opt errors
;;

let validate t =
  match errors t with
  | [] -> Ok ()
  | errors -> Or_error.error_s [%message "invalid execution algo" (errors : string list)]
;;
