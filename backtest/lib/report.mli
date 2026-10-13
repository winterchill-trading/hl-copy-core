(** Backtest output: JSON, Parquet and a text summary.

    [<out>/backtest.json]:
    [{"generated_at", "params": {...}, "results": [{...}, ...]}], one result per leader in
    ranking order, each with the fields of {!Backtest.Result.t} (amounts as numbers,
    times in epoch ms, [reasons] as an object) and, when [~curve:true], its [curve] as
    [[time_ms, equity, leader_equity], ...].

    [<out>/results.parquet]: one row per leader: [rank], [address], [start], [end]
    (TIMESTAMP_NS), [start_equity], [end_equity], [pnl], [return], [max_drawdown],
    [realized], [unrealized], [fees], [turnover], [orders], [unfilled_orders],
    [leader_changes], [changes_traded], [changes_capped], [changes_skipped], [skip_rate],
    [leader_return], [leader_max_drawdown], [leader_fill_pnl].

    [<out>/curves.parquet]: [address], [time] (TIMESTAMP_NS), [equity], [leader_equity],
    one row per curve point.

    Both Parquet files are written to [<path>.tmp] and renamed. Amounts are DOUBLE. *)

open! Core

val params_to_json : Backtest.Params.t -> Yojson.Safe.t
val result_to_json : curve:bool -> Backtest.Result.t -> Yojson.Safe.t

val to_json
  :  generated_at:Time_ns.t
  -> curve:bool
  -> Backtest.Params.t
  -> Backtest.Result.t list
  -> Yojson.Safe.t

val write_results_parquet : string -> Backtest.Result.t list -> unit
val write_curves_parquet : string -> Backtest.Result.t list -> unit

(** [backtest.json], [results.parquet] and [curves.parquet] under [dir] (created if
    missing). *)
val write
  :  dir:string
  -> generated_at:Time_ns.t
  -> curve:bool
  -> Backtest.Params.t
  -> Backtest.Result.t list
  -> unit

(** A few lines for one leader: window, equity, pnl, drawdown, costs, orders, skips and the
    leader's own curve over the same window. *)
val summary : Backtest.Result.t -> string

(** A Markdown table, one row per result, in the given order. *)
val table : Backtest.Result.t list -> string
