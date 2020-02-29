open Base

let is_ascii t = String.for_all ~f:(fun c -> Char.to_int c <= 0x7F) t

module Header_key = struct
  module T = struct
    type t = string [@@deriving sexp, compare]
  end

  include T
  include Comparable.Make (T)

  let of_string t =
    match is_ascii t with
    | true -> Ok (String.lowercase t)
    | false ->
      Error
        (Error.create
           "Header key needs to be ASCII"
           ("header_key", t)
           [%sexp_of: string * t])
  ;;

  let of_string_exn = Fn.compose Or_error.ok_exn of_string
  let to_string t = t
end

module Header_value = struct
  type t = string [@@deriving sexp, compare]

  let of_string t =
    match is_ascii t with
    | true -> Ok t
    | false ->
      Error
        (Error.create
           "Header value needs to be ascii"
           ("header_value", t)
           [%sexp_of: string * t])
  ;;

  let of_string_exn = Fn.compose Or_error.ok_exn of_string
  let to_string t = t
end

type t = Header_value.t list Map.M(Header_key).t [@@deriving sexp, compare]

let empty = Map.empty (module Header_key)
let of_list xs = Map.of_alist_multi (module Header_key) xs
let add key data t = Map.add_multi t ~key ~data
let find key t = Map.find t key

let add_if_missing key data t =
  match find key t with
  | None -> add key data t
  | Some _ -> t
;;

let to_alist t = Map.to_alist t
let remove key t = Map.remove t key
let pp fmt t = Sexp.pp fmt (sexp_of_t t)
let pp_hum fmt t = Sexp.pp_hum fmt (sexp_of_t t)

let content_length len =
  ( Header_key.of_string_exn "content-length"
  , Header_value.of_string_exn (Int64.to_string len) )
;;
