open! Core
open Hl_copy_core

let words ~n make =
  let t = Bench_state.in_line ~n in
  let symbol = (Bench_state.symbols n).(n / 2) in
  let event = make t symbol in
  (* warm up, then measure one call *)
  ignore (Sys.opaque_identity (Mirror.apply t event) : Mirror.t * Plan.t);
  let before = Gc.minor_words () in
  ignore (Sys.opaque_identity (Mirror.apply t event) : Mirror.t * Plan.t);
  Gc.minor_words () - before
;;

(* Minor words per Mirror.apply of one leader update. Pinned so a change that makes the
   hot path allocate much more shows up in review; the counts move with the symbol count
   (map rebuilds and the other-notional fold are O(log n) and O(n)). The no-trade band
   field added one word to each copy of the mirror record (two copies per update). *)
let%expect_test "allocation of a leader update" =
  List.iter [ 1; 20; 100 ] ~f:(fun n ->
    printf
      "n=%d same=%d grow=%d\n"
      n
      (words ~n Bench_state.same_update)
      (words ~n Bench_state.grow_update));
  [%expect
    {|
    n=1 same=88 grow=190
    n=20 same=124 grow=226
    n=100 same=160 grow=262
    |}]
;;
