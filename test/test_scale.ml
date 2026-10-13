open! Core
open Hl_copy_core
module Size = Market_data.Size

let usd = Usd.of_string
let size = Size.of_string

let show ~leader_size ~leader_equity ~follower_equity mode =
  let s =
    Scale.target_size
      ~leader_size:(size leader_size)
      ~leader_equity:(usd leader_equity)
      ~follower_equity:(usd follower_equity)
      ~mark:(Market_data.Price.of_string "50000")
      ~mode
  in
  print_s [%message "" (mode : Scale.Mode.t) ~target:(Size.to_string s)]
;;

let%expect_test "modes" =
  show ~leader_size:"2" ~leader_equity:"100000" ~follower_equity:"1000" Equity_ratio;
  show ~leader_size:"-2" ~leader_equity:"100000" ~follower_equity:"1000" Equity_ratio;
  (* half the leader's leverage *)
  show ~leader_size:"2" ~leader_equity:"100000" ~follower_equity:"1000" (Multiplier 0.5);
  (* 500 USD at a 50000 mark, whatever the leader's size *)
  show
    ~leader_size:"2"
    ~leader_equity:"100000"
    ~follower_equity:"1000"
    (Fixed_notional (usd "500"));
  show
    ~leader_size:"-0.001"
    ~leader_equity:"100000"
    ~follower_equity:"1000"
    (Fixed_notional (usd "500"));
  show ~leader_size:"2" ~leader_equity:"0" ~follower_equity:"1000" Equity_ratio;
  show
    ~leader_size:"2"
    ~leader_equity:"100"
    ~follower_equity:"1000"
    (Multiplier Float.nan);
  [%expect
    {|
    ((mode Equity_ratio) (target 0.02))
    ((mode Equity_ratio) (target -0.02))
    ((mode (Multiplier 0.5)) (target 0.01))
    ((mode (Fixed_notional 500)) (target 0.01))
    ((mode (Fixed_notional 500)) (target -0.01))
    ((mode Equity_ratio) (target 0))
    ((mode (Multiplier NAN)) (target 0))
    |}]
;;

let%test_unit "sign follows the leader and the target is at most the leader's size \
               scaled by the capital ratio"
  =
  Quickcheck.test
    (let open Quickcheck.Generator.Let_syntax in
     (* Equities from 1 USD to 1e9 USD and follower capital up to 1000 times the leader's
        keep every result inside Fixed_decimal's range. *)
     let%bind le = Int.gen_incl 100_000_000 100_000_000_000_000_000 in
     let%map l = Int.gen_incl (-1_000_000_000_000) 1_000_000_000_000
     and fe =
       Int.gen_incl
         0
         (if le > 100_000_000_000_000 then 100_000_000_000_000_000 else le * 1000)
     and mode = Scale.Mode.quickcheck_generator in
     l, le, fe, mode)
    ~f:(fun (l, le, fe, mode) ->
      let leader_size = Size.of_units l in
      let t =
        Scale.target_size
          ~leader_size
          ~leader_equity:(Usd.of_units le)
          ~follower_equity:(Usd.of_units fe)
          ~mark:(Market_data.Price.of_int 100)
          ~mode
      in
      assert (
        Size.is_zero t || Bool.equal (Size.is_positive t) (Size.is_positive leader_size));
      match mode with
      | Equity_ratio -> if fe <= le then assert (Size.(abs t <= abs leader_size))
      | Multiplier _ | Fixed_notional _ -> ())
;;
