(* Mirror.apply of one leader position update, on a follower already in line with the
   leader on [n] symbols. [same] repeats the current leader position (the plan is empty,
   the common case for a duplicated or replayed update); [grow] grows it by 10% (one IOC
   order is planned). The state is not threaded between runs, so every run does the same
   work. *)

open! Core
open Core_bench
open Hl_copy_core

let case ~n name make =
  let t = Hl_copy_core_test.Bench_state.in_line ~n in
  let symbol = (Hl_copy_core_test.Bench_state.symbols n).(n / 2) in
  let event = make t symbol in
  Bench.Test.create ~name:(sprintf "%s n=%d" name n) (fun () ->
    ignore (Sys.opaque_identity (Mirror.apply t event) : Mirror.t * Plan.t))
;;

let () =
  let module S = Hl_copy_core_test.Bench_state in
  Command_unix.run
    (Bench.make_command
       (List.concat_map [ 1; 20; 100 ] ~f:(fun n ->
          [ case ~n "same" S.same_update; case ~n "grow" S.grow_update ])))
;;
