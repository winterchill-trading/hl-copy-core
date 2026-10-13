open! Core
open! Async
open Hl_copy_backtest
module Address = Hl_copy_core.Address

let a = Address.of_string "0x00000000000000000000000000000000000000aa"
let b = Address.of_string "0x00000000000000000000000000000000000000bb"
let t0 = 1_790_000_000_000
let hour = 3_600_000

(* One userFillsByTime page; [startPosition] is the position before each fill. *)
let page fills =
  let fill (time, coin, side, sz, px, start) =
    sprintf
      {|{"coin":"%s","px":"%s","sz":"%s","side":"%s","time":%d,"startPosition":"%s","dir":"Trade","closedPnl":"0.0","hash":"0x00","oid":%d,"crossed":true,"fee":"0.0","tid":%d,"feeToken":"USDC"}|}
      coin
      px
      sz
      side
      time
      start
      time
      time
  in
  "[" ^ String.concat ~sep:"," (List.map fills ~f:fill) ^ "]"
;;

let portfolio ~equity =
  sprintf
    {|[["month",{"accountValueHistory":[[%d,"%s"]],"pnlHistory":[[%d,"0.0"]],"vlm":"0.0"}]]|}
    t0
    equity
    t0
;;

let write_collection dir =
  let recv_ts = Time_ns.of_int_ns_since_epoch (t0 * 1_000_000) in
  let module L = Hl_leaderboard in
  (* A: 1 BTC long from 50000 to 55000. B: short ETH from 4000 to 4400. *)
  let%bind () =
    L.Raw_log.append
      (L.Layout.fills dir a)
      ~recv_ts
      (page
         [ t0 + hour, "BTC", "B", "1.0", "50000.0", "0.0"
         ; t0 + (2 * hour), "BTC", "A", "1.0", "55000.0", "1.0"
         ])
  in
  let%bind () =
    L.Raw_log.append
      (L.Layout.fills dir b)
      ~recv_ts
      (page
         [ t0 + hour, "ETH", "A", "10.0", "4000.0", "0.0"
         ; t0 + (2 * hour), "ETH", "B", "10.0", "4400.0", "-10.0"
         ])
  in
  let%bind () =
    L.Raw_log.append (L.Layout.portfolio dir a) ~recv_ts (portfolio ~equity:"100000.0")
  in
  let%bind () =
    L.Raw_log.append (L.Layout.portfolio dir b) ~recv_ts (portfolio ~equity:"200000.0")
  in
  L.Progress.save
    (L.Layout.progress dir)
    { started = recv_ts; candidates = [ a; b ]; collected = [ a; b ] }
;;

(* Without a meta the lots are inferred from these few round sizes (1 BTC, 1 ETH), far
   coarser than the venue's. *)
let meta =
  let asset name sz_decimals =
    { Hl_protocol.Meta.Asset_meta.name = Hl_protocol.Coin.of_string name
    ; sz_decimals
    ; max_leverage = 50
    ; only_isolated = false
    }
  in
  { Hl_protocol.Meta.universe = [ asset "BTC" 5; asset "ETH" 4 ] }
;;

let%expect_test "rank a collection and write the reports" =
  let dir = Filename_unix.temp_dir "backtest" "" in
  let%bind () = write_collection dir in
  let%bind inputs = Collection.load_all dir >>| ok_exn in
  let params =
    { Backtest.Params.follow =
        Hl_copy_core.Follower_config.create
          ~follower:(Address.of_string "0x0000000000000000000000000000000000000001")
          ~leader:a
          ()
    ; start_equity = Hl_copy_core.Usd.of_string "10000"
    ; slippage_bps = 0.
    ; fee_bps = 0.
    ; specs = Collection.specs ~meta inputs
    }
  in
  let results = Ranking.run params inputs in
  print_string (Report.table results);
  (* B: 10 ETH short on 200000 is 0.5 ETH for the follower, losing 0.5 * 400. *)
  [%expect
    {|
    | Rank | Leader | Window (days) | Follower pnl | Return | Max drawdown | Fees | Turnover | Orders | Changes | Skipped | Leader marked return | Leader curve return | Leader curve max drawdown |
    | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | 1 | `0x00000000000000000000000000000000000000aa` | 0.0 | 500.00 | 5.00% | 0.00% | 0.00 | 10500.00 | 2 | 2 | 0.00% | 5.00% | 0.00% | 0.00% |
    | 2 | `0x00000000000000000000000000000000000000bb` | 0.0 | -200.00 | -2.00% | 2.00% | 0.00 | 4200.00 | 2 | 2 | 0.00% | -2.00% | 0.00% | 0.00% |
    |}];
  print_string (Report.summary (List.hd_exn results));
  [%expect
    {|
    leader          0x00000000000000000000000000000000000000aa
    window          2026-09-21T15:13 to 2026-09-21T16:13 UTC
    equity          10000.00 -> 10500.00 (pnl 500.00, 5.00%)
    max drawdown    0.00%
    realized        500.00, unrealized 0.00, fees 0.00
    turnover        10500.00
    orders          2 (0 unfilled)
    leader changes  2: 2 traded (0 capped), 0 skipped (0.00%)
    notes           none
    leader          curve return 0.00%, max drawdown 0.00%
    leader fills    marked pnl 5000.00 (5.00% of its equity), closed pnl - fees 0.00
    |}];
  Report.write ~dir:(dir ^/ "out") ~generated_at:Time_ns.epoch ~curve:true params results;
  let%bind files = Sys.readdir (dir ^/ "out") in
  print_s [%sexp (List.sort (Array.to_list files) ~compare:String.compare : string list)];
  [%expect {| (backtest.json curves.parquet results.parquet) |}];
  let json = Yojson.Safe.from_file (dir ^/ "out" ^/ "backtest.json") in
  let open Yojson.Safe.Util in
  json
  |> member "results"
  |> index 0
  |> member "curve"
  |> Yojson.Safe.to_string
  |> print_endline;
  [%expect {| [[1790003600000,10000.0,100000.0],[1790007200000,10500.0,100000.0]] |}];
  return ()
;;
