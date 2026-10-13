(** Rounding sizes to the venue's lot and prices to its tick.

    Sizes are truncated toward zero to a multiple of [lot], so a rounded order never
    exceeds what sizing and caps allowed. Prices are rounded to a multiple of [tick] in
    the direction the caller asks; with [sig_figs], also to that many significant figures
    (integer prices are always allowed, as on Hyperliquid). *)

open! Core

module Spec : sig
  module Stable : sig
    module V1 : sig
      type t =
        { lot : Market_data.Size.Stable.V1.t
        ; tick : Market_data.Price.Stable.V1.t
        ; sig_figs : int option
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    { lot : Market_data.Size.t
    ; tick : Market_data.Price.t
    ; sig_figs : int option
    }
  [@@deriving bin_io, sexp, compare, equal]

  (** Hyperliquid perpetuals: lot [10^-sz_decimals], at most [6 - sz_decimals] price
      decimals and 5 significant figures. *)
  val hyperliquid_perp : sz_decimals:int -> t

  val of_asset_meta : Hl_protocol.Meta.Asset_meta.t -> t

  (** Tick and lot from the catalogue entry, no significant-figure rule. *)
  val of_instrument_info : Market_data.Instrument_info.t -> t
end

(** Truncates toward zero to a multiple of [lot]. *)
val size : Spec.t -> Market_data.Size.t -> Market_data.Size.t

(** The order that moves [current] to [target], truncated toward zero to the lot, or
    [None] when that is less than one lot. *)
val delta
  :  Spec.t
  -> current:Market_data.Size.t
  -> target:Market_data.Size.t
  -> Market_data.Size.t option

(** Rounds a positive price onto the grid, [`Down] or [`Up]. *)
val price : Spec.t -> Market_data.Price.t -> dir:[ `Down | `Up ] -> Market_data.Price.t

(** The limit price of an immediate-or-cancel order that may trade at most [slippage_bps]
    basis points through [mark]: a buy at [mark * (1 + bps / 10^4)] rounded down, a sell
    at [mark * (1 - bps / 10^4)] rounded up, so rounding never widens the bound. *)
val ioc_limit
  :  Spec.t
  -> side:Market_data.Side.t
  -> mark:Market_data.Price.t
  -> slippage_bps:int
  -> Market_data.Price.t
