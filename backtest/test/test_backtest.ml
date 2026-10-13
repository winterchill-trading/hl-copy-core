open! Core
open Hl_copy_core
open Hl_copy_backtest
open Synthetic

let run ?caps ?mode ?slippage_bps ?fee_bps ?start_equity fills =
  Backtest.run (params ?caps ?mode ?slippage_bps ?fee_bps ?start_equity ()) (input fills)
;;

let round_trip =
  [ fill ~time_ms:hour_ms btc "1" "50000"
  ; fill ~time_ms:(2 * hour_ms) btc "-1" "55000" ~closed_pnl:"5000"
  ]
;;

let%expect_test "one round trip, no costs: a tenth of the leader's size and pnl" =
  run round_trip |> print_summary;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 7200000) (start_equity 10000) (end_equity 10500) (pnl 500)
     (return_ 0.05) (max_drawdown 0) (realized 500) (unrealized 0) (fees 0)
     (turnover 10500) (orders 2) (unfilled_orders 0) (leader_changes 2)
     (changes_traded 2) (changes_capped 0) (changes_skipped 0) (skip_rate 0)
     (reasons ()) (leader_return 0) (leader_max_drawdown 0)
     (leader_fill_pnl 5000) (leader_mtm_pnl 5000) (leader_mtm_return 0.05)
     (positions ()) (curve ()))
    |}]
;;

let%expect_test "fees and slippage" =
  (* Buy at 50000 * 1.001 = 50050, sell at 55000 * 0.999 = 54945: realized 0.1 * 4895 =
     489.5, fees 0.00045 * (5005 + 5494.5) = 4.724775. *)
  run ~slippage_bps:10. ~fee_bps:4.5 round_trip |> print_summary;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 7200000) (start_equity 10000) (end_equity 10484.775225)
     (pnl 484.775225) (return_ 0.048478) (max_drawdown 0.000725) (realized 489.5)
     (unrealized 0) (fees 4.724775) (turnover 10499.5) (orders 2)
     (unfilled_orders 0) (leader_changes 2) (changes_traded 2) (changes_capped 0)
     (changes_skipped 0) (skip_rate 0) (reasons ()) (leader_return 0)
     (leader_max_drawdown 0) (leader_fill_pnl 5000) (leader_mtm_pnl 5000)
     (leader_mtm_return 0.05) (positions ()) (curve ()))
    |}]
;;

let%expect_test "slippage beyond the IOC limit leaves every order unfilled" =
  (* The follow's IOC limit is 20 bps through the mark; 30 bps never fills. *)
  run ~slippage_bps:30. round_trip |> print_summary;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 7200000) (start_equity 10000) (end_equity 10000) (pnl 0) (return_ 0)
     (max_drawdown 0) (realized 0) (unrealized 0) (fees 0) (turnover 0)
     (orders 1) (unfilled_orders 1) (leader_changes 2) (changes_traded 1)
     (changes_capped 0) (changes_skipped 0) (skip_rate 0) (reasons ())
     (leader_return 0) (leader_max_drawdown 0) (leader_fill_pnl 5000)
     (leader_mtm_pnl 5000) (leader_mtm_return 0.05) (positions ()) (curve ()))
    |}]
;;

let%expect_test "changes under the minimum notional are skipped" =
  (* 0.001 BTC for the leader is 0.0001 BTC, 5 USD, for the follower. *)
  run
    [ fill ~time_ms:hour_ms btc "0.001" "50000"
    ; fill ~time_ms:(2 * hour_ms) btc "1" "50000"
    ; fill ~time_ms:(3 * hour_ms) btc "-1.001" "50000"
    ]
  |> print_summary;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 10800000) (start_equity 10000) (end_equity 10000) (pnl 0)
     (return_ 0) (max_drawdown 0) (realized 0) (unrealized 0) (fees 0)
     (turnover 10010) (orders 2) (unfilled_orders 0) (leader_changes 3)
     (changes_traded 2) (changes_capped 0) (changes_skipped 1)
     (skip_rate 0.333333) (reasons ((below_min_notional 1))) (leader_return 0)
     (leader_max_drawdown 0) (leader_fill_pnl 0) (leader_mtm_pnl 0)
     (leader_mtm_return 0) (positions ()) (curve ()))
    |}]
