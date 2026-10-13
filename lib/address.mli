(** Account addresses ({!Hl_protocol.Address}) with a stable binary encoding (the
    lowercase hex string). Leaders and followers are identified by address. *)

open! Core

type t = Hl_protocol.Address.t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Binable.S with type t := t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end

val to_string : t -> string
val of_string : string -> t
