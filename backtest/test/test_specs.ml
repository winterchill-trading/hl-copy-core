open! Core
open Hl_copy_backtest
open Synthetic

let%expect_test "size decimals inferred from fills" =
  Specs.inferred_sz_decimals
    [ fill ~time_ms:0 btc "0.001" "50000"
    ; fill ~time_ms:0 btc "0.12345" "50000"
    ; fill ~time_ms:0 eth "-2" "4000"
    ; fill ~time_ms:0 eth "0.5" "4000"
    ]
  |> [%sexp_of: int Map.M(Market_data.Symbol).t]
  |> print_s;
  [%expect {| ((BTC 5) (ETH 1)) |}]
;;

let%expect_test "a saved mainnet meta response (trimmed), and meta winning over inference" =
  let meta = Specs.load_meta "fixtures/meta.json" |> ok_exn in
  let inferred = Specs.infer [ fill ~time_ms:0 btc "1" "50000"; fill ~time_ms:0 (Market_data.Symbol.of_string "xyz:NVDA") "0.5" "180" ] in
  Specs.combine ~meta:(Specs.of_meta meta) ~inferred
  |> [%sexp_of: Specs.t]
  |> print_s;
  [%expect {|
    ((BTC ((lot 0.00001) (tick 0.1) (sig_figs (5))))
     (ETH ((lot 0.0001) (tick 0.01) (sig_figs (5))))
     (HYPE ((lot 0.01) (tick 0.0001) (sig_figs (5))))
     (MATIC ((lot 0.1) (tick 0.00001) (sig_figs (5))))
     (xyz:NVDA ((lot 0.1) (tick 0.00001) (sig_figs (5)))))
    |}]
;;
