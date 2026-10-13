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
    end

    include Stable.V1
  end

  module Stable = struct
    module V1 = struct
      type t =
        { symbol : Symbol.Stable.V1.t
        ; reason : Reason.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Stable = struct
  module V1 = struct
    type t =
      { actions : Action.Stable.V1.t list
      ; notes : Note.Stable.V1.t list
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

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
