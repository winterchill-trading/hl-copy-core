open! Core

module T = struct
  type t = Hl_protocol.Cloid.t [@@deriving sexp, compare, equal, hash]

  let to_string = Hl_protocol.Cloid.to_string
  let of_string = Hl_protocol.Cloid.of_string
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
  Hl_protocol.Cloid :
    Comparable.S
    with type t := t
     and type comparator_witness = Hl_protocol.Cloid.comparator_witness)

let create ~follower ~seq =
  if Int.(follower < 0 || seq < 0)
  then raise_s [%message "Cloid.create: negative part" (follower : int) (seq : int)];
  of_string (sprintf "0x%016x%016x" follower seq)
;;

let%expect_test "create" =
  print_endline (to_string (create ~follower:7 ~seq:258));
  [%expect {| 0x00000000000000070000000000000102 |}]
;;