;;

let%expect_test "fills of one order are one change at their average price" =
  let fills =
    [ fill ~time_ms:hour_ms eth "1" "4000"
    ; fill ~time_ms:hour_ms eth "3" "4004"
    ; fill ~time_ms:hour_ms btc "0.5" "50000"
    ; fill ~time_ms:(hour_ms + 1) eth "-4" "4010"
    ]
  in
  print_s [%sexp (Leader_change.of_fills fills : Leader_change.t list)];
  [%expect
    {|
    (((time_ms 3600000) (symbol ETH) (size 4) (price 4003) (traded 4) (fills 2))
     ((time_ms 3600000) (symbol BTC) (size 0.5) (price 50000) (traded 0.5)
      (fills 1))
     ((time_ms 3600001) (symbol ETH) (size 0) (price 4010) (traded -4) (fills 1)))
    |}]
;;

let averaging_down =
  [ fill ~time_ms:hour_ms btc "1" "50000"
  ; fill ~time_ms:(2 * hour_ms) btc "1" "40000"
  ; fill ~time_ms:(3 * hour_ms) btc "-2" "50000"
  ]
;;

let%expect_test "equity ratio rescales on the follower's marked equity" =
  (* 0.1 BTC at 50000; at 40000 the follower is worth 9000, so the target for 2 BTC is
     0.18 and it buys 0.08; selling 0.18 at 50000 makes 0.08 * 10000 = 800. The drawdown
     is 1000 / 10000. *)
  let r = run averaging_down in
  print_summary r;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 10800000) (start_equity 10000) (end_equity 10800) (pnl 800)
     (return_ 0.08) (max_drawdown 0.1) (realized 800) (unrealized 0) (fees 0)
     (turnover 17200) (orders 3) (unfilled_orders 0) (leader_changes 3)
     (changes_traded 3) (changes_capped 0) (changes_skipped 0) (skip_rate 0)
     (reasons ()) (leader_return 0) (leader_max_drawdown 0) (leader_fill_pnl 0)
     (leader_mtm_pnl 10000) (leader_mtm_return 0.1) (positions ()) (curve ()))
    |}];
  print_s [%sexp (r.curve : Backtest.Point.t list)];
  [%expect
    {|
    (((time_ms 3600000) (equity 10000) (leader_equity 100000))
     ((time_ms 7200000) (equity 9000.00000001) (leader_equity 100000))
     ((time_ms 10800000) (equity 10800) (leader_equity 100000)))
    |}]
;;

let%expect_test "the daily loss cap closes the follower until the next day" =
  (* At 40000 the day's loss is 1000, over the 500 cap: the follower sells its 0.1 BTC and
     skips the rest of the day. The next day it follows again, at 9000 of equity. *)
  let caps = { Caps.none with max_daily_loss = Some (Usd.of_string "500") } in
  run ~caps (averaging_down @ [ fill ~time_ms:(25 * hour_ms) btc "1" "50000" ])
  |> print_summary;
  [%expect
    {|
    ((leader 0x00000000000000000000000000000000000000aa) (start_ms 3600000)
     (end_ms 90000000) (start_equity 10000) (end_equity 9000) (pnl -1000)
     (return_ -0.1) (max_drawdown 0.1) (realized -1000) (unrealized 0) (fees 0)
     (turnover 13500) (orders 3) (unfilled_orders 0) (leader_changes 4)
     (changes_traded 3) (changes_capped 1) (changes_skipped 0) (skip_rate 0)
     (reasons ((daily_loss 1))) (leader_return 0) (leader_max_drawdown 0)
     (leader_fill_pnl 0) (leader_mtm_pnl 10000) (leader_mtm_return 0.1)
     (positions ((BTC 0.09))) (curve ()))
    |}]
;;
