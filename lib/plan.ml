open! Core
module Symbol = Market_data.Symbol
module Side = Market_data.Side
module Size = Market_data.Size
module Price = Market_data.Price

module Order = struct
  module Stable = struct
    module V1 = struct
      type t =
        { cloid : Cloid.Stable.V1.t
        ; symbol : Symbol.Stable.V1.t
        ; side : Side.Stable.V1.t
        ; size : Size.Stable.V1.t
        ; limit_px : Price.Stable.V1.t
        ; reduce_only : bool
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let signed_size t =
    match t.side with
    | Buy -> t.size
    | Sell -> Size.neg t.size
  ;;
end

module Action = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Place of Order.Stable.V1.t
        | Cancel of
            { symbol : Symbol.Stable.V1.t
            ; cloid : Cloid.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Note = struct
  module Reason = struct
    module Stable = struct
      module V1 = struct
        type t =
          | Capped of Caps.Reason.Stable.V1.t
          | No_mark
          | No_spec
          | No_leader_equity
        [@@deriving bin_io, sexp, compare, equal]
      end

      module V2 = struct
        type t =
          | Capped of Caps.Reason.Stable.V1.t
          | No_mark
          | No_spec
          | No_leader_equity
          | Within_band of
              { gap : Size.Stable.V1.t
              ; band : Usd.Stable.V1.t
              ; saved : Usd.Stable.V1.t
              }
        [@@deriving bin_io, sexp, compare, equal]

        let of_v1 : V1.t -> t = function
          | Capped r -> Capped r
          | No_mark -> No_mark
          | No_spec -> No_spec
          | No_leader_equity -> No_leader_equity
        ;;

        let to_v1 : t -> V1.t option = function
          | Capped r -> Some (Capped r)
          | No_mark -> Some No_mark
          | No_spec -> Some No_spec
          | No_leader_equity -> Some No_leader_equity
          | Within_band _ -> None
        ;;
      end
    end

    include Stable.V2
  end

  module Stable = struct
    module V1 = struct
      type t =
        { symbol : Symbol.Stable.V1.t
        ; reason : Reason.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
      type t =
        { symbol : Symbol.Stable.V1.t
        ; reason : Reason.Stable.V2.t
        }
      [@@deriving bin_io, sexp, compare, equal]

      let of_v1 ({ symbol; reason } : V1.t) =
        { symbol; reason = Reason.Stable.V2.of_v1 reason }
      ;;

      let to_v1 { symbol; reason } : V1.t option =
        Option.map (Reason.Stable.V2.to_v1 reason) ~f:(fun reason ->
          { V1.symbol; reason })
      ;;
    end
  end

  include Stable.V2
end

module Stable = struct
  module V1 = struct
    type t =
      { actions : Action.Stable.V1.t list
      ; notes : Note.Stable.V1.t list
      }
    [@@deriving bin_io, sexp, compare, equal]
  end

  module V2 = struct
    type t =
      { actions : Action.Stable.V1.t list
      ; notes : Note.Stable.V2.t list
      }
    [@@deriving bin_io, sexp, compare, equal]

    let of_v1 ({ actions; notes } : V1.t) =
      { actions; notes = List.map notes ~f:Note.Stable.V2.of_v1 }
    ;;

    let to_v1 { actions; notes } : V1.t =
      { actions; notes = List.filter_map notes ~f:Note.Stable.V2.to_v1 }
    ;;
  end
end

include Stable.V2

let empty = { actions = []; notes = [] }
let is_empty t = List.is_empty t.actions && List.is_empty t.notes
let append a b = { actions = a.actions @ b.actions; notes = a.notes @ b.notes }

let concat ts =
  { actions = List.concat_map ts ~f:(fun t -> t.actions)
  ; notes = List.concat_map ts ~f:(fun t -> t.notes)
  }
;;

let places t =
  List.filter_map t.actions ~f:(function
    | Place o -> Some o
    | Cancel _ -> None)
;;

let cancels t =
  List.filter_map t.actions ~f:(function
    | Cancel { cloid; _ } -> Some cloid
    | Place _ -> None)
;;
