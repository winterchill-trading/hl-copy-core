open! Core
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Spec = Hl_copy_core.Rounding.Spec

type t = Spec.t Hl_copy_core.Mirror.Symbol_map.t [@@deriving sexp_of]

let of_meta (meta : Hl_protocol.Meta.t) =
  List.fold
    meta.universe
    ~init:(Map.empty (module Symbol))
    ~f:(fun acc m -> Map.set acc ~key:m.name ~data:(Spec.of_asset_meta m))
;;

let load_meta path =
  Or_error.try_with_join (fun () ->
    Yojson.Safe.from_file path |> Hl_protocol.Meta.t_of_yojson |> Or_error.return)
  |> Or_error.tag ~tag:path
;;

(* Hyperliquid perps have at most 6 size decimals (price decimals are [6 - szDecimals]). *)
let max_sz_decimals = 6

let decimals_of size =
  let units = Int.abs (Size.to_units size) in
  let rec go d =
    if d >= max_sz_decimals
    then max_sz_decimals
    else if units % Int.pow 10 (Size.decimals - d) = 0
    then d
    else go (d + 1)
  in
  go 0
;;

let inferred_sz_decimals fills =
  List.fold
    fills
    ~init:(Map.empty (module Symbol))
    ~f:(fun acc (f : Hl_copy_core.Fill.t) ->
      let d = decimals_of f.size in
      Map.update acc f.symbol ~f:(function
        | None -> d
        | Some prev -> Int.max prev d))
;;

let infer fills =
  Map.map (inferred_sz_decimals fills) ~f:(fun sz_decimals ->
    Spec.hyperliquid_perp ~sz_decimals)
;;

let combine ~meta ~inferred =
  Map.merge_skewed inferred meta ~combine:(fun ~key:_ _ from_meta -> from_meta)
;;
