open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let btc = Symbol.of_string "BTC"
let eth = Symbol.of_string "ETH"

let config ?(caps = Caps.none) ?(mode = Scale.Mode.Equity_ratio) ?band () =
  { Mirror.Config.follower = 1
  ; mode
  ; caps
  ; slippage_bps = 50
  ; specs =
      Map.of_alist_exn
        (module Symbol)
        [ btc, Rounding.Spec.hyperliquid_perp ~sz_decimals:5
        ; eth, Rounding.Spec.hyperliquid_perp ~sz_decimals:4
        ]
  ; band
  }
;;

let start ?caps ?mode ?band () =
  Mirror.create (config ?caps ?mode ?band ())
  |> Fn.flip Mirror.on_leader_equity (Usd.of_string "100000")
  |> Fn.flip Mirror.on_follower_equity (Usd.of_string "10000")
  |> Mirror.start_day
;;

let leader t symbol size mark =
  let t, plan =
    Mirror.on_leader_position_change
      t
      ~symbol
      ~size:(Size.of_string size)
      ~mark:(Price.of_string mark)
  in
  print_s [%sexp (plan : Plan.t)];
  t
;;

let fill t (o : Plan.Order.t) size =
  Mirror.on_follower_fill
    t
    { Fill.time_ns = 0
    ; symbol = o.symbol
    ; side = o.side
    ; size = Size.of_string size
    ; price = o.limit_px
    ; fee = Usd.zero
    ; closed_pnl = Usd.zero
    ; cloid = Some o.cloid
    }
;;

let show_positions (t : Mirror.t) =
  print_s
    [%message
      ""
        ~follower:(t.follower_positions : Size.t Mirror.Symbol_map.t)
        ~pending:(t.pending : Mirror.Pending.t list)]
;;

let%expect_test "open, duplicate, partial fill, retry, flip" =
  let t = start () in
  let t = leader t btc "1" "100000" in
  [%expect
    {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000000) (symbol BTC) (side Buy)
         (size 0.1) (limit_px 100500) (reduce_only false)))))
     (notes ()))
    |}];
  (* the same update again plans nothing: the buy is still in flight *)
  let t = leader t btc "1" "100000" in
  [%expect {| ((actions ()) (notes ())) |}];
  let first =
    { Plan.Order.cloid = Cloid.create ~follower:1 ~seq:0
    ; symbol = btc
    ; side = Buy
    ; size = Size.of_string "0.1"
    ; limit_px = Price.of_string "100500"
    ; reduce_only = false
    }
  in
  let t = fill t first "0.06" in
  let t = Mirror.on_order_closed t first.cloid in
  show_positions t;
  [%expect {| ((follower ((BTC 0.06))) (pending ())) |}];
  let t = leader t btc "1" "100000" in
  [%expect
    {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000001) (symbol BTC) (side Buy)
         (size 0.04) (limit_px 100500) (reduce_only false)))))
     (notes ()))
    |}];
  (* the leader flips while the 0.04 buy is in flight: cancel it, sell through zero *)
  let t = leader t btc "-0.5" "100000" in
  [%expect
    {|
    ((actions
      ((Cancel (symbol BTC) (cloid 0x00000000000000010000000000000001))
       (Place
        ((cloid 0x00000000000000010000000000000002) (symbol BTC) (side Sell)
         (size 0.11) (limit_px 99500) (reduce_only false)))))
     (notes ()))
    |}];
  show_positions t;
  [%expect
    {|
    ((follower ((BTC 0.06)))
     (pending
      (((cloid 0x00000000000000010000000000000001) (symbol BTC) (remaining 0.04)
        (cancel_requested true))
       ((cloid 0x00000000000000010000000000000002) (symbol BTC) (remaining -0.11)
        (cancel_requested false)))))
    |}]
;;

let%expect_test "leader closes: reduce-only close" =
  let t = start () in
  let t = leader t eth "10" "4000" in
  let o = List.hd_exn t.pending in
  let t =
    Mirror.on_follower_fill
      t
      { Fill.time_ns = 0
      ; symbol = eth
      ; side = Buy
      ; size = o.remaining
      ; price = Price.of_string "4000"
      ; fee = Usd.zero
      ; closed_pnl = Usd.zero
      ; cloid = Some o.cloid
      }
  in
  let _t = leader t eth "0" "4100" in
  [%expect
    {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000000) (symbol ETH) (side Buy)
         (size 1) (limit_px 4020) (reduce_only false)))))
     (notes ()))
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000001) (symbol ETH) (side Sell)
         (size 1) (limit_px 4079.5) (reduce_only true)))))
     (notes ()))
    |}]
