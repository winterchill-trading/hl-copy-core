open! Core
open Hl_copy_core

let master = Key_store.Master_key.of_hex (String.make 64 'a') |> Or_error.ok_exn
let other_master = Key_store.Master_key.of_hex (String.make 64 'b') |> Or_error.ok_exn
let account = Address.of_string "0x1111111111111111111111111111111111111111"
let other = Address.of_string "0x2222222222222222222222222222222222222222"
let agent = Address.of_string "0x3333333333333333333333333333333333333333"
let key = "0x" ^ String.make 64 '7'
let created = Time_ns.of_string_with_utc_offset "2026-10-13 07:00:00Z"

let with_store f =
  let dir = Filename_unix.temp_dir "key-store" "" in
  Exn.protect
    ~f:(fun () ->
      f dir (Key_store.create ~master_key:master ~state_dir:dir () |> Or_error.ok_exn))
    ~finally:(fun () ->
      ignore
        (Core_unix.system (sprintf "rm -rf %s" (Filename.quote dir))
         : Core_unix.Exit_or_signal.t))
;;

let show_get t ~account =
  print_s
    [%sexp
      (Key_store.get t ~account |> Or_error.map ~f:(Option.map ~f:snd)
       : string option Or_error.t)]
;;

let%expect_test "put, get, list, rotate, revoke" =
  with_store (fun dir t ->
    show_get t ~account;
    [%expect {| (Ok ()) |}];
    let entry =
      Key_store.put
        t
        ~account
        ~agent_address:agent
        ~agent_name:"hl-copy"
        ~created
        ~valid_until:(Time_ns.add created (Time_ns.Span.of_day 179.))
        ~private_key:key
        ()
      |> Or_error.ok_exn
    in
    print_s
      [%sexp
        (entry.created : Time_ns.Alternate_sexp.t)
        , (entry.valid_until : Time_ns.Alternate_sexp.t option)
        , (String.length entry.nonce : int)
        , (String.length entry.tag : int)
        , (String.is_substring entry.ciphertext ~substring:(String.make 64 '7') : bool)];
    [%expect {| ("2026-10-13 07:00:00Z" ("2027-04-10 07:00:00Z") 48 64 false) |}];
    show_get t ~account;
    [%expect
      {| (Ok (0x7777777777777777777777777777777777777777777777777777777777777777)) |}];
    let path = Key_store.path t ~account in
    print_s
      [%sexp
        (String.chop_prefix_exn path ~prefix:dir : string)
        , ((Core_unix.stat path).st_perm : int)];
    [%expect {| (/agents/0x1111111111111111111111111111111111111111.key 384) |}];
    let (_ : Key_store.Entry.t) =
      Key_store.put
        t
        ~account
        ~agent_address:other
        ~agent_name:"hl-copy 2"
        ~created
        ~private_key:(String.make 64 '8')
        ()
      |> Or_error.ok_exn
    in
    print_s
      [%sexp
        (Key_store.list t
         |> List.map ~f:(fun (a, (e : Key_store.Entry.t)) -> a, e.agent_address)
         : (Address.t * Address.t) list)];
    [%expect
      {|
      ((0x1111111111111111111111111111111111111111
        0x2222222222222222222222222222222222222222))
      |}];
    print_s [%sexp (Key_store.revoke t ~account : unit Or_error.t)];
    show_get t ~account;
    print_s [%sexp (Key_store.revoke t ~account : unit Or_error.t)];
    [%expect {|
      (Ok ())
      (Ok ())
      (Ok ())
      |}])
;;

let%expect_test "wrong master key, another account's file and tampering do not open" =
  with_store (fun dir t ->
    let entry =
      Key_store.put
        t
        ~account
        ~agent_address:agent
        ~agent_name:"hl-copy"
        ~created
        ~private_key:key
        ()
      |> Or_error.ok_exn
    in
    let wrong =
      Key_store.create ~master_key:other_master ~state_dir:dir () |> Or_error.ok_exn
    in
    show_get wrong ~account;
    (* The same file under another account's name. *)
    Out_channel.write_all
      (Key_store.path t ~account:other)
      ~data:(Sexp.to_string (Key_store.Entry.sexp_of_t entry));
    show_get t ~account:other;
    let flip_first s =
      let c = if Char.equal s.[0] '0' then "1" else "0" in
      c ^ String.drop_prefix s 1
    in
    Out_channel.write_all
      (Key_store.path t ~account)
      ~data:
        (Sexp.to_string
           (Key_store.Entry.sexp_of_t
              { entry with ciphertext = flip_first entry.ciphertext }));
    show_get t ~account;
    [%expect
      {|
      (Error "cannot open agent key (wrong master key or tampered file)")
      (Error "cannot open agent key (wrong master key or tampered file)")
      (Error "cannot open agent key (wrong master key or tampered file)")
      |}];
    print_s
      [%sexp
        (Key_store.put
           t
           ~account
           ~agent_address:agent
           ~agent_name:"x"
           ~created
           ~private_key:"0x12"
           ()
         |> Result.is_error
         : bool)];
    [%expect {| true |}])
;;

let%expect_test "master key parsing and derivation" =
  print_s
    [%sexp
      (Key_store.Master_key.of_hex (String.make 62 'a')
       : Key_store.Master_key.t Or_error.t)];
  print_s [%sexp (master : Key_store.Master_key.t)];
  print_s
    [%sexp
      (String.length (Key_store.Master_key.derive master ~label:"session") : int)
      , (String.equal
           (Key_store.Master_key.derive master ~label:"session")
           (Key_store.Master_key.derive master ~label:"other")
         : bool)];
  [%expect
    {|
    (Error "master key must be 64 hex digits (32 bytes)")
    "<master key>"
    (32 false)
    |}]
;;
