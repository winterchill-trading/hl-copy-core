open! Core
module Symbol = Market_data.Symbol
module Size = Market_data.Size
module Price = Market_data.Price
module Notional = Fixed_decimal.Product (Size) (Price) (Usd)
module Avg = Fixed_decimal.Product (Price) (Size) (Usd)

module Position = struct
  module Stable = struct
    module V1 = struct
      type t =
        { size : Size.Stable.V1.t
        ; avg_entry : Price.Stable.V1.t
        ; realized : Usd.Stable.V1.t
        ; fees : Usd.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let flat =
    { size = Size.zero; avg_entry = Price.zero; realized = Usd.zero; fees = Usd.zero }
  ;;

  let same_side a b =
    (Size.is_positive a && Size.is_positive b)
    || (Size.is_negative a && Size.is_negative b)
  ;;

  let apply_fill t (fill : Fill.t) =
    let q = Fill.signed_size fill in
    let p = fill.price in
    let fees = Usd.(t.fees + fill.fee) in
    if Size.is_zero t.size || same_side t.size q
    then (
      let size = Size.(t.size + q) in
      let cost =
        Usd.(Notional.mul (Size.abs t.size) t.avg_entry + Notional.mul (Size.abs q) p)
      in
      { t with size; avg_entry = Avg.div cost (Size.abs size); fees })
    else (
      let closed = Size.min (Size.abs q) (Size.abs t.size) in
      let per_unit = Price.(p - t.avg_entry) in
      let pnl = Notional.mul closed per_unit in
      let pnl = if Size.is_positive t.size then pnl else Usd.neg pnl in
      let realized = Usd.(t.realized + pnl) in
      let size = Size.(t.size + q) in
      let avg_entry =
        if Size.is_zero size
        then Price.zero
        else if same_side size t.size
        then t.avg_entry
        else p
      in
      { size; avg_entry; realized; fees })
  ;;

  let unrealized t ~mark = Notional.mul t.size Price.(mark - t.avg_entry)
end

module Summary = struct
  type t =
    { leader : Address.t
    ; realized : Usd.t
    ; unrealized : Usd.t
    ; fees : Usd.t
    ; net : Usd.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable = struct
  module V1 = struct
    type t = Position.Stable.V1.t Map.M(Symbol).t Map.M(Address).t
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let empty = Map.empty (module Address)

let position t ~leader symbol =
  Option.bind (Map.find t leader) ~f:(fun book -> Map.find book symbol)
  |> Option.value ~default:Position.flat
;;

let on_fill t ~leader (fill : Fill.t) =
  Map.update t leader ~f:(fun book ->
    let book = Option.value book ~default:(Map.empty (module Symbol)) in
    Map.update book fill.symbol ~f:(fun p ->
      Position.apply_fill (Option.value p ~default:Position.flat) fill))
;;

let summary t ~marks =
  Map.to_alist t
  |> List.map ~f:(fun (leader, book) ->
    let realized, unrealized, fees =
      Map.fold
        book
        ~init:(Usd.zero, Usd.zero, Usd.zero)
        ~f:(fun ~key ~data:(p : Position.t) (r, u, f) ->
          let u =
            match Map.find marks key with
            | None -> u
            | Some mark -> Usd.(u + Position.unrealized p ~mark)
          in
          Usd.(r + p.realized), u, Usd.(f + p.fees))
    in
    { Summary.leader
    ; realized
    ; unrealized
    ; fees
    ; net = Usd.(realized + unrealized - fees)
    })
;;
