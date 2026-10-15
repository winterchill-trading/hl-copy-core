(** How the engine executes the orders a follow's mirror plans: the execution algorithm
    choice stored in {!Follower_config}.

    The constructors and fields are those of [Execution_algos.Algo.Stable.V1] in the
    execution-algos repository (same sexp, same bin_prot shape; the copy engine checks
    the digests are equal), kept here so this library does not depend on it. The engine
    converts with a one-to-one match. Durations are milliseconds.

    [Immediate] is the default and the behaviour before algos existed: each planned
    order is one IOC at the mirror's limit. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      | Immediate
      | Twap of
          { duration_ms : int
          ; slices : int
          ; max_participation : float option
          }
      | Vwap of
          { duration_ms : int
          ; slices : int
          ; max_participation : float option
          }
      | Pov of
          { participation : float
          ; max_duration_ms : int
          }
      | Passive of
          { display : float
          ; timeout_ms : int
          }
      | Adaptive of
          { small_ratio : float
          ; depth_bps : int
          ; max_behind_bps : int
          ; max_drift_bps : int
          ; timeout_ms : int
          }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  | Immediate
  | Twap of
      { duration_ms : int
      ; slices : int
      ; max_participation : float option
      }
  | Vwap of
      { duration_ms : int
      ; slices : int
      ; max_participation : float option
      }
  | Pov of
      { participation : float
      ; max_duration_ms : int
      }
  | Passive of
      { display : float
      ; timeout_ms : int
      }
  | Adaptive of
      { small_ratio : float
      ; depth_bps : int
      ; max_behind_bps : int
      ; max_drift_bps : int
      ; timeout_ms : int
      }
[@@deriving bin_io, sexp, compare, equal]

val default : t

(** ["immediate"], ["twap"], ["vwap"], ["pov"], ["passive"], ["iceberg"] (passive
    showing less than everything), ["adaptive"]. *)
val name : t -> string

(** Positive durations and slices; participation and display above 0 and at most 1;
    a positive ratio and bounds. *)
val validate : t -> unit Or_error.t
