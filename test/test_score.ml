open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let hour = 3_600_000_000_000

let fill ?(symbol = "BTC") ~h side size ~pnl ~fee : Fill.t =
  { time_ns = h * hour
  ; symbol = Symbol.of_string symbol
  ; side
  ; size = Size.of_string size
  ; price = Price.of_int 100
  ; fee = Usd.of_string fee
  ; closed_pnl = Usd.of_string pnl
  ; cloid = None
  }
;;

let point h e = { Score.Equity_point.time_ns = h * hour; equity = Usd.of_string e }

let%expect_test "a small history" =
  let fills =
    [ fill ~h:0 Buy "1" ~pnl:"0" ~fee:"1"
    ; fill ~h:2 Sell "1" ~pnl:"50" ~fee:"1"
    ; fill ~h:3 Sell "1" ~pnl:"0" ~fee:"1"
    ; fill ~h:4 Buy "2" ~pnl:"-20" ~fee:"1" (* closes the short and flips long *)
    ; fill ~h:7 Sell "1" ~pnl:"30" ~fee:"1"
    ; fill ~symbol:"ETH" ~h:5 Buy "3" ~pnl:"0" ~fee:"1" (* still open *)
    ]
  in
  let equity =
    [ point 0 "1000"; point 2 "1048"; point 4 "1000"; point 6 "990"; point 8 "1060" ]
  in
  print_s [%sexp (Score.round_trips fills : Score.Trip.t list)];
  print_s [%sexp (Score.compute ~fills ~equity () : Score.t)];
  [%expect
    {|
    (((symbol BTC) (opened_ns 0) (closed_ns 7200000000000) (pnl 48))
     ((symbol BTC) (opened_ns 10800000000000) (closed_ns 14400000000000)
      (pnl -22))
     ((symbol BTC) (opened_ns 14400000000000) (closed_ns 25200000000000)
      (pnl 29)))
    ((pnl 54) (return_ 0.054) (max_drawdown 0.055343511450381681)
     (win_rate 0.66666666666666663) (trade_count 3) (avg_hold_ns 7200000000000)
     (consistency 0.5) (score 0.0057387881679389309))
    |}]
;;

let%expect_test "empty inputs" =
  print_s [%sexp (Score.compute ~fills:[] ~equity:[] () : Score.t)];
  [%expect
    {|
    ((pnl 0) (return_ 0) (max_drawdown 0) (win_rate 0) (trade_count 0)
     (avg_hold_ns 0) (consistency 0) (score 0))
    |}]
;;

let gen_inputs =
  let open Quickcheck.Generator.Let_syntax in
  let%map fills = List.quickcheck_generator Fill.quickcheck_generator
  and equity =
    List.quickcheck_generator
      (let%map time_ns = Int.gen_incl 0 1_000_000_000_000
       and e = Int.gen_incl (-100_000_000_000) 10_000_000_000_000 in
       { Score.Equity_point.time_ns; equity = Usd.of_units e })
  in
  fills, equity
;;

let%test_unit "ratios stay in [0, 1], counts are bounded, order does not matter" =
  Quickcheck.test
    (Quickcheck.Generator.both gen_inputs Quickcheck.Generator.size)
    ~f:(fun ((fills, equity), seed) ->
      let s = Score.compute ~fills ~equity () in
      let in_unit x = Float.(x >= 0. && x <= 1.) in
      assert (in_unit s.max_drawdown);
      assert (in_unit s.win_rate);
      assert (in_unit s.consistency);
      assert (s.trade_count <= List.length fills);
      assert (s.avg_hold_ns >= 0);
      let shuffle l = List.permute ~random_state:(Random.State.make [| seed |]) l in
      [%test_result: Score.t]
        (Score.compute ~fills:(shuffle fills) ~equity:(shuffle equity) ())
        ~expect:s)
;;

let%test_unit "a curve that never falls has no drawdown" =
  Quickcheck.test
    (List.quickcheck_generator (Int.gen_incl 1 1_000_000_000))
    ~f:(fun steps ->
      let _, points =
        List.fold_mapi steps ~init:1_000_000_000 ~f:(fun i e step ->
          e + step, { Score.Equity_point.time_ns = i; equity = Usd.of_units (e + step) })
      in
      [%test_result: float] (Score.max_drawdown points) ~expect:0.)
;;
