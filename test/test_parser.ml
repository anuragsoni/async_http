open! Core
open Async_http

let req =
  "GET /wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg HTTP/1.1\r\n\
   Host: www.kittyhell.com   \r\n\
   User-Agent: Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) \
   Gecko/20100401 Firefox/3.6.3 Pathtraq/0.9\r\n\
   Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n\
   Accept-Language: ja,en-us;q=0.7,en;q=0.3\r\n\
   Accept-Encoding: gzip,deflate\r\n\
   Accept-Charset: Shift_JIS,utf-8;q=0.7,*;q=0.7\r\n\
   Keep-Alive: 115\r\n\
   Connection: keep-alive\r\n\
   Cookie: wp_ozh_wsa_visits=2; wp_ozh_wsa_visit_lasttime=xxxxxxxxxx; \
   __utma=xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x; \
   __utmz=xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral\r\n\
   \r\n"
;;

let req = Bigstring.of_string req

module P = Async_http.Private.Parser

type 'a success =
  { consumed : int
  ; value : 'a
  }
[@@deriving sexp_of]

let parse_or_error res =
  match res with
  | Ok (value, consumed) -> Ok { value; consumed }
  | Error P.Partial -> Or_error.errorf "Partial"
  | Error (Fail error) -> Error (Error.tag error ~tag:"Parse error")
;;

