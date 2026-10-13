open! Core
open Hl_copy_core
open Hl_copy_backtest
open Synthetic
module Size = Market_data.Size

(* Random histories in BTC and ETH: sizes in leader lots, prices within 20% of a base,
   then one closing fill per coin so the leader ends flat. *)
let history_generator =
  let open Quickcheck.Generator.Let_syntax in
  let step =
    let%map is_btc = Bool.quickcheck_generator
    and lots = Int.gen_incl (-300) 300
    and move = Int.gen_incl (-20) 20 in
    if is_btc
    then btc, Size.of_units (lots * 1_000_000), 50_000 + (move * 500)
    else eth, Size.of_units (lots * 10_000_000), 4_000 + (move * 40)
  in
  let%map steps = List.gen_with_length 30 step in
  let fills, positions, _ =
    List.fold
      steps
      ~init:([], Map.empty (module Market_data.Symbol), 0)
      ~f:(fun (fills, positions, i) (symbol, size, price) ->
        if Size.is_zero size
        then fills, positions, i
        else (
          let time_ms = (i + 1) * hour_ms in
          let f = fill ~time_ms symbol (Size.to_string size) (Int.to_string price) in
          let positions =
            Map.update positions symbol ~f:(fun p ->
              Size.(Option.value p ~default:zero + size))
          in
          f :: fills, positions, i + 1))
  in
  let closes =
    Map.to_alist positions
    |> List.filter_map ~f:(fun (symbol, pos) ->
      if Size.is_zero pos
      then None
      else (
        let price = if Market_data.Symbol.equal symbol btc then "50000" else "4000" in
        Some (fill ~time_ms:(100 * hour_ms) symbol (Size.to_string (Size.neg pos)) price)))
  in
  List.rev fills @ closes
;;

let%test_unit "a leader that ends flat leaves the follower flat, and fees follow turnover"
  =
  Quickcheck.test
    history_generator
    ~sexp_of:[%sexp_of: Fill.t list]
    ~trials:200
    ~f:(fun fills ->
      let r = Backtest.run (params ~slippage_bps:2. ~fee_bps:4.5 ()) (input fills) in
      [%test_result: (Market_data.Symbol.t * Size.t) list] r.positions ~expect:[];
      (* Each fill's fee is rounded to 10^-8 on its own. *)
      let expected = Usd.to_float r.turnover *. 4.5 /. 10_000. in
      let tolerance = 1e-8 *. Float.of_int (r.orders + 1) in
      if Float.(abs (Usd.to_float r.fees -. expected) > tolerance)
      then raise_s [%message "fees" (r.fees : Usd.t) (expected : float)];
      (match List.last r.curve with
       | None -> ()
       | Some last ->
         [%test_result: float]
           (Float.round_decimal last.equity ~decimal_digits:6)
           ~expect:(Float.round_decimal (Usd.to_float r.end_equity) ~decimal_digits:6));
      assert (r.changes_traded + r.changes_skipped <= r.leader_changes))
;;