;;

let%expect_test "unmanaged symbols, missing marks and specs, small changes" =
  let t = start () in
  (* the follower holds SOL on its own; the leader never did, so it is left alone *)
  let t, plan =
    Mirror.on_resync
      t
      ~leader_state:
        { equity = Usd.of_string "100000"
        ; positions = Map.singleton (module Symbol) btc (Size.of_string "0.5")
        }
      ~follower_state:
        { equity = Usd.of_string "10000"
        ; positions =
            Map.of_alist_exn
              (module Symbol)
              [ Symbol.of_string "SOL", Size.of_string "3"; btc, Size.of_string "0.05" ]
        ; open_orders = []
        }
      ~marks:(Map.empty (module Symbol))
  in
  print_s [%sexp (plan : Plan.t)];
  [%expect {| ((actions ()) (notes (((symbol BTC) (reason No_mark))))) |}];
  let t = leader t (Symbol.of_string "DOGE") "100" "0.2" in
  [%expect {| ((actions ()) (notes (((symbol DOGE) (reason No_spec))))) |}];
  (* 0.5005 -> 0.05005: 0.00005 BTC is 5 USD, under the 10 USD minimum *)
  let _t = leader t btc "0.5005" "100000" in
  [%expect
    {|
    ((actions ())
     (notes
      (((symbol BTC)
        (reason (Capped (Below_min_notional (notional 5) (min 10))))))))
    |}]
;;

let%expect_test "caps show up as notes" =
  let caps = { Caps.none with max_notional_per_symbol = Some (Usd.of_string "2000") } in
  let t = start ~caps () in
  let _t = leader t btc "1" "100000" in
  [%expect
    {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000000) (symbol BTC) (side Buy)
         (size 0.02) (limit_px 100500) (reduce_only false)))))
     (notes
      (((symbol BTC)
        (reason (Capped (Symbol_notional (wanted 10000) (limit 2000))))))))
    |}]
;;

(* Random sessions: leader updates on two symbols, fills and closes of in-flight orders,
   equity moves, rebalances and duplicated events. *)
module Step = struct
  type t =
    | Leader of int * int * int (* symbol index, size units, mark units *)
    | Fill_oldest of int (* percent of the remaining size *)
    | Close_oldest
    | Follower_equity of int
    | Rebalance
    | Repeat_last_leader
  [@@deriving sexp_of]

  let gen =
    let open Quickcheck.Generator.Let_syntax in
    Quickcheck.Generator.weighted_union
      [ ( 4.
        , let%map s = Int.gen_incl 0 1
          and size = Int.gen_incl (-200_000_000) 200_000_000
          and mark = Int.gen_incl 100_000_000_000 12_000_000_000_000 in
          Leader (s, size, mark) )
      ; ( 3.
        , let%map p = Int.gen_incl 1 100 in
          Fill_oldest p )
      ; 1., return Close_oldest
      ; ( 1.
        , let%map e = Int.gen_incl 100_000_000_000 2_000_000_000_000 in
          Follower_equity e )
      ; 1., return Rebalance
      ; 1., return Repeat_last_leader
      ]
  ;;
end

let symbols = [| btc; eth |]

(* Turns abstract steps into events against the current state. *)
let run ?band steps =
  let t = start ?band () in
  let last = ref None in
  List.fold steps ~init:(t, []) ~f:(fun (t, events) step ->
    let event : Mirror.Event.t option =
      match (step : Step.t) with
      | Leader (s, size, mark) ->
        let e =
          Mirror.Event.Leader_position
            { symbol = symbols.(s)
            ; size = Size.of_units size
            ; mark = Price.of_units mark
            }
        in
        last := Some e;
        Some e
      | Repeat_last_leader -> !last
      | Fill_oldest pct ->
        (match t.pending with
         | [] -> None
         | p :: _ ->
           let units = Size.to_units p.remaining * pct / 100 in
           if units = 0
           then None
           else
             Some
               (Follower_fill
                  { time_ns = 0
                  ; symbol = p.symbol
                  ; side = (if units > 0 then Buy else Sell)
                  ; size = Size.of_units (Int.abs units)
                  ; price = Price.of_int 1000
                  ; fee = Usd.zero
                  ; closed_pnl = Usd.zero
                  ; cloid = Some p.cloid
                  }))
      | Close_oldest ->
        (match t.pending with
         | [] -> None
         | p :: _ -> Some (Order_closed p.cloid))
      | Follower_equity e -> Some (Follower_equity (Usd.of_units e))
      | Rebalance -> Some Rebalance
    in
    match event with
    | None -> t, events
    | Some e ->
      let t, plan = Mirror.apply t e in
      t, (e, plan) :: events)
  |> fun (t, events) -> t, List.rev events
