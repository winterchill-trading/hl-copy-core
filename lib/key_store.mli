(** Agent private keys at rest, shared by hl-copy-api (writes) and hl-copy-engine (reads).

    Layout: [<state_dir>/agents/<account address>.key], mode [0600], one file per account
    holding the account's current agent:

    {v
((agent_address 0x...) (agent_name "hl-copy valid_until 1807343157720")
 (created 2026-10-13T07:45:26.150000000Z) (valid_until (2027-04-10T07:45:26.150Z))
 (ciphertext <hex>) (nonce <hex, 24 bytes>) (tag <hex, 32 bytes>))
    v}

    Encryption, under the 32-byte master key from [HL_COPY_MASTER_KEY] (64 hex digits,
    e.g. [openssl rand -hex 32]). The switch's cryptokit 1.16 has ChaCha20 and HMAC-SHA256
    but no AEAD mode, so this is the standard encrypt-then-MAC composition:

    + subkeys [enc = HMAC-SHA256(master, "hl-copy key-store v1 encryption")] and
      [mac = HMAC-SHA256(master, "hl-copy key-store v1 authentication")];
    + per key a fresh random 24-byte [nonce]; the ChaCha20 key is
      [HMAC-SHA256(enc, nonce)] (an extended-nonce construction like XChaCha20, so no key
      and nonce pair ever repeats), with ChaCha20's own 8-byte nonce zero;
    + [tag = HMAC-SHA256(mac, "v1" || nonce || len(aad) as 8 hex digits || aad || ciphertext)]
      with [aad = "<account>/<agent_address>"], checked in constant time before
      decrypting, so a file copied to another account, or edited, does not open.

    TODO: move to ChaCha20-Poly1305 or AES-GCM when the switch carries a cryptokit with
    AEAD; a new layout would get a new [v2] label.

    A [put] replaces the account's agent (rotation); [revoke] deletes the file, after
    which {!get} returns [None] and the engine stops trading the account. Writes go
    through a dot-prefixed temporary file renamed into place. *)

open! Core

module Master_key : sig
  (** Never shown by [sexp_of_t]. *)
  type t [@@deriving sexp_of]

  (** 64 hex digits, with or without [0x]. *)
  val of_hex : string -> t Or_error.t

  (** Reads [var], default [HL_COPY_MASTER_KEY]. *)
  val of_env : ?var:string -> unit -> t Or_error.t

  (** A 32-byte key for another purpose, e.g. session tokens:
      [HMAC-SHA256(master, "hl-copy key-store v1 derive " ^ label)]. *)
  val derive : t -> label:string -> string
end

module Entry : sig
  (** The file's contents. [ciphertext], [nonce] and [tag] are lowercase hex. *)
  type t =
    { agent_address : Address.t
    ; agent_name : string
    ; created : Time_ns.Alternate_sexp.t
    ; valid_until : Time_ns.Alternate_sexp.t option
    ; ciphertext : string
    ; nonce : string
    ; tag : string
    }
  [@@deriving sexp, compare, equal]
end

type t

(** [master_key] defaults to {!Master_key.of_env}. *)
val create : ?master_key:Master_key.t -> state_dir:string -> unit -> t Or_error.t

(** [<state_dir>/agents/<account>.key] *)
val path : t -> account:Address.t -> string

(** Seals [private_key] (64 hex digits, with or without [0x]) for [account], replacing any
    previous agent. *)
val put
  :  t
  -> account:Address.t
  -> agent_address:Address.t
  -> agent_name:string
  -> created:Time_ns.t
  -> ?valid_until:Time_ns.t
  -> private_key:string
  -> unit
  -> Entry.t Or_error.t

(** The account's agent without decrypting it. *)
val find : t -> account:Address.t -> Entry.t option Or_error.t

(** The decrypted private key as [0x] and 64 lowercase hex digits (what
    [Hl_client.Signing.Private_key.of_hex] takes), with the entry. Fails on a wrong master
    key or a tampered file. *)
val get : t -> account:Address.t -> (Entry.t * string) option Or_error.t

(** Accounts with a key file, sorted, with their entries; unreadable files are skipped. *)
val list : t -> (Address.t * Entry.t) list

(** Deletes the account's key file; [Ok ()] when there was none. *)
val revoke : t -> account:Address.t -> unit Or_error.t
