open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price

let band = No_trade_band.default
let equity = Usd.of_string "10000"
let mark = Price.of_string "100000"

let decide ?(band = band) current target =
  let cost_bps = No_trade_band.cost_bps band ~estimate:None in
  print_s
    [%sexp
      (No_trade_band.decide
         band
         ~cost_bps
         ~equity
         ~mark
         ~current:(Size.of_string current)
         ~target:(Size.of_string target)
       : No_trade_band.Decision.t)]
;;

let%expect_test "band edges in closed form" =
  let cost_bps = No_trade_band.cost_bps band ~estimate:None in
  (* (4.5 + 5) bp / (20 * 0.03^2) = 5.28% of equity *)
  printf
    "cost %.1f bp, half-width %.2f USD, step %.2f\n"
    cost_bps
    (No_trade_band.half_width band ~cost_bps ~equity:10_000.)
    (No_trade_band.step_fraction band);
  [%expect {| cost 9.5 bp, half-width 527.78 USD, step 1.00 |}];
  (* Impact slippage: the estimate when one is known, else the fallback *)
  let impact = { band with slippage = Impact { fallback_bps = 8. } } in
  printf
    "%.1f %.1f %.1f\n"
    (No_trade_band.cost_bps impact ~estimate:None)
    (No_trade_band.cost_bps impact ~estimate:(Some 2.))
    (No_trade_band.cost_bps impact ~estimate:(Some (-3.)));
  [%expect {| 12.5 6.5 4.5 |}];
  let quadratic = { band with cost_model = Quadratic { impact = 0.009 } } in
  printf "step %.3f\n" (No_trade_band.step_fraction quadratic);
  [%expect {| step 0.500 |}]
;;

let%expect_test "decisions" =
  (* a 0.004 BTC gap is 400 USD, inside the 528 USD half-width *)
  decide "0.01" "0.014";
  [%expect {| (Skip (gap 0.004) (band 527.77777778) (saved 0.38)) |}];
  (* 0.01 BTC is 1000 USD: trade to the near edge, 0.00528 (the half-width) short of the
     target *)
  decide "0" "0.01";
  [%expect {| (Trade 0.00472222) |}];
  decide "0.02" "0.01";
  [%expect {| (Trade 0.01527778) |}];
  (* a leader close is copied in full, however small *)
  decide "0.003" "0";
  [%expect {| (Trade 0) |}];
  (* quadratic costs: same edge, part of the way past it *)
  decide ~band:{ band with cost_model = Quadratic { impact = 0.009 } } "0" "0.01";
  [%expect {| (Trade 0.00236111) |}];
  (* an empty band returns the target itself *)
  decide ~band:{ band with fee_bps = 0.; slippage = Fixed_bps 0. } "0" "0.00001";
  [%expect {| (Trade 0.00001) |}]
;;

let bps = Float.gen_incl 0. 100.

let%test_unit "the band widens with cost and narrows with risk aversion and volatility" =
  Quickcheck.test
    (Quickcheck.Generator.tuple4
       bps
       bps
       (Float.gen_incl 0.1 100.)
       (Float.gen_incl 1. 1000.))
    ~sexp_of:[%sexp_of: float * float * float * float]
    ~f:(fun (c1, c2, gamma, vol) ->
      let lo, hi = Float.min c1 c2, Float.max c1 c2 in
      let t = { band with risk_aversion = gamma; vol_bps = vol } in
      let h c = No_trade_band.half_width t ~cost_bps:c ~equity:10_000. in
      assert (Float.( <= ) (h lo) (h hi));
      let wider_risk = { t with risk_aversion = gamma *. 2. } in
      assert (
        Float.( <= )
          (No_trade_band.half_width wider_risk ~cost_bps:hi ~equity:10_000.)
          (h hi));
      let more_vol = { t with vol_bps = vol *. 2. } in
      assert (
        Float.( <= )
          (No_trade_band.half_width more_vol ~cost_bps:hi ~equity:10_000.)
          (h hi)))
;;

let%test_unit "a gap skipped at some cost is skipped at every higher cost" =
  Quickcheck.test
    (Quickcheck.Generator.tuple4
       bps
       bps
       (Int.gen_incl (-2_000_000) 2_000_000)
       (Int.gen_incl (-2_000_000) 2_000_000))
    ~sexp_of:[%sexp_of: float * float * int * int]
    ~f:(fun (c1, c2, current, target) ->
      let lo, hi = Float.min c1 c2, Float.max c1 c2 in
      let d c =
        No_trade_band.decide
          band
          ~cost_bps:c
          ~equity
          ~mark
          ~current:(Size.of_units current)
          ~target:(Size.of_units target)
      in
      match d lo, d hi with
      | Skip _, Trade _ -> failwith "skipped at the lower cost only"
      | Trade a, Trade b ->
        (* a higher cost trades less far toward the target *)
        let moved x = Int.abs (Size.to_units x - current) in
        assert (moved b <= moved a)
      | _, Skip _ -> ())
;;
