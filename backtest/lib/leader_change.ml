open! Core
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Price = Market_data.Price
module Fill = Hl_copy_core.Fill
module Notional = Fixed_decimal.Product (Size) (Price) (Hl_copy_core.Usd)
module Avg = Fixed_decimal.Product (Price) (Size) (Hl_copy_core.Usd)

type t =
  { time_ms : int
  ; symbol : Symbol.t
  ; size : Size.t
  ; price : Price.t
  ; traded : Size.t
  ; fills : int
  }
[@@deriving sexp, compare, equal]

let time_ms (f : Fill.t) = f.time_ns / 1_000_000

let same_group (a : Fill.t) (b : Fill.t) =
  time_ms a = time_ms b
  && Symbol.equal a.symbol b.symbol
  && Market_data.Side.equal a.side b.side
;;

(* [group] is newest first. *)
let close_group positions group =
  let first = List.last_exn group in
  let traded = Size.sum (List.map group ~f:Fill.signed_size) in
  let volume = Size.sum (List.map group ~f:(fun (f : Fill.t) -> f.size)) in
  let cost =
    Hl_copy_core.Usd.sum (List.map group ~f:(fun (f : Fill.t) -> Notional.mul f.size f.price))
  in
  let price = if Size.is_zero volume then first.price else Avg.div cost volume in
  let before = Option.value (Map.find positions first.symbol) ~default:Size.zero in
  let size = Size.(before + traded) in
  ( Map.set positions ~key:first.symbol ~data:size
  , { time_ms = time_ms first
    ; symbol = first.symbol
    ; size
    ; price
    ; traded
    ; fills = List.length group
    } )
;;

let of_fills fills =
  let rec loop positions acc group = function
    | [] ->
      (match group with
       | [] -> List.rev acc
       | _ ->
         let _, change = close_group positions group in
         List.rev (change :: acc))
    | (f : Fill.t) :: rest ->
      (match group with
       | prev :: _ when same_group prev f -> loop positions acc (f :: group) rest
       | [] -> loop positions acc [ f ] rest
       | _ ->
         let positions, change = close_group positions group in
         loop positions (change :: acc) [ f ] rest)
  in
  loop (Map.empty (module Symbol)) [] [] fills
;;
