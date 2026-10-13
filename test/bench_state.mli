(** A follower mirroring a leader on [n] symbols, shared by the benchmark and the
    allocation test. *)

open! Core
open Hl_copy_core

val symbols : int -> Market_data.Symbol.t array

(** Leader and follower in line on every symbol (each leader position filled), marks set,
    nothing pending. *)
val in_line : n:int -> Mirror.t

(** A leader update equal to the current state (plans nothing). *)
val same_update : Mirror.t -> Market_data.Symbol.t -> Mirror.Event.t

(** A leader update that grows the position by 10% (plans one order). *)
val grow_update : Mirror.t -> Market_data.Symbol.t -> Mirror.Event.t
