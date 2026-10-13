open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let btc = Symbol.of_string "BTC"
let alice = Address.of_string "0x1111111111111111111111111111111111111111"
let bob = Address.of_string "0x2222222222222222222222222222222222222222"

let fill ?(symbol = btc) ?(fee = "0") side size price : Fill.t =
  { time_ns = 0
  ; symbol
  ; side
  ; size = Size.of_string size
  ; price = Price.of_string price
  ; fee = Usd.of_string fee
  ; closed_pnl = Usd.zero
  ; cloid = None
  }
;;

let%expect_test "average entry, partial close, flip" =
  let t =
    List.fold
      [ alice, fill Buy "1" "100" ~fee:"0.1"
      ; alice, fill Buy "1" "110" ~fee:"0.1"
      ; alice, fill Sell "0.5" "120" ~fee:"0.05"
      ; alice, fill Sell "2" "90" ~fee:"0.2"
      ; bob, fill Sell "0.1" "100"
      ]
      ~init:Pnl.empty
      ~f:(fun t (leader, f) -> Pnl.on_fill t ~leader f)
  in
  print_s [%sexp (Pnl.position t ~leader:alice btc : Pnl.Position.t)];
  print_s
    [%sexp
      (Pnl.summary t ~marks:(Map.singleton (module Symbol) btc (Price.of_string "80"))
       : Pnl.Summary.t list)];
  [%expect
    {|
    ((size -0.5) (avg_entry 90) (realized -15) (fees 0.45))
    (((leader 0x1111111111111111111111111111111111111111) (realized -15)
      (unrealized 5) (fees 0.45) (net -10.45))
     ((leader 0x2222222222222222222222222222222222222222) (realized 0)
      (unrealized 2) (fees 0) (net 2)))
    |}]
;;

let%test_unit "a round trip to flat realizes the cash flow" =
  let open Quickcheck.Generator.Let_syntax in
  let gen =
    List.gen_with_length
      8
      (let%map side = Quickcheck.Generator.of_list Market_data.Side.all
       and size = Int.gen_incl 1 100_000_000
       and price = Int.gen_incl 100_000_000 10_000_000_000_000 in
       side, size, price)
  in
  Quickcheck.test gen ~f:(fun fills ->
    let mk side size price : Fill.t =
      { (fill Buy "0" "0") with
        side
      ; size = Size.of_units size
      ; price = Price.of_units price
      }
    in
    let fills = List.map fills ~f:(fun (s, q, p) -> mk s q p) in
    let pos = List.fold fills ~init:Pnl.Position.flat ~f:Pnl.Position.apply_fill in
    (* close at the last price *)
    let close_px = (List.last_exn fills).price in
    let fills =
      if Size.is_zero pos.size
      then fills
      else
        fills
        @ [ { (mk Buy 0 0) with
              side = (if Size.is_positive pos.size then Sell else Buy)
            ; size = Size.abs pos.size
            ; price = close_px
            }
          ]
    in
    let pos = List.fold fills ~init:Pnl.Position.flat ~f:Pnl.Position.apply_fill in
    assert (Size.is_zero pos.size);
    let cash =
      List.fold fills ~init:0. ~f:(fun acc (f : Fill.t) ->
        acc -. (Size.to_float (Fill.signed_size f) *. Price.to_float f.price))
    in
    (* average-entry prices are truncated to 10^-8 on every fill *)
    let err = Float.abs (Usd.to_float pos.realized -. cash) in
    if Float.(err > 1e-3)
    then raise_s [%message "mismatch" (pos : Pnl.Position.t) (cash : float)])
;;