;;

let replay events =
  List.fold
    events
    ~init:(start (), [])
    ~f:(fun (t, plans) (e, _) ->
      let t, plan = Mirror.apply t e in
      t, plan :: plans)
  |> fun (t, plans) -> t, List.rev plans
;;

let steps_gen = Quickcheck.Generator.list_with_length 40 Step.gen

let%test_unit "replaying the journal gives the same plans and state" =
  Quickcheck.test steps_gen ~sexp_of:[%sexp_of: Step.t list] ~trials:200 ~f:(fun steps ->
    let t, events = run steps in
    let t', plans = replay events in
    [%test_result: Mirror.t] t' ~expect:t;
    [%test_result: Plan.t list] plans ~expect:(List.map events ~f:snd);
    (* and through bin_io, as the journal stores them *)
    let roundtrip =
      Binable.of_string
        (module Mirror.Stable.V2)
        (Binable.to_string (module Mirror.Stable.V2) t)
    in
    [%test_result: Mirror.t] roundtrip ~expect:t)
;;

let%test_unit "a duplicated leader update places nothing new" =
  Quickcheck.test steps_gen ~sexp_of:[%sexp_of: Step.t list] ~trials:200 ~f:(fun steps ->
    let t, events = run steps in
    match
      List.find (List.rev events) ~f:(fun (e, _) ->
        match e with
        | Leader_position _ -> true
        | _ -> false)
    with
    | None -> ()
    | Some (e, _) ->
      let t, _ = Mirror.apply t e in
      let _, again = Mirror.apply t e in
      [%test_result: Plan.Order.t list] (Plan.places again) ~expect:[])
;;

let%test_unit "after every order fills, the follower sits on the target and a rebalance \
               places nothing"
  =
  Quickcheck.test steps_gen ~sexp_of:[%sexp_of: Step.t list] ~trials:200 ~f:(fun steps ->
    let t, _ = run steps in
    let t, _ = Mirror.rebalance t in
    (* fill every live order completely, close the cancelled ones *)
    let t =
      List.fold t.pending ~init:t ~f:(fun t (p : Mirror.Pending.t) ->
        if p.cancel_requested
        then Mirror.on_order_closed t p.cloid
        else
          Mirror.on_follower_fill
            t
            { time_ns = 0
            ; symbol = p.symbol
            ; side = (if Size.is_positive p.remaining then Buy else Sell)
            ; size = Size.abs p.remaining
            ; price = Price.of_int 1000
            ; fee = Usd.zero
            ; closed_pnl = Usd.zero
            ; cloid = Some p.cloid
            })
    in
    [%test_result: Mirror.Pending.t list] t.pending ~expect:[];
    let _, plan = Mirror.rebalance t in
    [%test_result: Plan.Order.t list] (Plan.places plan) ~expect:[];
    Array.iter symbols ~f:(fun symbol ->
      match Mirror.target t symbol with
      | None, _ -> ()
      | Some target, _ ->
        let pos =
          Option.value (Map.find t.follower_positions symbol) ~default:Size.zero
        in
        let spec = Map.find_exn t.config.specs symbol in
        let mark = Map.find_exn t.marks symbol in
        (* within one lot, or within the minimum order notional *)
        let gap = Size.(abs (target - pos)) in
        assert (
          Size.(gap < spec.lot)
          || Usd.(Caps.notional gap mark < t.config.caps.min_order_notional))))
;;

(* {2 No-trade band} *)

let zero_band = { No_trade_band.default with fee_bps = 0.; slippage = Fixed_bps 0. }

let%test_unit "an empty band plans exactly what no band plans" =
  Quickcheck.test steps_gen ~sexp_of:[%sexp_of: Step.t list] ~trials:300 ~f:(fun steps ->
    let t, events = run steps in
    let t', events' = run ~band:zero_band steps in
    [%test_result: (Mirror.Event.t * Plan.t) list] events' ~expect:events;
    [%test_result: Mirror.t] { t' with config = { t'.config with band = None } } ~expect:t)
;;

let band_gen =
  let open Quickcheck.Generator.Let_syntax in
  let%map fee = Float.gen_incl 0. 10.
  and slippage = Float.gen_incl 0. 20.
  and risk_aversion = Float.gen_incl 1. 200.
  and vol_bps = Float.gen_incl 50. 500. in
  { No_trade_band.default with fee_bps = fee; slippage = Fixed_bps slippage; risk_aversion; vol_bps }
;;

