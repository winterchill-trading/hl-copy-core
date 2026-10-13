open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let spec = Rounding.Spec.hyperliquid_perp ~sz_decimals:5
let btc = Symbol.of_string "BTC"

let ctx ?(current = "0") ?(equity = "10000") ?(other = "0") ?(daily_pnl = "0") () =
  { Caps.Context.symbol = btc
  ; mark = Price.of_string "100000"
  ; current = Size.of_string current
  ; equity = Usd.of_string equity
  ; other_notional = Usd.of_string other
  ; daily_pnl = Usd.of_string daily_pnl
  }
;;

let run caps ctx target =
  print_s
    [%sexp (Caps.apply caps ctx ~spec ~target:(Size.of_string target) : Caps.Decision.t)]
;;

let%expect_test "no caps: the order is the lot-rounded difference" =
  run Caps.none (ctx ()) "0.0123456";
  [%expect {| ((target 0.0123456) (order (0.01234)) (reasons ())) |}]
;;

let%expect_test "allowlist" =
  run
    { Caps.none with allowlist = Some [ Symbol.of_string "ETH" ] }
    (ctx ~current:"0.1" ())
    "1";
  [%expect {| ((target 0.1) (order ()) (reasons (Not_allowlisted))) |}]
;;

let%expect_test "daily loss: reduce and close only" =
  let caps = { Caps.none with max_daily_loss = Some (Usd.of_string "100") } in
  run caps (ctx ~current:"0.1" ~daily_pnl:"-150" ()) "0.2";
  run caps (ctx ~current:"0.1" ~daily_pnl:"-150" ()) "0.05";
  run caps (ctx ~current:"0.1" ~daily_pnl:"-150" ()) "-0.1";
  run caps (ctx ~current:"0.1" ~daily_pnl:"-99" ()) "0.2";
  [%expect
    {|
    ((target 0.1) (order ())
     (reasons ((Daily_loss_reached (daily_pnl -150) (limit 100)))))
    ((target 0.05) (order (-0.05)) (reasons ()))
    ((target 0) (order (-0.1))
     (reasons ((Daily_loss_reached (daily_pnl -150) (limit 100)))))
    ((target 0.2) (order (0.1)) (reasons ()))
    |}]
;;

let%expect_test "notional per symbol clamps growth but never forces a reduction" =
  let caps = { Caps.none with max_notional_per_symbol = Some (Usd.of_string "5000") } in
  run caps (ctx ()) "0.2";
  run caps (ctx ~current:"0.08" ()) "-0.2";
  (* already above the cap (the mark rose): hold, do not sell down *)
  run caps (ctx ~current:"0.08" ()) "0.1";
  [%expect
    {|
    ((target 0.05) (order (0.05))
     (reasons ((Symbol_notional (wanted 20000) (limit 5000)))))
    ((target -0.05) (order (-0.13))
     (reasons ((Symbol_notional (wanted 20000) (limit 5000)))))
    ((target 0.08) (order ())
     (reasons ((Symbol_notional (wanted 10000) (limit 5000)))))
    |}]
;;

let%expect_test "leverage counts the other symbols" =
  let caps = { Caps.none with max_leverage = Some 3. } in
  run caps (ctx ~other:"20000" ()) "1";
  run caps (ctx ~other:"40000" ()) "1";
  [%expect
    {|
    ((target 0.1) (order (0.1)) (reasons ((Leverage (wanted 12) (limit 3)))))
    ((target 0) (order ()) (reasons ((Leverage (wanted 14) (limit 3)))))
    |}]
;;

let%expect_test "minimum order notional, except for a full close" =
  run Caps.none (ctx ~current:"0.1" ()) "0.10005";
  run Caps.none (ctx ~current:"0.00005" ()) "0";
  [%expect
    {|
    ((target 0.10005) (order ())
     (reasons ((Below_min_notional (notional 5) (min 10)))))
    ((target 0) (order (-0.00005)) (reasons ()))
    |}]
;;

let%test_unit "caps never grow the position beyond the uncapped target" =
  let open Quickcheck.Generator.Let_syntax in
  Quickcheck.test
    (let%map current = Int.gen_incl (-100_000_000) 100_000_000
     and target = Int.gen_incl (-100_000_000) 100_000_000
     and daily = Int.gen_incl (-100_000_000_000) 100_000_000_000
     and lev = Float.gen_incl 0.5 20.
     and per_symbol = Int.gen_incl 0 2_000_000_000_000 in
     current, target, daily, lev, per_symbol)
    ~f:(fun (current, target, daily, lev, per_symbol) ->
      let caps =
        { Caps.none with
          max_leverage = Some lev
        ; max_notional_per_symbol = Some (Usd.of_units per_symbol)
        ; max_daily_loss = Some (Usd.of_int 100)
        }
      in
      let ctx =
        { (ctx ()) with current = Size.of_units current; daily_pnl = Usd.of_units daily }
      in
      let d = Caps.apply caps ctx ~spec ~target:(Size.of_units target) in
      let final =
        Option.value_map d.order ~default:ctx.current ~f:(Size.( + ) ctx.current)
      in
      (* the final position is no further from zero than both the target and the current
         position on its side *)
      assert (Size.(abs final <= max (abs (of_units target)) (abs ctx.current)));
      Option.iter d.order ~f:(fun o ->
        assert (Size.to_units o % Size.to_units spec.lot = 0)))
;;
