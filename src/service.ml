open Core
open Async_kernel

type http_request = Http.Request.t
type http_response = Http.Response.t

let sexp_of_http_request { Http.Request.meth; headers; version; resource; _ } =
  [%sexp
    { meth = (Http.Method.to_string meth : string)
    ; headers = (Http.Header.to_list headers : (string * string) list)
    ; version = (Http.Version.to_string version : string)
    ; resource : string
    }]
;;

let sexp_of_http_response { Http.Response.headers; version; status; _ } =
  [%sexp
    { headers = (Http.Header.to_list headers : (string * string) list)
    ; version = (Http.Version.to_string version : string)
    ; status = (Http.Status.to_int status : int)
    }]
;;

type request = http_request * Body.Reader.t [@@deriving sexp_of]
type response = http_response * Body.Writer.t [@@deriving sexp_of]
type ('req, 'res) t = 'req -> 'res Deferred.t

let body request = snd request
let header request key = Http.Header.get (Http.Request.headers (fst request)) key
let resource request = Http.Request.resource (fst request)
let meth request = Http.Request.meth (fst request)

let header_multi request key =
  Http.Header.get_multi (Http.Request.headers (fst request)) key
;;

let respond_string ?(headers = []) ?(status = `OK) body =
  let body = Body.Writer.string body in
  let headers = Http.Header.of_list_rev headers in
  let response = Http.Response.make ~status ~headers ~version:`HTTP_1_1 () in
  return (response, body)
;;

let respond_bigstring ?(headers = []) ?(status = `OK) body =
  let body = Body.Writer.bigstring body in
  let headers = Http.Header.of_list_rev headers in
  let response = Http.Response.make ~status ~headers ~version:`HTTP_1_1 () in
  return (response, body)
;;

let respond_stream ?(headers = []) ?(status = `OK) body =
  let body = Body.Writer.stream body in
  let headers = Http.Header.of_list_rev headers in
  let response = Http.Response.make ~status ~headers ~version:`HTTP_1_1 () in
  return (response, body)
;;
