open! Core
open Hl_copy_core

let follower = Address.of_string "0x00000000000000000000000000000000000000f1"
let leader = Address.of_string "0xabcdef0123456789abcdef0123456789abcdef01"

let%expect_test "file round trip" =
  let t =
    Follower_config.create
      ~follower
      ~leader
      ~caps:
        { Caps.none with
          max_leverage = Some 5.
        ; max_daily_loss = Some (Usd.of_int 200)
        ; allowlist = Some [ Market_data.Symbol.of_string "BTC" ]
        }
      ()
  in
  let s = Follower_config.to_file_contents t in
  print_string s;
  print_endline (Follower_config.file_name t);
  printf "cloid prefix %x\n" (Follower_config.cloid_prefix t);
  print_endline
    (Cloid.to_string (Cloid.create ~follower:(Follower_config.cloid_prefix t) ~seq:1));
  [%test_result: Follower_config.t]
    (ok_exn (Follower_config.of_file_contents s))
    ~expect:t;
  [%expect
    {|
    ((follower 0x00000000000000000000000000000000000000f1)
     (leader 0xabcdef0123456789abcdef0123456789abcdef01) (mode Equity_ratio)
     (caps
      ((max_leverage (5)) (max_notional_per_symbol ()) (max_daily_loss (200))
       (allowlist ((BTC))) (min_order_notional 10)))
     (slippage_bps 20) (paused false))
    0x00000000000000000000000000000000000000f1-0xabcdef0123456789abcdef0123456789abcdef01.sexp
    cloid prefix abcdef012345678
    0x0abcdef0123456780000000000000001
    |}]
;;

let%expect_test "validation" =
  let bad =
    { (Follower_config.create ~follower ~leader:follower ()) with
      slippage_bps = -1
    ; mode = Multiplier 0.
    }
  in
  print_s
    [%sexp
      (Follower_config.of_file_contents (Follower_config.to_file_contents bad)
       : Follower_config.t Or_error.t)];
  [%expect
    {|
    (Error
     ("invalid follower config"
      (errors
       ("follower equals leader" "slippage_bps outside [0, 1000]"
        "multiplier not positive"))))
    |}]
;;

let%expect_test "algo: written only when not immediate, old files read as immediate" =
  let t = Follower_config.create ~follower ~leader () in
  let twap =
    { t with algo = Twap { duration_ms = 60_000; slices = 6; max_participation = None } }
  in
  print_string (Follower_config.to_file_contents twap);
  [%expect
    {|
    ((follower 0x00000000000000000000000000000000000000f1)
     (leader 0xabcdef0123456789abcdef0123456789abcdef01) (mode Equity_ratio)
     (caps
      ((max_leverage ()) (max_notional_per_symbol ()) (max_daily_loss ())
       (allowlist ()) (min_order_notional 10)))
     (slippage_bps 20) (paused false)
     (algo (Twap (duration_ms 60000) (slices 6) (max_participation ()))))
    |}];
  [%test_result: Follower_config.t]
    (ok_exn (Follower_config.of_file_contents (Follower_config.to_file_contents twap)))
    ~expect:twap;
  (* a file written before [algo] existed *)
  let old =
    Sexp.to_string
      (Follower_config.Stable.V1.sexp_of_t (Follower_config.Stable.V3.to_v1 twap))
  in
  print_s [%sexp ((ok_exn (Follower_config.of_file_contents old)).algo : Exec_algo.t)];
  [%expect {| Immediate |}];
  print_s
    [%sexp
      (Follower_config.of_file_contents
         (Follower_config.to_file_contents
            { twap with algo = Pov { participation = 1.5; max_duration_ms = 0 } })
       : Follower_config.t Or_error.t)];
  [%expect
    {|
    (Error
     ("invalid follower config"
      (errors
       ("algo: participation must be in (0, 1]"
        "algo: max_duration must be positive"))))
    |}]
;;

let%expect_test "stable shapes" =
  print_endline
    (Bin_prot.Shape.eval_to_digest_string Follower_config.Stable.V1.bin_shape_t);
  print_endline
    (Bin_prot.Shape.eval_to_digest_string Follower_config.Stable.V2.bin_shape_t);
  print_endline (Bin_prot.Shape.eval_to_digest_string Exec_algo.Stable.V1.bin_shape_t);
  print_endline
    (Bin_prot.Shape.eval_to_digest_string Follower_config.Stable.V3.bin_shape_t);
  [%expect
    {|
    f2f10032b6d39691e468618d1cf1fa12
    0ab5f263b5dffcb4b25e128558ec1cec
    3a486612be155bbf3411a99a085779a6
    8c8016d52ea59d15928592c4ae9e7593
    |}]
;;

let%expect_test "band: written only when set, V2 files read with no band" =
  let t = Follower_config.create ~follower ~leader () in
  let v2_text =
    Sexp.to_string_hum
      (Follower_config.Stable.V2.sexp_of_t (Follower_config.Stable.V3.to_v2 t))
    ^ "\n"
  in
  (* a default follow writes exactly what V2 wrote *)
  print_s [%sexp (String.equal v2_text (Follower_config.to_file_contents t) : bool)];
  [%expect {| true |}];
  let banded = { t with band = Some No_trade_band.default } in
  print_string (Follower_config.to_file_contents banded);
  [%expect
    {|
    ((follower 0x00000000000000000000000000000000000000f1)
     (leader 0xabcdef0123456789abcdef0123456789abcdef01) (mode Equity_ratio)
     (caps
      ((max_leverage ()) (max_notional_per_symbol ()) (max_daily_loss ())
       (allowlist ()) (min_order_notional 10)))
     (slippage_bps 20) (paused false)
     (band
      ((fee_bps 4.5) (slippage (Fixed_bps 5)) (risk_aversion 20) (vol_bps 300)
       (cost_model Proportional))))
    |}];
  [%test_result: Follower_config.t]
    (ok_exn (Follower_config.of_file_contents (Follower_config.to_file_contents banded)))
    ~expect:banded;
  print_s
    [%sexp
      ((ok_exn (Follower_config.of_file_contents v2_text)).band : No_trade_band.t option)];
  [%expect {| () |}];
  print_s
    [%sexp
      (Follower_config.of_file_contents
         (Follower_config.to_file_contents
            { t with
              band =
                Some
                  { No_trade_band.default with
                    risk_aversion = 0.
                  ; cost_model = Quadratic { impact = -1. }
                  }
            })
       : Follower_config.t Or_error.t)];
  [%expect
    {|
    (Error
     ("invalid follower config"
      (errors
       ("band: risk_aversion not positive"
        "band: impact not a non-negative number"))))
    |}];
  (* the band reaches the mirror's config *)
  let config =
    Follower_config.mirror_config banded ~specs:(Map.empty (module Market_data.Symbol))
  in
  print_s [%sexp (Option.is_some config.band : bool)];
  [%expect {| true |}]
;;
