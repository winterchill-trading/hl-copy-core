open! Core

module Stable = struct
  module V1 = struct
    type t =
      { follower : Address.Stable.V1.t
      ; leader : Address.Stable.V1.t
      ; mode : Scale.Mode.Stable.V1.t
      ; caps : Caps.Stable.V1.t
      ; slippage_bps : int
      ; paused : bool
      }
    [@@deriving bin_io, sexp, compare, equal]
  end

  module V2 = struct
    type t =
      { follower : Address.Stable.V1.t
      ; leader : Address.Stable.V1.t
      ; mode : Scale.Mode.Stable.V1.t
      ; caps : Caps.Stable.V1.t
      ; slippage_bps : int
      ; paused : bool
      ; algo : Exec_algo.Stable.V1.t
           [@sexp.default Exec_algo.default] [@sexp_drop_default.equal]
      }
    [@@deriving bin_io, sexp, compare, equal]

    let of_v1 ({ follower; leader; mode; caps; slippage_bps; paused } : V1.t) =
      { follower; leader; mode; caps; slippage_bps; paused; algo = Exec_algo.default }
    ;;

    let to_v1 { follower; leader; mode; caps; slippage_bps; paused; algo = _ } : V1.t =
      { follower; leader; mode; caps; slippage_bps; paused }
    ;;
  end
end

include Stable.V2

let default_slippage_bps = 20

let create
  ?(mode = Scale.Mode.Equity_ratio)
  ?(caps = Caps.none)
  ?(slippage_bps = default_slippage_bps)
  ?(algo = Exec_algo.default)
  ~follower
  ~leader
  ()
  =
  { follower; leader; mode; caps; slippage_bps; paused = false; algo }
;;

let validate t =
  let errors =
    List.filter_opt
      [ Option.some_if (Address.equal t.follower t.leader) "follower equals leader"
      ; Option.some_if
          (t.slippage_bps < 0 || t.slippage_bps > 1000)
          "slippage_bps outside [0, 1000]"
      ; (match t.mode with
         | Multiplier k ->
           Option.some_if (Float.is_nan k || Float.(k <= 0.)) "multiplier not positive"
         | Fixed_notional n ->
           Option.some_if (not (Usd.is_positive n)) "notional not positive"
         | Equity_ratio -> None)
      ; Option.bind t.caps.max_leverage ~f:(fun l ->
          Option.some_if
            (Float.is_nan l || Float.(l <= 0.) || not (Float.is_finite l))
            "max_leverage not positive")
      ; Option.bind t.caps.max_notional_per_symbol ~f:(fun n ->
          Option.some_if (Usd.is_negative n) "max_notional_per_symbol negative")
      ; Option.bind t.caps.max_daily_loss ~f:(fun n ->
          Option.some_if (Usd.is_negative n) "max_daily_loss negative")
      ; Option.some_if
          (Usd.is_negative t.caps.min_order_notional)
          "min_order_notional negative"
      ]
    @ List.map (Exec_algo.errors t.algo) ~f:(fun e -> "algo: " ^ e)
  in
  match errors with
  | [] -> Ok ()
  | _ -> Or_error.error_s [%message "invalid follower config" (errors : string list)]
;;

let file_name t =
  sprintf "%s-%s.sexp" (Address.to_string t.follower) (Address.to_string t.leader)
;;

let to_file_contents t = Sexp.to_string_hum (sexp_of_t t) ^ "\n"

let of_file_contents s =
  let open Or_error.Let_syntax in
  let%bind t =
    Or_error.try_with (fun () -> t_of_sexp (Sexp.of_string (String.strip s)))
  in
  let%map () = validate t in
  t
;;

let cloid_prefix t =
  let hex = Address.to_string t.leader in
  let hex = String.chop_prefix_if_exists hex ~prefix:"0x" in
  let hex = String.prefix (hex ^ String.make 15 '0') 15 in
  Int.of_string ("0x" ^ hex)
;;

let mirror_config t ~specs =
  { Mirror.Config.follower = cloid_prefix t
  ; mode = t.mode
  ; caps = t.caps
  ; slippage_bps = t.slippage_bps
  ; specs
  ; band = None
  }
;;
