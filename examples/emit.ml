(*
 * SPDX-FileCopyrightText: 2023 Tarides <contact@tarides.com>
 *
 * SPDX-License-Identifier: ISC
 *)

(* This is a small experiment to see if this library could be used for
   an OCaml 5 style event tracing:

   https://v2.ocaml.org/releases/5.0/api/Runtime_events.html

   The idea is that an emitting process writes events into a ring
   buffer backed by an memory mapped file. A listening process uses
   the same mapped file to read events from the ring buffer.

   This would allow OCaml 5 style event tracing (also custom events;
   see https://github.com/ocaml/ocaml/pull/11474) for OCaml 4.*.
*)

open Lwt
open Lwt.Syntax

(* Initialize a shared ring backed by a memory-mapped file *)
let init_sring ~size ~idx_size path =
  let fd = Unix.openfile path Unix.[ O_CREAT; O_RDWR ] 0o600 in
  Unix.ftruncate fd size;
  let mmap =
    Unix.map_file fd Char Bigarray.c_layout true [| -1 |]
    |> Bigarray.array1_of_genarray
  in
  Ring.Rpc.of_buf ~buf:(Cstruct.of_bigarray mmap) ~idx_size ~name:"emit_ring"

(* Events are just strings *)
type event = string

module Id = struct
  type t = int

  let counter = ref 0

  let next () =
    let id = !counter in
    counter := id + 1;
    id
end

module Emitter = struct
  (* Emitter is a frontend. *)

  type t = (unit, Id.t) Lwt_ring.Front.t

  let init sring : t =
    let front = Ring.Rpc.Front.init ~sring in
    let t = Lwt_ring.Front.init string_of_int front in
    t

  let emit t event =
    Lwt_ring.Front.push_request_and_wait t
      (fun () -> Format.printf "notify_fn called\n%!")
      (fun buf ->
        let id = Id.next () in
        Cstruct.LE.set_uint16 buf 0 id;
        Cstruct.LE.set_uint16 buf 2 (String.length event);
        Seq.iteri (fun i c -> Cstruct.set_char buf (4 + i) c)
        @@ String.to_seq event;
        id)

  let poll t =
    Lwt_ring.Front.poll t (fun buf ->
        let id = Cstruct.LE.get_uint16 buf 0 in
        (id, ()))
end

module Listener = struct
  (* Listener is a backend. *)

  type t = (event, Id.t) Lwt_ring.Back.t

  let init sring : t =
    let front = Ring.Rpc.Back.init ~sring in
    let t = Lwt_ring.Back.init string_of_int front in
    t

  let listen t =
    Lwt_ring.Back.push_response t
      (fun () -> ())
      (fun buf ->
        let id = Cstruct.LE.get_uint16 buf 0 in
        let len = Cstruct.LE.get_uint16 buf 2 in
        let event = Cstruct.to_string ~off:4 ~len buf in
        Format.printf "Listener got (id=%d): %s\n%!" id event)
end

let main () =
  let sring = init_sring ~size:1024 ~idx_size:32 "eventring" in

  (* Initialize the emitter and listener. *)
  let emitter = Emitter.init sring in
  let listener = Listener.init sring in

  (* Emit some events. *)
  let emits =
    [
      Emitter.emit emitter "hello";
      Emitter.emit emitter "event";
      Emitter.emit emitter "ring";
      Emitter.emit emitter "with";
      Emitter.emit emitter "shared-memory-ring";
    ]
  in

  (* Listen for the events. *)
  Listener.listen listener;
  Listener.listen listener;
  Listener.listen listener;
  Listener.listen listener;
  Listener.listen listener;

  (* Emitter needs to poll for responses to emitted events. *)
  Emitter.poll emitter;

  (* Conclusion: This does not work as intended:

        - The RPC semantics don't fit very well for just emitting a
          stream of events. The event does not really need to be acked.
        - The design of the ring buffer requires a bit of cordination
     between emitter and listener. The OCaml 5 eventring does not require
     any coordination between readers and producer.
  *)
  let* _ = Lwt.all emits in
  return_unit

let () = Lwt_main.run (main ())
