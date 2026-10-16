(** What the mirror wants done on the follower's account: immediate-or-cancel orders to
    place, orders to cancel, and notes explaining what was capped or skipped. Every order
    is IOC with a limit at most [slippage_bps] through the mark (see
    {!Rounding.ioc_limit}). Actions are in the order they should be sent: cancels before
    places for each symbol, symbols in ascending order. *)

open! Core

module Order : sig
  module Stable : sig
    module V1 : sig
      type t =
        { cloid : Cloid.Stable.V1.t
        ; symbol : Market_data.Symbol.Stable.V1.t
        ; side : Market_data.Side.Stable.V1.t
        ; size : Market_data.Size.Stable.V1.t
        ; limit_px : Market_data.Price.Stable.V1.t
        ; reduce_only : bool
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    { cloid : Cloid.t
    ; symbol : Market_data.Symbol.t
    ; side : Market_data.Side.t
    ; size : Market_data.Size.t (** positive, a lot multiple *)
    ; limit_px : Market_data.Price.t (** on the tick grid *)
    ; reduce_only : bool
    (** set when the order only shrinks the position toward zero, never through it *)
    }
  [@@deriving bin_io, sexp, compare, equal]

  (** [size] signed by [side]. *)
  val signed_size : t -> Market_data.Size.t
end

module Action : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Place of Order.Stable.V1.t
        | Cancel of
            { symbol : Market_data.Symbol.Stable.V1.t
            ; cloid : Cloid.Stable.V1.t
            }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    | Place of Order.t
    | Cancel of
        { symbol : Market_data.Symbol.t
        ; cloid : Cloid.t
        }
  [@@deriving bin_io, sexp, compare, equal]
end

module Note : sig
  module Reason : sig
    module Stable : sig
      module V1 : sig
        type t =
          | Capped of Caps.Reason.Stable.V1.t
          | No_mark
          | No_spec
          | No_leader_equity
        [@@deriving bin_io, sexp, compare, equal]
      end

      (** [V1] plus the no-trade band's skips. *)
      module V2 : sig
        type t =
          | Capped of Caps.Reason.Stable.V1.t
          | No_mark
          | No_spec
          | No_leader_equity
          | Within_band of
              { gap : Market_data.Size.Stable.V1.t
              ; band : Usd.Stable.V1.t
              ; saved : Usd.Stable.V1.t
              }
        [@@deriving bin_io, sexp, compare, equal]

        val of_v1 : V1.t -> t

        (** [None] for [Within_band]. *)
        val to_v1 : t -> V1.t option
      end
    end

    type t = Stable.V2.t =
      | Capped of Caps.Reason.t
      | No_mark (** no mark price known for the symbol yet *)
      | No_spec (** no lot/tick spec configured for the symbol *)
      | No_leader_equity (** the leader's equity is unknown or not positive *)
      | Within_band of
          { gap : Market_data.Size.t (** [target - current], signed *)
          ; band : Usd.t (** the band's half-width, USD notional *)
          ; saved : Usd.t (** estimated cost of the rebalance not sent *)
          }
      (** the gap to the target is inside the follow's {!No_trade_band}: no order *)
    [@@deriving bin_io, sexp, compare, equal]
  end

  module Stable : sig
    module V1 : sig
      type t =
        { symbol : Market_data.Symbol.Stable.V1.t
        ; reason : Reason.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 : sig
      type t =
        { symbol : Market_data.Symbol.Stable.V1.t
        ; reason : Reason.Stable.V2.t
        }
      [@@deriving bin_io, sexp, compare, equal]

      val of_v1 : V1.t -> t
      val to_v1 : t -> V1.t option
    end
  end

  type t = Stable.V2.t =
    { symbol : Market_data.Symbol.t
    ; reason : Reason.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Stable : sig
  module V1 : sig
    type t =
      { actions : Action.Stable.V1.t list
      ; notes : Note.Stable.V1.t list
      }
    [@@deriving bin_io, sexp, compare, equal]
  end

  (** Notes may say [Within_band]. *)
  module V2 : sig
    type t =
      { actions : Action.Stable.V1.t list
      ; notes : Note.Stable.V2.t list
      }
    [@@deriving bin_io, sexp, compare, equal]

    val of_v1 : V1.t -> t

    (** Drops [Within_band] notes. *)
    val to_v1 : t -> V1.t
  end
end

type t = Stable.V2.t =
  { actions : Action.t list
  ; notes : Note.t list
  }
[@@deriving bin_io, sexp, compare, equal]

val empty : t
val is_empty : t -> bool
val append : t -> t -> t
val concat : t list -> t
val places : t -> Order.t list
val cancels : t -> Cloid.t list
