(** Module for deserializing values *)
open! StdLabels
open Spec

module FieldMap = Map.Make(String)
type fields = Yojson.Basic.t FieldMap.t

let value_error type_name json =
  Result.raise (`Wrong_field_type (type_name, Yojson.Basic.to_string json))

let to_int64 = function
  | `String s -> Int64.of_string s
  | `Int v -> Int64.of_int v
  | json -> value_error "int64" json
let to_int json = to_int64 json |> Int64.to_int
let to_int32 = function
  | `String s -> Int32.of_string s
  | `Int v -> Int32.of_int v
  | json -> value_error "int32" json
let to_string = function
  | `String s -> s
  | json -> value_error "string" json
let to_bytes json = to_string json |> Base64.decode_exn |> Bytes.of_string
let to_enum: type a. (module Spec.Enum with type t = a) -> Yojson.Basic.t -> a = fun (module Enum) -> function
  | `String enum -> Enum.from_string_exn enum
  | `Int enum -> Enum.from_int_exn enum
  | json -> value_error "enum" json

let to_float = function
  | `Float f -> f
  | `Int i -> Float.of_int i
  | `String s -> Float.of_string s
  | json -> value_error "float" json

let to_bool = function
  | `Bool b -> b
  | `String "true" -> true
  | `String "false" -> false
  | json -> value_error "bool" json

let to_list = function
  | `List l -> l
  | json -> value_error "list" json

let read_map: type a b. read_key:(string -> a) -> read_value:(Yojson.Basic.t -> b) -> Yojson.Basic.t -> (a * b) list =
  fun ~read_key ~read_value -> function
    | `Assoc entries ->
      List.map ~f:( fun (key, value) ->
        let key = read_key key in
        let value = read_value value in
        (key, value)
      ) entries
    | json -> value_error "map_entry" json

(** What a strange encoding.
    Durations less than one second are represented with a 0 seconds field and a positive or negative nanos field. For durations of one second or more, a non-zero value for the nanos field must be of the same sign as the seconds field.
*)
let duration_of_json json =
  (* Capture the signedness of the duration, and apply to both seconds and nanos *)
  (* nanos can be 0, 3, 6 or 9 digits *)
  (* must end with a 's' *)

  try
    let s = Yojson.Basic.Util.to_string json in
    assert (String.get s (String.length s - 1) = 's');
    let sign, s = match String.get s 0 = '-' with
      | true -> (-1), String.sub s ~pos:1 ~len:(String.length s - 2)
      | false -> 1, String.sub s ~pos:0 ~len:(String.length s - 1)
    in
    let seconds, nanos = match String.split_on_char ~sep:'.' s with
      | [seconds; nanos] -> seconds, nanos
      | [seconds] -> seconds, "000"
      | _ -> failwith "Too many '.' in string"
    in
    let seconds = int_of_string seconds in
    let nano_fac = match String.length nanos with
      | 3 -> 1_000_000
      | 6 -> 1000
      | 9 -> 1
      | _ -> failwith "Nanos should be either 0, 3, 6 or 9 digits"
    in

    let nanos = int_of_string nanos * nano_fac in
    assert (seconds >= 0 && nanos >= 0);
    (seconds * sign, nanos * sign)
  with
  | _ -> value_error "google.protobuf.duration" json

let%expect_test "google.protobuf.Duration" =
  let test str =
    try
      let (s,n) = duration_of_json (`String str) in
      Printf.printf "D: %s -> %d.%09ds\n" str s n
    with
    | Result.Error e -> Printf.printf "Error parsing %s: %s\n" str (Result.show_error e)
  in
  test "1s";
  test "-1s";
  test "1.001s";
  test "-1.001s";
  test "1.1";
  test "1.-10s";
  ();
  [%expect {|
    D: 1s -> 1.000000000s
    D: -1s -> -1.000000000s
    D: 1.001s -> 1.001000000s
    D: -1.001s -> -1.-01000000s
    Error parsing 1.1: `Wrong_field_type (("google.protobuf.duration", "\"1.1\""))
    Error parsing 1.-10s: `Wrong_field_type (("google.protobuf.duration", "\"1.-10s\"")) |}]

let timestamp_of_json = function
  | `String timestamp ->
    let t =
      match Ptime.of_rfc3339 timestamp with
      | Ok (t, _, _) -> t
      | Error _e -> value_error "google.protobuf.duration" (`String timestamp)
    in
    let seconds = Ptime.to_float_s t |> Float.to_int in
    let nanos = Ptime.frac_s t |> Ptime.Span.to_float_s |> Float.mul 1_000_000_000.0 |> Float.to_int in
    (seconds, nanos)
  | json -> value_error "google.protobuf.timestamp" json

let%expect_test "google.protobuf.Timestamp" =
  let test str =
    try
      let (s, n) = timestamp_of_json (`String str) in
      Printf.printf "D: %s -> %d.%09ds\n" str s n
    with
    | Result.Error e -> Printf.printf "Error parsing %s: %s\n" str (Result.show_error e)
  in
  test "1972-01-01T10:00:20.021Z";
  test "2024-03-06T21:10:27.020Z";
  test "2024-03-06T21:10:27.123123123Z";
  test "2024-03-06T21:10:27.999999Z";
  test "2024-03-06T21:10:27.999999";
  ();
  [%expect {|
    D: 1972-01-01T10:00:20.021Z -> 63108020.021000000s
    D: 2024-03-06T21:10:27.020Z -> 1709759427.020000000s
    D: 2024-03-06T21:10:27.123123123Z -> 1709759427.123123123s
    D: 2024-03-06T21:10:27.999999Z -> 1709759427.999999000s
    Error parsing 2024-03-06T21:10:27.999999: `Wrong_field_type (("google.protobuf.duration",
                        "\"2024-03-06T21:10:27.999999\"")) |}]



let read_value: type a b. (a, b) spec -> Yojson.Basic.t -> a = function
   | Double -> to_float
   | Float -> to_float
   | Int32 -> to_int32
   | UInt32 -> to_int32
   | SInt32 -> to_int32
   | Fixed32 -> to_int32
   | SFixed32 -> to_int32
   | Int32_int -> to_int
   | UInt32_int -> to_int
   | SInt32_int -> to_int
   | Fixed32_int -> to_int
   | SFixed32_int -> to_int
   | UInt64 -> to_int64
   | Int64 -> to_int64
   | SInt64 -> to_int64
   | Fixed64 -> to_int64
   | SFixed64 -> to_int64
   | UInt64_int -> to_int
   | Int64_int -> to_int
   | SInt64_int -> to_int
   | Fixed64_int -> to_int
   | SFixed64_int -> to_int
   | Bool -> to_bool
   | String -> to_string
   | Bytes -> to_bytes
   | Enum (module Enum) -> to_enum (module Enum)
   | Message ((module Message), Empty) -> begin
       function
       | `Assoc [] -> Message.from_tuple ()
       | json -> value_error "google.protobuf.empty" json
     end
   | Message ((module Message), Duration) ->
     fun json -> duration_of_json json |> Message.from_tuple
   | Message ((module Message), Timestamp) ->
     fun json -> timestamp_of_json json |> Message.from_tuple
   | Message ((module Message), Default) -> Message.from_json_exn

let find_field (_number, field_name, json_name) fields =
  match FieldMap.find_opt json_name fields with
  | Some value -> Some value
  | None -> FieldMap.find_opt field_name fields

let rec read: type a b. fields -> (a, b) Spec.compound -> a = fun fields -> function
  | Basic (index, spec, default) ->
    begin
      match find_field index fields with
      | Some field -> read_value spec field
      | None -> default
    end
  | Basic_opt (index, spec) ->
    begin
      match find_field index fields with
      | Some field -> Some (read_value spec field)
      | None -> None
    end
  | Basic_req (index, spec) ->
    begin
      match find_field index fields with
      | Some field -> read_value spec field
      | None -> Result.raise (`Required_field_missing (0, ""))
    end
  | Repeated (index, spec, _packed) ->
    begin
      match find_field index fields with
      | Some field ->
        let read = read_value spec in
        to_list field |> List.map ~f:read
      | None -> []
    end
  | Map (index, (key_spec, Basic (_, value_spec, _))) ->
    let read_key = read_value key_spec in
    let read_key v = read_key (`String v) in
    let read_value = read_value value_spec in
    begin match find_field index fields with
    | Some field ->
      read_map ~read_key ~read_value field
    | None -> []
    end
  | Map (index, (key_spec, Basic_opt (_, value_spec))) ->
    let read_key = read_value key_spec in
    let read_key v = read_key (`String v) in
    let read_value = read_value value_spec in
    let read_value = function
      | `Null -> None
      | json -> Some (read_value json)
    in
    begin match find_field index fields with
    | Some field ->
      read_map ~read_key ~read_value field
    | None -> []
    end
  | Oneof (oneofs, _) ->
    let rec inner = function
      | Oneof_elem (index, spec, (constr, _)) :: rest ->
        begin
          match read fields (Spec.Basic_opt (index, spec)) with
          | Some v -> constr v
          | None -> inner rest
        end
      | [] -> `not_set
    in
    inner oneofs


let rec deserialize: type constr a. (constr, a) compound_list -> constr -> fields -> a = function
  | Nil -> fun constr _json -> constr
  | Nil_ext _extension_ranges -> fun constr _json -> constr [] (* TODO implement support for extensions *)
  | Cons (spec, rest) ->
    fun constr fields ->
      let v = read fields spec in
      deserialize rest (constr v) fields


let deserialize: type constr a. (constr, a) compound_list -> constr -> Yojson.Basic.t -> a =
  fun spec constr -> function
  | `Assoc fields ->
    fields
    |> List.filter ~f:(function (_, `Null) -> false | _ -> true)
    |> List.fold_left ~f:(fun map (key, value) -> FieldMap.add key value map) ~init:FieldMap.empty
    |> deserialize spec constr
  | json -> value_error "message" json
