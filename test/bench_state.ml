open! Core
open Hl_copy_core
module Size = Market_data.Size
module Price = Market_data.Price
module Symbol = Market_data.Symbol

let symbols n = Array.init n ~f:(fun i -> Symbol.of_string (sprintf "S%02d" i))
let mark = Price.of_int 100
let leader_size = Size.of_int 10

let in_line ~n =
  let syms = symbols n in
  let config =
    { Mirror.Config.follower = 1
    ; mode = Equity_ratio
    ; caps = { Caps.none with max_leverage = Some 10. }
    ; slippage_bps = 50
    ; specs =
        Array.to_list syms
        |> List.map ~f:(fun s -> s, Rounding.Spec.hyperliquid_perp ~sz_decimals:2)
        |> Map.of_alist_exn (module Symbol)
    }
  in
  let positions size =
    Array.to_list syms
    |> List.map ~f:(fun s -> s, size)
    |> Map.of_alist_exn (module Symbol)
  in
  let t, _ =
    Mirror.on_resync
      (Mirror.create config)
      ~leader_state:{ equity = Usd.of_int 1_000_000; positions = positions leader_size }
      ~follower_state:
        { equity = Usd.of_int 100_000
        ; positions = positions (Size.of_int 1)
        ; open_orders = []
        }
      ~marks:
        (Array.to_list syms
         |> List.map ~f:(fun s -> s, mark)
         |> Map.of_alist_exn (module Symbol))
  in
  t
;;

let same_update (t : Mirror.t) symbol =
  Mirror.Event.Leader_position
    { symbol; size = Map.find_exn t.leader_positions symbol; mark }
;;

let grow_update (t : Mirror.t) symbol =
  let size = Map.find_exn t.leader_positions symbol in
  Mirror.Event.Leader_position { symbol; size = Size.(size + div_int size 10); mark }
;;
