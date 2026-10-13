(** Lot and tick specs for the backtest, per coin.

    The exact ones come from a saved [meta] response (the perpetuals universe with each
    coin's [szDecimals]). Coins missing from it (builder-deployed perps such as
    [xyz:NVDA] live in other universes) get a spec inferred from the fills: the fewest
    size decimals that every recorded fill size fits, which is at most the venue's
    [szDecimals] and so never rounds finer than the venue allows. *)

open! Core

type t = Hl_copy_core.Rounding.Spec.t Hl_copy_core.Mirror.Symbol_map.t [@@deriving sexp_of]

val of_meta : Hl_protocol.Meta.t -> t

(** Reads a [meta] info response saved as JSON. *)
val load_meta : string -> Hl_protocol.Meta.t Or_error.t

(** Size decimals per coin: the fewest decimals (0 to 6) that every fill size fits. *)
val inferred_sz_decimals : Hl_copy_core.Fill.t list -> int Map.M(Market_data.Symbol).t

val infer : Hl_copy_core.Fill.t list -> t

(** [meta]'s spec where it has one, else the inferred one. *)
val combine : meta:t -> inferred:t -> t