let%expect_test "can parse single request" =
  print_s
    ([%sexp_of: Request.t success Or_error.t] (parse_or_error (P.parse_request req)));
  [%expect
    {|
    (Ok
     ((consumed 706)
      (value
       ((meth GET)
        (path /wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg)
        (version Http_1_1)
        (headers
         ((Host www.kittyhell.com)
          (User-Agent
           "Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) Gecko/20100401 Firefox/3.6.3 Pathtraq/0.9")
          (Accept
           "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
          (Accept-Language "ja,en-us;q=0.7,en;q=0.3")
          (Accept-Encoding gzip,deflate)
          (Accept-Charset "Shift_JIS,utf-8;q=0.7,*;q=0.7") (Keep-Alive 115)
          (Connection keep-alive)
          (Cookie
           "wp_ozh_wsa_visits=2; wp_ozh_wsa_visit_lasttime=xxxxxxxxxx; __utma=xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x; __utmz=xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral"))))))) |}]
;;

let%expect_test "reject headers with space before colon" =
  let req =
    Bigstring.of_string
      "GET / HTTP/1.1\r\nHost : www.kittyhell.com\r\nKeep-Alive: 115\r\n\r\n"
  in
  print_s
    ([%sexp_of: Request.t success Or_error.t] (parse_or_error (P.parse_request req)));
  [%expect {| (Error ("Parse error" "Invalid Header Key")) |}]
;;

let more_requests =
  Bigstring.of_string
    "GET / HTTP/1.1\r\n\
     Host: www.reddit.com\r\n\
     User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) \r\n\
    \   Gecko/20100101 Firefox/15.0.1\r\n\
     Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n\
     Accept-Language: en-us,en;q=0.5\r\n\
     Accept-Encoding: gzip, deflate\r\n\
     Connection: keep-alive\r\n\
     \r\n\
     GET /reddit.v_EZwRzV-Ns.css HTTP/1.1\r\n\
     Host: www.redditstatic.com\r\n\
     User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) Gecko/20100101 \
     Firefox/15.0.1\r\n\
     Accept: text/css,*/*;q=0.1\r\n\
     Accept-Language: en-us,en;q=0.5\r\n\
     Accept-Encoding: gzip, deflate\r\n\
     Connection: keep-alive\r\n\
     Referer: http://www.reddit.com/\r\n\
     \r\n"
;;

let%expect_test "can parse request at offset" =
  print_s
    ([%sexp_of: Request.t success Or_error.t]
       (parse_or_error (P.parse_request ~pos:304 more_requests)));
  [%expect
    {|
    (Ok
     ((consumed 315)
      (value
       ((meth GET) (path /reddit.v_EZwRzV-Ns.css) (version Http_1_1)
        (headers
         ((Host www.redditstatic.com)
          (User-Agent
           "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) Gecko/20100101 Firefox/15.0.1")
          (Accept "text/css,*/*;q=0.1") (Accept-Language "en-us,en;q=0.5")
          (Accept-Encoding "gzip, deflate") (Connection keep-alive)
          (Referer http://www.reddit.com/))))))) |}]
;;

let%expect_test "can report a partial parse" =
  print_s
    ([%sexp_of: Request.t success Or_error.t]
       (parse_or_error (P.parse_request ~len:50 req)));
  [%expect {| (Error Partial) |}]
;;

let%expect_test "can validate http version" =
  let req =
    Bigstring.of_string
      "GET / HTTP/1.4\r\nHost: www.kittyhell.com\r\nKeep-Alive: 115\r\n\r\n"
  in
  print_s
    ([%sexp_of: Request.t success Or_error.t] (parse_or_error (P.parse_request req)));
  [%expect {| (Error ("Parse error" ("Invalid http version" 4))) |}]
;;

let%expect_test "parse result indicates location of start of body" =
  let req =
    Bigstring.of_string
      "POST / HTTP/1.1\r\n\
       Host: localhost:8080\r\n\
       User-Agent: curl/7.64.1\r\n\
       Accept: */*\r\n\
       Content-Length: 6\r\n\
       Content-Type: application/x-www-form-urlencoded\r\n\
       \r\n\
       foobar"
  in
  let { consumed; _ } = Or_error.ok_exn (parse_or_error (P.parse_request req)) in
  print_endline
    (Bigstring.To_string.sub req ~pos:consumed ~len:(Bigstring.length req - consumed));
  [%expect {| foobar |}]
;;

open Base_quickcheck

let parse_chunk_length () =
  Test.run_exn
    (module struct
      type t = int [@@deriving quickcheck, sexp_of]
    end)
    ~f:(fun num ->
      let payload =
        let s = Bigstring.of_string (Printf.sprintf "%x\r\n" num) in
        s
      in
      match P.parse_chunk_length payload with
      | Ok res ->
        [%test_eq: int * int] res (num, String.length (Printf.sprintf "%x" num) + 2)
      | Error (P.Fail _) -> ()
      | Error _ -> assert false)
;;

let chunk_length_parse_case_insensitive () =
  let run_test num str =
    let buf = Bigstring.of_string str in
    match P.parse_chunk_length buf with
    | Ok res ->
      [%test_eq: int * int] res (num, String.length (Printf.sprintf "%x" num) + 2)
    | Error (P.Fail _) -> ()
    | Error _ -> assert false
  in
  Test.run_exn
    (module struct
      type t = int [@@deriving quickcheck, sexp_of]
    end)
    ~f:(fun num ->
      let payload = Printf.sprintf "%x\r\n" num in
      run_test num (String.uppercase payload);
      run_test num (String.lowercase payload))
;;

let%expect_test "can parse chunk lengths" =
  List.iter
    ~f:(fun buf ->
      printf
        !"input: %S, parse_result: %{sexp: int success Or_error.t} \n"
        buf
        (parse_or_error (P.parse_chunk_length (Bigstring.of_string buf))))
    [ "ab2\r\n"
    ; "4511ab\r\n"
    ; "4511ab  ; a\r\n"
    ; "4511ab; now in extension\r\n"
    ; "4511ab a ; now in extension\r\n"
    ; "111111111111111\r\n"
    ; "1111111111111111\r\n"
    ; "abc\r12"
    ; "abc\n12"
    ; "121"
    ; "121\r"
    ];
  [%expect
    {|
    input: "ab2\r\n", parse_result: (Ok ((consumed 5) (value 2738)))
    input: "4511ab\r\n", parse_result: (Ok ((consumed 8) (value 4526507)))
    input: "4511ab  ; a\r\n", parse_result: (Ok ((consumed 13) (value 4526507)))
    input: "4511ab; now in extension\r\n", parse_result: (Ok ((consumed 26) (value 4526507)))
    input: "4511ab a ; now in extension\r\n", parse_result: (Error ("Parse error" ("Invalid chunk_length character" a)))
    input: "111111111111111\r\n", parse_result: (Ok ((consumed 17) (value 76861433640456465)))
    input: "1111111111111111\r\n", parse_result: (Error ("Parse error" "Chunk size is too large"))
    input: "abc\r12", parse_result: (Error ("Parse error" Expected_newline))
    input: "abc\n12", parse_result: (Error ("Parse error" ("Invalid chunk_length character" "\n")))
    input: "121", parse_result: (Error Partial)
    input: "121\r", parse_result: (Error Partial) |}]
;;
