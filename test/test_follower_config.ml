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
