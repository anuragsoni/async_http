open Core
open Async
open Shuttle

type encoding =
  [ `Chunked
  | `Fixed of int64
  ]
[@@deriving sexp]

module Reader = struct
  type t =
    { encoding : encoding
    ; reader : (string Pipe.Reader.t[@sexp.opaque])
    }
  [@@deriving sexp_of]

  let empty = { encoding = `Fixed 0L; reader = Pipe.empty () }

  module Private = struct
    let fixed_reader len chan =
      Pipe.create_reader ~close_on_exception:false (fun writer ->
          Deferred.repeat_until_finished len (fun len ->
              Input_channel.read chan len
              >>= function
              | `Eof -> return (`Finished ())
              | `Ok chunk ->
                let consumed = String.length chunk in
                Pipe.write_if_open writer chunk
                >>= fun () ->
                if consumed = len
                then return (`Finished ())
                else return (`Repeat (len - consumed))))
    ;;

    let chunked_reader chan =
      Pipe.create_reader ~close_on_exception:false (fun writer ->
          Deferred.repeat_until_finished Parser.Start_chunk (fun state ->
              let view = Input_channel.view chan in
              match Parser.parse_chunk ~pos:view.pos ~len:view.len view.buf state with
              | Error (Msg msg) ->
                Log.Global.error "Error while parsing chunk: %s" msg;
                failwith msg
              | Error Partial ->
                Input_channel.refill chan
                >>| (function
                | `Ok -> `Repeat state
                | `Buffer_is_full -> `Finished ()
                | `Eof -> `Finished ())
              | Ok (parse_result, consumed) ->
                Input_channel.consume chan consumed;
                (match parse_result with
                | Parser.Chunk_complete chunk ->
                  Pipe.write_if_open writer chunk >>| fun () -> `Repeat Parser.Start_chunk
                | Parser.Done -> return (`Finished ())
                | Parser.Partial_chunk (chunk, to_consume) ->
                  Pipe.write_if_open writer chunk
                  >>| fun () -> `Repeat (Parser.Continue_chunk to_consume))))
    ;;

    let get_transfer_encoding headers =
      match List.rev @@ Headers.find_multi headers "Transfer-Encoding" with
      | x :: _ when String.Caseless.equal x "chunked" -> `Chunked
      | _x :: _ -> `Bad_request
      | [] ->
        (match
           List.dedup_and_sort
             ~compare:String.Caseless.compare
             (Headers.find_multi headers "Content-Length")
         with
        | [] -> `Fixed 0L
        (* TODO: check for exceptions when converting to int *)
        | [ x ] ->
          let len =
            try Int64.of_string x with
            | _ -> -1L
          in
          if Int64.(len >= 0L) then `Fixed len else `Bad_request
        | _ -> `Bad_request)
    ;;

    let create req chan =
      match get_transfer_encoding (Request.headers req) with
      | `Fixed 0L -> Ok empty
      | `Fixed len as encoding ->
        let reader = fixed_reader (Int64.to_int_exn len) chan in
        Ok { encoding; reader }
      | `Chunked as encoding -> Ok { encoding; reader = chunked_reader chan }
      | `Bad_request -> Or_error.error_s [%sexp "Invalid transfer encoding"]
    ;;
  end

  let encoding t = t.encoding
  let pipe t = t.reader
  let drain t = Pipe.drain t.reader
end

module Writer = struct
  type kind =
    | Empty
    | String of string
    | Bigstring of Bigstring.t
    | Stream of (string Pipe.Reader.t[@sexp.opaque])
  [@@deriving sexp_of]

  type t =
    { encoding : encoding
    ; kind : kind
    }
  [@@deriving sexp_of]

  let encoding t = t.encoding
  let empty = { encoding = `Fixed 0L; kind = Empty }
  let string x = { encoding = `Fixed (Int64.of_int (String.length x)); kind = String x }

  let bigstring x =
    { encoding = `Fixed (Int64.of_int (Bigstring.length x)); kind = Bigstring x }
  ;;

  let stream ?(encoding = `Chunked) x = { encoding; kind = Stream x }

  module Private = struct
    let is_chunked t =
      match t.encoding with
      | `Chunked -> true
      | _ -> false
    ;;

    let make_writer t =
      match t.encoding with
      | `Chunked ->
        fun writer buf ->
          (* avoid writing empty payloads as that is used to indicate the end of a
             stream. *)
          if String.is_empty buf
          then Deferred.unit
          else (
            Output_channel.writef writer "%x\r\n" (String.length buf);
            Output_channel.write writer buf;
            Output_channel.write writer "\r\n";
            Output_channel.flush writer)
      | `Fixed _ ->
        fun writer buf ->
          if String.is_empty buf
          then Deferred.unit
          else (
            Output_channel.write writer buf;
            Output_channel.flush writer)
    ;;

    let write t writer =
      Deferred.create (fun ivar ->
          match t.kind with
          | Empty -> Ivar.fill ivar ()
          | String x ->
            Output_channel.write writer x;
            Output_channel.flush writer >>> fun () -> Ivar.fill ivar ()
          | Bigstring b ->
            Output_channel.write_bigstring writer b;
            Output_channel.flush writer >>> fun () -> Ivar.fill ivar ()
          | Stream xs ->
            let write_chunk = make_writer t in
            Pipe.iter xs ~f:(fun buf -> write_chunk writer buf)
            >>> fun () ->
            if is_chunked t
            then (
              Output_channel.write writer "0\r\n\r\n";
              Output_channel.flush writer >>> fun () -> Ivar.fill ivar ())
            else Ivar.fill ivar ())
    ;;
  end
end
