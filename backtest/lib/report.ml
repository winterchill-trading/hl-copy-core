open! Core
open Hl_copy_core
module Column = Parquet.Schema.Column
module Result = Backtest.Result

let usd x = `Float (Usd.to_float x)
let ms_to_time ms = Time_ns.of_int_ns_since_epoch (ms * 1_000_000)

let caps_to_json (c : Caps.t) =
  let opt f = Option.value_map ~default:`Null ~f in
  `Assoc
    [ "max_leverage", opt (fun x -> `Float x) c.max_leverage
    ; "max_notional_per_symbol", opt usd c.max_notional_per_symbol
    ; "max_daily_loss", opt usd c.max_daily_loss
    ; ( "allowlist"
      , opt
          (fun l ->
            `List (List.map l ~f:(fun s -> `String (Market_data.Symbol.to_string s))))
          c.allowlist )
    ; "min_order_notional", usd c.min_order_notional
    ]
;;

let mode_to_json : Scale.Mode.t -> Yojson.Safe.t = function
  | Equity_ratio -> `Assoc [ "kind", `String "equity_ratio" ]
  | Multiplier k -> `Assoc [ "kind", `String "multiplier"; "k", `Float k ]
  | Fixed_notional n -> `Assoc [ "kind", `String "fixed_notional"; "usd", usd n ]
;;

let params_to_json (p : Backtest.Params.t) =
  `Assoc
    [ "start_equity", usd p.start_equity
    ; "mode", mode_to_json p.follow.mode
    ; "caps", caps_to_json p.follow.caps
    ; "ioc_slippage_bps", `Int p.follow.slippage_bps
    ; "fill_slippage_bps", `Float p.slippage_bps
    ; "fee_bps", `Float p.fee_bps
    ; "coins_with_specs", `Int (Map.length p.specs)
    ]
;;

let result_to_json ~curve (r : Result.t) =
  `Assoc
    ([ "address", `String (Address.to_string r.leader)
     ; "start_ms", `Int r.start_ms
     ; "end_ms", `Int r.end_ms
     ; "start_equity", usd r.start_equity
     ; "end_equity", usd r.end_equity
     ; "pnl", usd r.pnl
     ; "return", `Float r.return_
     ; "max_drawdown", `Float r.max_drawdown
     ; "realized", usd r.realized
     ; "unrealized", usd r.unrealized
     ; "fees", usd r.fees
     ; "turnover", usd r.turnover
     ; "orders", `Int r.orders
     ; "unfilled_orders", `Int r.unfilled_orders
     ; "leader_changes", `Int r.leader_changes
     ; "changes_traded", `Int r.changes_traded
     ; "changes_capped", `Int r.changes_capped
     ; "changes_skipped", `Int r.changes_skipped
     ; "skip_rate", `Float r.skip_rate
     ; "reasons", `Assoc (List.map r.reasons ~f:(fun (k, n) -> k, `Int n))
     ; "leader_return", `Float r.leader_return
     ; "leader_max_drawdown", `Float r.leader_max_drawdown
     ; "leader_fill_pnl", usd r.leader_fill_pnl
     ; "leader_mtm_pnl", usd r.leader_mtm_pnl
     ; "leader_mtm_return", `Float r.leader_mtm_return
     ; ( "positions"
       , `Assoc
           (List.map r.positions ~f:(fun (s, size) ->
              Market_data.Symbol.to_string s, `Float (Market_data.Size.to_float size))) )
     ]
     @
     if curve
     then
       [ ( "curve"
         , `List
             (List.map r.curve ~f:(fun (p : Backtest.Point.t) ->
                `List [ `Int p.time_ms; `Float p.equity; `Float p.leader_equity ])) )
       ]
     else [])
;;

let to_json ~generated_at ~curve params results =
  `Assoc
    [ ( "generated_at"
      , `String (Time_ns.to_string_iso8601_basic generated_at ~zone:Time_float.Zone.utc) )
    ; "params", params_to_json params
    ; "results", `List (List.map results ~f:(result_to_json ~curve))
    ]
;;

let with_tmp path ~f =
  let tmp = path ^ ".tmp" in
  f tmp;
  Core_unix.rename ~src:tmp ~dst:path
;;

let results_schema : (int * Result.t) Parquet.Schema.t =
  let r f (_, x) = f x in
  let money name (f : Result.t -> Usd.t) =
    Column.float name (r (fun x -> Usd.to_float (f x)))
  in
  Parquet.Schema.create
    [ Column.int32 "rank" fst
    ; Column.utf8 "address" (r (fun x -> Address.to_string x.Result.leader))
    ; Column.timestamp_ns "start" (r (fun x -> ms_to_time x.Result.start_ms))
    ; Column.timestamp_ns "end" (r (fun x -> ms_to_time x.Result.end_ms))
    ; money "start_equity" (fun x -> x.start_equity)
    ; money "end_equity" (fun x -> x.end_equity)
    ; money "pnl" (fun x -> x.pnl)
    ; Column.float "return" (r (fun x -> x.Result.return_))
    ; Column.float "max_drawdown" (r (fun x -> x.Result.max_drawdown))
    ; money "realized" (fun x -> x.realized)
    ; money "unrealized" (fun x -> x.unrealized)
    ; money "fees" (fun x -> x.fees)
    ; money "turnover" (fun x -> x.turnover)
    ; Column.int64 "orders" (r (fun x -> x.Result.orders))
    ; Column.int64 "unfilled_orders" (r (fun x -> x.Result.unfilled_orders))
    ; Column.int64 "leader_changes" (r (fun x -> x.Result.leader_changes))
    ; Column.int64 "changes_traded" (r (fun x -> x.Result.changes_traded))
    ; Column.int64 "changes_capped" (r (fun x -> x.Result.changes_capped))
    ; Column.int64 "changes_skipped" (r (fun x -> x.Result.changes_skipped))
    ; Column.float "skip_rate" (r (fun x -> x.Result.skip_rate))
    ; Column.float "leader_return" (r (fun x -> x.Result.leader_return))
    ; Column.float "leader_max_drawdown" (r (fun x -> x.Result.leader_max_drawdown))
    ; money "leader_fill_pnl" (fun x -> x.leader_fill_pnl)
    ; money "leader_mtm_pnl" (fun x -> x.leader_mtm_pnl)
    ; Column.float "leader_mtm_return" (r (fun x -> x.Result.leader_mtm_return))
    ]
;;

let curves_schema : (Address.t * Backtest.Point.t) Parquet.Schema.t =
  Parquet.Schema.create
    [ Column.utf8 "address" (fun (a, _) -> Address.to_string a)
    ; Column.timestamp_ns "time" (fun (_, (p : Backtest.Point.t)) -> ms_to_time p.time_ms)
    ; Column.float "equity" (fun (_, (p : Backtest.Point.t)) -> p.equity)
    ; Column.float "leader_equity" (fun (_, (p : Backtest.Point.t)) -> p.leader_equity)
    ]
;;

let write_results_parquet path results =
  with_tmp path ~f:(fun tmp ->
    Parquet.Writer.with_file ~schema:results_schema ~compression:`Zstd tmp ~f:(fun w ->
      List.iteri results ~f:(fun i r -> Parquet.Writer.add w (i + 1, r))))
;;

let write_curves_parquet path results =
  with_tmp path ~f:(fun tmp ->
    Parquet.Writer.with_file
      ~schema:curves_schema
      ~compression:`Zstd
      ~row_group_rows:65_536
      tmp
      ~f:(fun w ->
        List.iter results ~f:(fun (r : Result.t) ->
          List.iter r.curve ~f:(fun p -> Parquet.Writer.add w (r.leader, p)))))
;;

let write ~dir ~generated_at ~curve params results =
  Core_unix.mkdir_p dir;
  let json = dir ^/ "backtest.json" in
  Out_channel.write_all
    (json ^ ".tmp")
    ~data:
      (Yojson.Safe.pretty_to_string (to_json ~generated_at ~curve params results) ^ "\n");
  Core_unix.rename ~src:(json ^ ".tmp") ~dst:json;
  write_results_parquet (dir ^/ "results.parquet") results;
  write_curves_parquet (dir ^/ "curves.parquet") results
;;

let date ms =
  if ms = 0
  then "-"
  else
    Time_ns.to_string_iso8601_basic (ms_to_time ms) ~zone:Time_float.Zone.utc
    |> String.sub ~pos:0 ~len:16
;;

let pct x = sprintf "%.2f%%" (100. *. x)
let money x = sprintf "%.2f" (Usd.to_float x)

let summary (r : Result.t) =
  let reasons =
    match r.reasons with
    | [] -> "none"
    | l -> String.concat ~sep:", " (List.map l ~f:(fun (k, n) -> sprintf "%s %d" k n))
  in
  String.concat
    ~sep:"\n"
    [ sprintf "leader          %s" (Address.to_string r.leader)
    ; sprintf "window          %s to %s UTC" (date r.start_ms) (date r.end_ms)
    ; sprintf
        "equity          %s -> %s (pnl %s, %s)"
        (money r.start_equity)
        (money r.end_equity)
        (money r.pnl)
        (pct r.return_)
    ; sprintf "max drawdown    %s" (pct r.max_drawdown)
    ; sprintf
        "realized        %s, unrealized %s, fees %s"
        (money r.realized)
        (money r.unrealized)
        (money r.fees)
    ; sprintf "turnover        %s" (money r.turnover)
    ; sprintf "orders          %d (%d unfilled)" r.orders r.unfilled_orders
    ; sprintf
        "leader changes  %d: %d traded (%d capped), %d skipped (%s)"
        r.leader_changes
        r.changes_traded
        r.changes_capped
        r.changes_skipped
        (pct r.skip_rate)
    ; sprintf "notes           %s" reasons
    ; sprintf
        "leader          curve return %s, max drawdown %s"
        (pct r.leader_return)
        (pct r.leader_max_drawdown)
    ; sprintf
        "leader fills    marked pnl %s (%s of its equity), closed pnl - fees %s"
        (money r.leader_mtm_pnl)
        (pct r.leader_mtm_return)
        (money r.leader_fill_pnl)
    ]
  ^ "\n"
;;

let table results =
  let header =
    "| Rank | Leader | Window (days) | Follower pnl | Return | Max drawdown | Fees | \
     Turnover | Orders | Changes | Skipped | Leader marked return | Leader curve return \
     | Leader curve max drawdown |\n\
     | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: \
     | ---: | ---: |\n"
  in
  header
  ^ String.concat
      (List.mapi results ~f:(fun i (r : Result.t) ->
         sprintf
           "| %d | `%s` | %.1f | %s | %s | %s | %s | %s | %d | %d | %s | %s | %s | %s |\n"
           (i + 1)
           (Address.to_string r.leader)
           (Float.of_int (r.end_ms - r.start_ms) /. 86_400_000.)
           (money r.pnl)
           (pct r.return_)
           (pct r.max_drawdown)
           (money r.fees)
           (money r.turnover)
           r.orders
           r.leader_changes
           (pct r.skip_rate)
           (pct r.leader_mtm_return)
           (pct r.leader_return)
           (pct r.leader_max_drawdown)))
;;
