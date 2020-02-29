open Core
open Async_kernel

type iovec = Bigstring.t Unix.IOVec.t [@@deriving sexp_of]

let iovec_to_string { Unix.IOVec.buf; pos; len } = Bigstring.to_string buf ~pos ~len
let iovec_of_string s = Unix.IOVec.of_bigstring (Bigstring.of_string s)
let iovec_of_bigstring ?pos ?len b = Unix.IOVec.of_bigstring ?pos ?len b

type content =
  | Empty
  | String of string
  | Bigstring of bigstring
  | Stream of iovec Pipe.Reader.t
[@@deriving sexp_of]

type t =
  { length : Int64.t option
  ; content : content
  }
[@@deriving sexp_of, fields]

let drain { content; _ } =
  match content with
  | Stream content -> Pipe.drain content
  | _ -> Deferred.unit
;;

let to_string { content; _ } =
  match content with
  | Stream content ->
    let string_pipe = Pipe.map ~f:iovec_to_string content in
    let%map segments = Pipe.to_list string_pipe in
    String.concat segments
  | String s -> return s
  | Bigstring b -> return (Bigstring.to_string b)
  | Empty -> return ""
;;

let to_pipe { content; _ } =
  match content with
  | Stream content -> content
  | String s -> Pipe.singleton (iovec_of_string s)
  | Bigstring b -> Pipe.singleton (iovec_of_bigstring b)
  | Empty -> Pipe.of_list []
;;

let of_string s = { content = String s; length = Some (Int64.of_int (String.length s)) }

let of_bigstring b =
  { content = Bigstring b; length = Some (Int64.of_int (Bigstring.length b)) }
;;

let of_stream ?length s = { content = Stream s; length }
let empty = { content = Empty; length = Some 0L }

let read_httpaf_body ?length finished body =
  let on_eof' () =
    Httpaf.Body.close_reader body;
    Ivar.fill finished ();
    return @@ `Finished ()
  in
  let on_read' writer b ~off ~len =
    let%map () = Pipe.write_if_open writer (iovec_of_bigstring ~pos:off ~len b) in
    `Repeat ()
  in
  let b =
    (* Async recommends choosing false for [close_on_exception]. In a normal flow,
       closing the write end of the pipe will indicate that the writer finished successfully. *)
    Pipe.create_reader ~close_on_exception:false (fun writer ->
        (* [create_reader] will automatically close the writer end, when this Deferred becomes
           determined. We loop here so we can process a chain of Httpaf read events. *)
        Deferred.repeat_until_finished () (fun () ->
            let next_iter = Ivar.create () in
            let on_eof () =
              don't_wait_for (on_eof' () >>| fun n -> Ivar.fill next_iter n)
            in
            let on_read buffer ~off ~len =
              don't_wait_for
                (on_read' writer buffer ~off ~len >>| fun n -> Ivar.fill next_iter n)
            in
            Httpaf.Body.schedule_read body ~on_eof ~on_read;
            Ivar.read next_iter))
  in
  of_stream ?length b
;;