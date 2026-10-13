open! Core
open! Async
open Hl_copy_core
open Hl_copy_backtest

(* Not a real account: the backtest never trades, and a follow needs a follower distinct
   from the leader. *)
let placeholder_follower = Address.of_string "0x0000000000000000000000000000000000000001"

let address_arg =
  Command.Arg_type.create (fun s ->
    let hex = String.chop_prefix_if_exists (String.lowercase s) ~prefix:"0x" in
    if String.length hex = 40 && String.for_all hex ~f:Char.is_hex_digit
    then Address.of_string ("0x" ^ hex)
    else failwithf "not an address: %s" s ())
;;

let usd_arg = Command.Arg_type.create Usd.of_string

let load_follow = function
  | None ->
    Ok
      (Follower_config.create
         ~follower:placeholder_follower
         ~leader:placeholder_follower
         ())
  | Some path ->
    Or_error.try_with_join (fun () ->
      Follower_config.of_file_contents (In_channel.read_all path))
    |> Or_error.tag ~tag:path
;;

let command =
  Command.async_or_error
    ~summary:"Estimate what a follower would have earned copying recorded leaders"
    ~readme:(fun () ->
      "Reads an hl-leaderboard collection directory (raw fills, account states and \
       portfolio curves), replays each leader's fills through the copy mirror and fills \
       the follower's IOC orders at the leader's price moved by -slippage-bps, paying \
       -fee-bps. With -leader, prints one summary; with -leaders N, ranks every leader \
       by follower pnl and prints the top N. -out writes backtest.json, results.parquet \
       and curves.parquet.")
    (let%map_open.Command dir =
       flag "-dir" (required string) ~doc:"DIR hl-leaderboard collection directory"
     and which =
       choose_one
         ~if_nothing_chosen:Raise
         [ flag "-leader" (optional address_arg) ~doc:"ADDRESS backtest one leader"
           |> map ~f:(Option.map ~f:(fun a -> `One a))
         ; flag
             "-leaders"
             (optional int)
             ~doc:"N rank every leader in DIR and print the top N"
           |> map ~f:(Option.map ~f:(fun n -> `Rank n))
         ]
     and config =
       flag
         "-config"
         (optional string)
         ~doc:
           "FILE follow sexp (mode, caps, IOC slippage) as the API writes it; the leader \
            in it is ignored (default: equity ratio, no caps but the 10 USD minimum \
            order, 20 bps IOC limit)"
     and start_equity =
       flag
         "-equity"
         (optional_with_default (Usd.of_string "10000") usd_arg)
         ~doc:"USD follower starting equity (default 10000)"
     and slippage_bps =
       flag
         "-slippage-bps"
         (optional_with_default Backtest.Params.default_slippage_bps float)
         ~doc:"BPS fill price distance from the leader's price (default 5)"
     and fee_bps =
       flag
         "-fee-bps"
         (optional_with_default Backtest.Params.default_fee_bps float)
         ~doc:"BPS taker fee on each fill's notional (default 4.5)"
     and meta =
       flag
         "-meta"
         (optional string)
         ~doc:
           "FILE saved Hyperliquid meta response for exact size decimals (default: \
            inferred from the fills)"
     and out = flag "-out" (optional string) ~doc:"DIR write JSON and Parquet here" in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       let%bind follow = Deferred.return (load_follow config) in
       let%bind meta =
         Deferred.return
           (match meta with
            | None -> Ok None
            | Some path -> Or_error.map (Specs.load_meta path) ~f:Option.some)
       in
       let%bind inputs =
         match which with
         | `One address ->
           let%map input = Collection.load_one dir address in
           [ input ]
         | `Rank _ -> Collection.load_all dir
       in
       let params =
         { Backtest.Params.follow
         ; start_equity
         ; slippage_bps
         ; fee_bps
         ; specs = Collection.specs ?meta inputs
         }
       in
       let results = Ranking.run params inputs in
       (match which with
        | `One _ -> List.iter results ~f:(fun r -> print_string (Report.summary r))
        | `Rank n -> print_string (Report.table (List.take results n)));
       Option.iter out ~f:(fun dir ->
         Report.write
           ~dir
           ~generated_at:(Time_ns.now ())
           ~curve:
             (match which with
              | `One _ -> true
              | `Rank _ -> false)
           params
           results);
       return ())
;;

let () = Command_unix.run command
