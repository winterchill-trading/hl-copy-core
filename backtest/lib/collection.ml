open! Core
open! Async
module Dataset = Hl_leaderboard.Dataset

let now_ms (leader : Dataset.Leader.t) =
  match leader.state, List.last leader.fills with
  | Some (time, _), _ -> Time_ns.to_int_ns_since_epoch time / 1_000_000
  | None, Some fill -> fill.time
  | None, None -> 0
;;

let input leader = Input.of_leader ~now_ms:(now_ms leader) leader

let load_all dir =
  let%map.Deferred.Or_error dataset = Dataset.load dir in
  List.filter_map dataset.leaders ~f:(fun (l : Dataset.Leader.t) ->
    if List.is_empty l.fills then None else Some (input l))
;;

let load_one dir address =
  let%map.Deferred.Or_error leader = Dataset.load_leader dir address in
  input leader
;;

let specs ?meta inputs =
  let inferred = Specs.infer (List.concat_map inputs ~f:(fun (i : Input.t) -> i.fills)) in
  match meta with
  | None -> inferred
  | Some meta -> Specs.combine ~meta:(Specs.of_meta meta) ~inferred
;;