let%test_unit "with a band: replays are identical and duplicated updates place nothing" =
  Quickcheck.test
    (Quickcheck.Generator.both band_gen steps_gen)
    ~sexp_of:[%sexp_of: No_trade_band.t * Step.t list]
    ~trials:200
    ~f:(fun (band, steps) ->
      let t, events = run ~band steps in
      let t', plans =
        List.fold events ~init:(start ~band (), []) ~f:(fun (t, plans) (e, _) ->
          let t, plan = Mirror.apply t e in
          t, plan :: plans)
      in
      [%test_result: Mirror.t] t' ~expect:t;
      [%test_result: Plan.t list] (List.rev plans) ~expect:(List.map events ~f:snd);
      match
        List.find (List.rev events) ~f:(fun (e, _) ->
          match e with
          | Leader_position _ -> true
          | _ -> false)
      with
      | None -> ()
      | Some (e, _) ->
        let t, _ = Mirror.apply t e in
        let _, again = Mirror.apply t e in
        [%test_result: Plan.Order.t list] (Plan.places again) ~expect:[])
;;

let%test_unit "with a proportional band, a rebalance after every fill places nothing and \
               the gap is at most the half-width or a lot"
  =
  Quickcheck.test
    (Quickcheck.Generator.both band_gen steps_gen)
    ~sexp_of:[%sexp_of: No_trade_band.t * Step.t list]
    ~trials:200
    ~f:(fun (band, steps) ->
      let t, _ = run ~band steps in
      let t, _ = Mirror.rebalance t in
      let t =
        List.fold t.pending ~init:t ~f:(fun t (p : Mirror.Pending.t) ->
          if p.cancel_requested
          then Mirror.on_order_closed t p.cloid
          else
            Mirror.on_follower_fill
              t
              { time_ns = 0
              ; symbol = p.symbol
              ; side = (if Size.is_positive p.remaining then Buy else Sell)
              ; size = Size.abs p.remaining
              ; price = Price.of_int 1000
              ; fee = Usd.zero
              ; closed_pnl = Usd.zero
              ; cloid = Some p.cloid
              })
      in
      let _, plan = Mirror.rebalance t in
      [%test_result: Plan.Order.t list] (Plan.places plan) ~expect:[];
      let cost_bps = No_trade_band.cost_bps band ~estimate:None in
      let h =
        No_trade_band.half_width band ~cost_bps ~equity:(Usd.to_float t.follower_equity)
      in
      Array.iter symbols ~f:(fun symbol ->
        match Mirror.target t symbol with
        | None, _ -> ()
        | Some target, _ ->
          let pos =
            Option.value (Map.find t.follower_positions symbol) ~default:Size.zero
          in
          let spec = Map.find_exn t.config.specs symbol in
          let mark = Map.find_exn t.marks symbol in
          let gap = Size.(abs (target - pos)) in
          let gap_usd = Usd.to_float (Caps.notional gap mark) in
          let lot_usd = Usd.to_float (Caps.notional spec.lot mark) in
          let min_usd = Usd.to_float t.config.caps.min_order_notional in
          (* the edge, plus what lot truncation and the minimum order leave *)
          assert (Float.(gap_usd <= h +. lot_usd +. min_usd +. 0.01))))
;;

let%expect_test "a band note says what was held back" =
  let t = start ~band:No_trade_band.default () in
  (* 10% of the leader's 1 BTC at 100,000 is 10,000 USD, well past the 528 USD edge *)
  let t = leader t btc "1" "100000" in
  [%expect {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000000) (symbol BTC) (side Buy)
         (size 0.09472) (limit_px 100500) (reduce_only false)))))
     (notes ()))
    |}];
  (* fill it, then a small leader change stays inside the band *)
  let t =
    List.fold t.pending ~init:t ~f:(fun t (p : Mirror.Pending.t) ->
      Mirror.on_follower_fill
        t
        { time_ns = 0
        ; symbol = p.symbol
        ; side = Buy
        ; size = p.remaining
        ; price = Price.of_int 100000
        ; fee = Usd.zero
        ; closed_pnl = Usd.zero
        ; cloid = Some p.cloid
        })
  in
  let t = leader t btc "0.995" "100000" in
  [%expect {|
    ((actions ())
     (notes
      (((symbol BTC)
        (reason (Within_band (gap 0.00478) (band 527.77777778) (saved 0.4541)))))))
    |}];
  (* the leader closes: the follower closes in full *)
  let _ = leader t btc "0" "100000" in
  [%expect {|
    ((actions
      ((Place
        ((cloid 0x00000000000000010000000000000001) (symbol BTC) (side Sell)
         (size 0.09472) (limit_px 99500) (reduce_only true)))))
     (notes ()))
    |}]
;;
