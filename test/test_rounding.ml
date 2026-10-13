open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price

let btc = Rounding.Spec.hyperliquid_perp ~sz_decimals:5
let eth = Rounding.Spec.hyperliquid_perp ~sz_decimals:4
let pepe = Rounding.Spec.hyperliquid_perp ~sz_decimals:0

let%expect_test "hyperliquid specs" =
  print_s [%sexp ([ btc; eth; pepe ] : Rounding.Spec.t list)];
  [%expect
    {|
    (((lot 0.00001) (tick 0.1) (sig_figs (5)))
     ((lot 0.0001) (tick 0.01) (sig_figs (5)))
     ((lot 1) (tick 0.000001) (sig_figs (5))))
    |}]
;;

let%expect_test "sizes truncate toward zero" =
  List.iter [ "0.123456"; "-0.123456"; "0.000009"; "1" ] ~f:(fun s ->
    printf "%s -> %s\n" s (Size.to_string (Rounding.size btc (Size.of_string s))));
  [%expect
    {|
    0.123456 -> 0.12345
    -0.123456 -> -0.12345
    0.000009 -> 0
    1 -> 1
    |}]
;;

let%expect_test "delta below one lot is dropped" =
  let d c t =
    Rounding.delta btc ~current:(Size.of_string c) ~target:(Size.of_string t)
    |> Option.value_map ~default:"none" ~f:Size.to_string
    |> print_endline
  in
  d "0.1" "0.100009";
  d "0.1" "0.2";
  d "0.1" "-0.05";
  [%expect
    {|
    none
    0.1
    -0.15
    |}]
;;

let%expect_test "prices: tick and five significant figures" =
  let p spec s dir =
    printf
      "%s %s -> %s\n"
      s
      (match dir with
       | `Down -> "down"
       | `Up -> "up")
      (Price.to_string (Rounding.price spec (Price.of_string s) ~dir))
  in
  p btc "113377.56" `Down;
  p btc "113377.56" `Up;
  p btc "99999.51" `Up;
  p eth "4123.456" `Down;
  p eth "4123.456" `Up;
  p pepe "0.0123456789" `Down;
  p pepe "0.0123456789" `Up;
  [%expect
    {|
    113377.56 down -> 113377
    113377.56 up -> 113378
    99999.51 up -> 100000
    4123.456 down -> 4123.4
    4123.456 up -> 4123.5
    0.0123456789 down -> 0.012345
    0.0123456789 up -> 0.012346
    |}]
;;

let%expect_test "ioc limits stay inside the slippage bound" =
  let mark = Price.of_string "100000" in
  List.iter Market_data.Side.all ~f:(fun side ->
    let px = Rounding.ioc_limit btc ~side ~mark ~slippage_bps:50 in
    print_s [%message "" (side : Market_data.Side.t) ~limit:(Price.to_string px)]);
  [%expect
    {|
    ((side Buy) (limit 100500))
    ((side Sell) (limit 99500))
    |}]
;;

let%test_unit "rounded prices are within one step and on the requested side" =
  Quickcheck.test
    (Quickcheck.Generator.tuple2
       (Int.gen_incl 1 1_000_000_000_000_000)
       (Int.gen_incl 0 5))
    ~f:(fun (u, sz_decimals) ->
      let spec = Rounding.Spec.hyperliquid_perp ~sz_decimals in
      let p = Price.of_units u in
      let down = Rounding.price spec p ~dir:`Down in
      let up = Rounding.price spec p ~dir:`Up in
      assert (Price.(down <= p && p <= up));
      (* rounding is idempotent *)
      assert (Price.equal (Rounding.price spec down ~dir:`Down) down);
      assert (Price.equal (Rounding.price spec up ~dir:`Up) up))
;;

let%test_unit "rounded sizes are lot multiples no larger than the input" =
  Quickcheck.test
    (Quickcheck.Generator.tuple2
       (Int.gen_incl (-1_000_000_000_000) 1_000_000_000_000)
       (Int.gen_incl 0 5))
    ~f:(fun (u, sz_decimals) ->
      let spec = Rounding.Spec.hyperliquid_perp ~sz_decimals in
      let r = Rounding.size spec (Size.of_units u) in
      assert (Size.(abs r <= abs (of_units u)));
      assert (Size.to_units r % Size.to_units spec.lot = 0))
;;
