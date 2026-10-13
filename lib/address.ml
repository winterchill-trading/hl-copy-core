open! Core

module T = struct
  type t = Hl_protocol.Address.t [@@deriving sexp, compare, equal, hash]

  let to_string = Hl_protocol.Address.to_string
  let of_string = Hl_protocol.Address.of_string
end

module Bin = Binable.Of_stringable_without_uuid [@alert "-legacy"] (T)

module Stable = struct
  module V1 = struct
    include T
    include Bin
  end
end

include T
include Bin

include (
  Hl_protocol.Address :
    Comparable.S
    with type t := t
     and type comparator_witness = Hl_protocol.Address.comparator_witness)
