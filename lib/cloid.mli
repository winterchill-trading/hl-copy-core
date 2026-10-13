(** Hyperliquid client order ids ({!Hl_protocol.Cloid}) with a stable binary encoding (the
    ["0x..."] string), and the deterministic ids the mirror assigns. *)

open! Core

type t = Hl_protocol.Cloid.t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Binable.S with type t := t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

(** [create ~follower ~seq] is ["0x"] followed by 16 hex digits of [follower] and 16 hex
    digits of [seq], so ids never collide between followers sharing a venue account and
    are the same every time the same events are replayed. Requires [follower >= 0] and
    [seq >= 0]. *)
val create : follower:int -> seq:int -> t

val to_string : t -> string
val of_string : string -> t
