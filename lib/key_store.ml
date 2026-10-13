open! Core

let to_hex s = String.concat_map s ~f:(fun c -> sprintf "%02x" (Char.to_int c))

let of_hex s =
  let s = String.chop_prefix_if_exists (String.strip s) ~prefix:"0x" in
  if String.length s % 2 <> 0 || not (String.for_all s ~f:Char.is_hex_digit)
  then Or_error.error_string "not a hex string"
  else
    Ok
      (String.init
         (String.length s / 2)
         ~f:(fun i ->
           Char.of_int_exn (Int.of_string ("0x" ^ String.sub s ~pos:(2 * i) ~len:2))))
;;

let hmac ~key data = Cryptokit.hash_string (Cryptokit.MAC.hmac_sha256 key) data

module Master_key = struct
  type t =
    { master : string
    ; enc : string
    ; mac : string
    }

  let sexp_of_t _ = Sexp.Atom "<master key>"

  let of_hex hex =
    match of_hex hex with
    | Ok key when String.length key = 32 ->
      Ok
        { master = key
        ; enc = hmac ~key "hl-copy key-store v1 encryption"
        ; mac = hmac ~key "hl-copy key-store v1 authentication"
        }
    | Ok _ | Error _ ->
      Or_error.error_string "master key must be 64 hex digits (32 bytes)"
  ;;

  let of_env ?(var = "HL_COPY_MASTER_KEY") () =
    match Sys.getenv var with
    | None -> Or_error.errorf "%s is not set" var
    | Some hex -> Or_error.tag (of_hex hex) ~tag:var
  ;;

  let derive t ~label = hmac ~key:t.master ("hl-copy key-store v1 derive " ^ label)
end

module Entry = struct
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

type t =
  { dir : string
  ; key : Master_key.t
  }

let create ?master_key ~state_dir () =
  let open Or_error.Let_syntax in
  let%map key =
    match master_key with
    | Some key -> Ok key
    | None -> Master_key.of_env ()
  in
  { dir = state_dir ^/ "agents"; key }
;;

let suffix = ".key"
let path t ~account = t.dir ^/ Address.to_string account ^ suffix

let aad ~account ~agent_address =
  Address.to_string account ^ "/" ^ Address.to_string agent_address
;;

let chacha t ~nonce data =
  Cryptokit.transform_string
    (Cryptokit.Cipher.chacha20 (hmac ~key:t.key.enc nonce) Encrypt)
    data
;;

let tag t ~nonce ~aad ciphertext =
  hmac
    ~key:t.key.mac
    (String.concat [ "v1"; nonce; sprintf "%08x" (String.length aad); aad; ciphertext ])
;;

(* The time taken does not depend on where the tags differ. *)
let equal_constant_time a b =
  String.length a = String.length b
  && String.foldi a ~init:0 ~f:(fun i acc c ->
       acc lor (Char.to_int c lxor Char.to_int b.[i]))
     = 0
;;

let random_nonce () = Cryptokit.Random.string Cryptokit.Random.secure_rng 24

let write_atomically t ~account contents =
  Or_error.try_with (fun () ->
    Core_unix.mkdir_p ~perm:0o700 t.dir;
    let final = path t ~account in
    let tmp = t.dir ^/ "." ^ Address.to_string account ^ ".tmp" in
    Out_channel.with_file tmp ~perm:0o600 ~f:(fun oc ->
      Out_channel.output_string oc contents);
    Core_unix.rename ~src:tmp ~dst:final)
;;

let seal ?nonce t ~account ~agent_address ~private_key =
  let open Or_error.Let_syntax in
  let%bind secret = of_hex private_key in
  if String.length secret <> 32
  then Or_error.error_string "private key must be 64 hex digits"
  else (
    let nonce = Option.value_or_thunk nonce ~default:random_nonce in
    let ciphertext = chacha t ~nonce secret in
    let tag = tag t ~nonce ~aad:(aad ~account ~agent_address) ciphertext in
    return (to_hex ciphertext, to_hex nonce, to_hex tag))
;;

let put t ~account ~agent_address ~agent_name ~created ?valid_until ~private_key () =
  let open Or_error.Let_syntax in
  let%bind ciphertext, nonce, tag = seal t ~account ~agent_address ~private_key in
  let entry =
    { Entry.agent_address; agent_name; created; valid_until; ciphertext; nonce; tag }
  in
  let%map () =
    write_atomically t ~account (Sexp.to_string_hum (Entry.sexp_of_t entry) ^ "\n")
  in
  entry
;;

let find t ~account =
  let path = path t ~account in
  match Sys_unix.file_exists path with
  | `No | `Unknown -> Ok None
  | `Yes ->
    Or_error.try_with (fun () -> Some (Sexp.load_sexp_conv_exn path Entry.t_of_sexp))
    |> Or_error.tag ~tag:path
;;

let open_ t ~account (e : Entry.t) =
  let open Or_error.Let_syntax in
  let fail =
    Or_error.error_string "cannot open agent key (wrong master key or tampered file)"
  in
  match of_hex e.ciphertext, of_hex e.nonce, of_hex e.tag with
  | Ok ciphertext, Ok nonce, Ok expected when String.length nonce = 24 ->
    if equal_constant_time
         expected
         (tag t ~nonce ~aad:(aad ~account ~agent_address:e.agent_address) ciphertext)
    then return ("0x" ^ to_hex (chacha t ~nonce ciphertext))
    else fail
  | _ -> fail
;;

let get t ~account =
  match find t ~account with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some entry) ->
    Or_error.map (open_ t ~account entry) ~f:(fun key -> Some (entry, key))
;;

let list t =
  match Sys_unix.readdir t.dir with
  | exception _ -> []
  | files ->
    Array.to_list files
    |> List.filter ~f:(fun f -> not (String.is_prefix f ~prefix:"."))
    |> List.filter_map ~f:(String.chop_suffix ~suffix)
    |> List.filter_map ~f:(fun a ->
      match Address.of_string a with
      | account ->
        (match find t ~account with
         | Ok (Some e) -> Some (account, e)
         | Ok None | Error _ -> None)
      | exception _ -> None)
    |> List.sort ~compare:(fun (a, _) (b, _) -> Address.compare a b)
;;

let revoke t ~account =
  Or_error.try_with (fun () ->
    let path = path t ~account in
    match Sys_unix.file_exists path with
    | `Yes -> Core_unix.unlink path
    | `No | `Unknown -> ())
;;
