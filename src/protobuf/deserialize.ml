(** Module for deserializing values *)

open StdLabels
open Result
open Infix.Result

type error =
  [ Reader.error
  | `Wrong_field_type of string * Spec.field
  | `Illegal_value of string * Spec.field
  | `Not_implemented
  | `Unknown_enum_value of int
  | `Oneof_missing
  | `Required_field_missing ]
[@@deriving show]

type nonrec 'a result = ('a, error) Result.t

type 'a sentinal = unit -> 'a result
type 'a decoder = Spec.field -> 'a result
type 'a default = Proto3 | Proto2 of 'a option | Required
type packed = Packed | Not_packed

type _ spec =
  | Double : float spec
  | Float : float spec

  | Int32 : Int32.t spec
  | UInt32 : Int32.t spec
  | SInt32 : Int32.t spec
  | Fixed32 : Int32.t spec
  | SFixed32 : Int32.t spec

  | Int32_int : int spec
  | UInt32_int : int spec
  | SInt32_int : int spec
  | Fixed32_int : int spec
  | SFixed32_int : int spec

  | UInt64 : Int64.t spec
  | Int64 : Int64.t spec
  | SInt64 : Int64.t spec
  | Fixed64 : Int64.t spec
  | SFixed64 : Int64.t spec

  | UInt64_int : int spec
  | Int64_int : int spec
  | SInt64_int : int spec
  | Fixed64_int : int spec
  | SFixed64_int : int spec

  | Bool : bool spec
  | String : string spec
  | Bytes : bytes spec
  | Enum: (int -> 'a result) -> 'a spec
  | Message: (Reader.t -> 'a result) -> 'a spec
  | Message_opt: (Reader.t -> 'a result) -> 'a option spec

type _ oneof =
  | Oneof_elem : (int * 'b spec * ('b -> 'a)) -> 'a oneof

type _ compound =
  | Basic : int * 'a spec * 'a default -> 'a compound
  | Repeated : int * 'a spec * packed -> 'a list compound
  | Oneof : 'a oneof list -> 'a compound

type (_, _) compound_list =
  | Nil : ('a, 'a) compound_list
  | Cons : ('a compound) * ('b, 'c) compound_list -> ('a -> 'b, 'c) compound_list

type (_, _) sentinal_list =
  | SNil : ('a, 'a) sentinal_list
  | SCons : ('a sentinal) * ('b, 'c) sentinal_list -> ('a -> 'b, 'c) sentinal_list


let error_wrong_field str field : _ result =
  `Wrong_field_type (str, field) |> Result.fail

let error_illegal_value str field : _ result = `Illegal_value (str, field) |> Result.fail

let read_varint ~signed ~type_name =
  let open! Infix.Int64 in
  function
  | Spec.Varint v -> begin
      let v = match signed with
        | true when v % 2L = 0L -> v / 2L
        | true -> (v / 2L * -1L) - 1L
        | false -> v
      in
      return v
    end
  | field -> error_wrong_field type_name field

let read_varint32 ~signed ~type_name field =
  read_varint ~signed ~type_name field >>| Int64.to_int32

let rec type_of_spec: type a. a spec -> 'b * a decoder =
  let int_of_int32 spec =
    let (tpe, f) = type_of_spec spec in
    let f field =
      f field >>| Int32.to_int
    in
    (tpe, f)
  in

  let int_of_int64 spec =
    let (tpe, f) = type_of_spec spec in
    let f field =
      f field >>| Int64.to_int
    in
    (tpe, f)
  in
  function
  | Double -> (`Fixed_64_bit, function
      | Spec.Fixed_64_bit v -> return (Int64.float_of_bits v)
      | field -> error_wrong_field "double" field)
  | Float -> (`Fixed_32_bit, function
      | Spec.Fixed_32_bit v -> return (Int32.float_of_bits v)
      | field -> error_wrong_field "float" field)
  | Int32 -> (`Varint, read_varint32 ~signed:false ~type_name:"int32")
  | Int32_int -> int_of_int32 Int32
  | Int64 ->  (`Varint, read_varint ~signed:false ~type_name:"int64")
  | Int64_int -> int_of_int64 Int64
  | UInt32 -> (`Varint, read_varint32 ~signed:false ~type_name:"uint32")
  | UInt32_int -> int_of_int32 UInt32
  | UInt64 -> (`Varint, read_varint ~signed:false ~type_name:"uint64")
  | UInt64_int -> int_of_int64 UInt64
  | SInt32 -> (`Varint, read_varint32 ~signed:true ~type_name:"sint32")
  | SInt32_int -> int_of_int32 SInt32
  | SInt64 -> (`Varint, read_varint ~signed:true ~type_name:"sint64")
  | SInt64_int -> int_of_int64 SInt64
  | Fixed32 -> (`Fixed_32_bit, function
      | Spec.Fixed_32_bit v -> return (v)
      | field -> error_wrong_field "fixed32" field)
  | Fixed32_int -> int_of_int32 Fixed32
  | Fixed64 -> (`Fixed_64_bit, function
      | Spec.Fixed_64_bit v -> return v
      | field -> error_wrong_field "fixed64" field)
  | Fixed64_int -> int_of_int64 Fixed64

  | SFixed32 -> (`Fixed_32_bit, function
      | Spec.Fixed_32_bit v -> return v
      | field -> error_wrong_field "sfixed32" field)
  | SFixed32_int -> int_of_int32 SFixed32
  | SFixed64 -> (`Fixed_64_bit, function
      | Spec.Fixed_64_bit v -> return v
      | field -> error_wrong_field "sfixed64" field)
  | SFixed64_int -> int_of_int64 SFixed64
  | Bool -> (`Varint, function
      | Spec.Varint v -> return (Int64.equal v 0L |> not)
      | field -> error_wrong_field "bool" field)
  | Enum of_int -> (`Varint, function
      | Spec.Varint v -> of_int (Int64.to_int v)
      | field -> error_wrong_field "enum" field)
  | String -> (`Length_delimited, function
      | Spec.Length_delimited {offset; length; data} -> return (String.sub ~pos:offset ~len:length data)
      | field -> error_wrong_field "string" field)
  | Bytes -> (`Length_delimited, function
      | Spec.Length_delimited {offset; length; data} -> return (String.sub ~pos:offset ~len:length data |> Bytes.of_string)
      | field -> error_wrong_field "string" field)
  | Message from_proto -> (`Length_delimited, function
      | Spec.Length_delimited {offset; length; data} -> from_proto (Reader.create ~offset ~length data)
      | field ->  error_wrong_field "message" field)
  | Message_opt from_proto -> (`Length_delimited, function
      | Spec.Length_delimited {offset; length; data} -> from_proto (Reader.create ~offset ~length data) >>| Option.some
      | field ->  error_wrong_field "message" field)


let default_of_field_type = function
  | `Fixed_32_bit -> Spec.fixed_32_bit Int32.zero
  | `Fixed_64_bit -> Spec.fixed_64_bit Int64.zero
  | `Length_delimited -> Spec.length_delimited ""
  | `Varint -> Spec.Varint 0L

let sentinal: type a. a compound -> (int * unit decoder) list * a sentinal = function
  | Basic (_index, (Message_opt _deser), Required) -> failwith "Required messages should be option types"
  | Basic (index, (Message_opt deser), _) ->
    let v = ref None in
    let get () = return !v in
    let read = function
      | Spec.Length_delimited {offset; length; data} ->
        let reader = Reader.create ~length ~offset data in
        deser reader >>| fun message -> v := Some message
      | field -> error_wrong_field "message" field
    in
    ([index, read], get)

  | Basic (index, spec, Required) ->
    let _, read = type_of_spec spec in
    let v = ref None in
    let get () = match !v with
      | Some v -> return v
      | None -> Error `Required_field_missing
    in
    let read field =
      read field >>| fun value -> v := Some value
    in
    ([index, read], get)
  | Basic (index, spec, default) ->
    let field_type, read = type_of_spec spec in
    let default = match default with
      | Proto2 (Some default) -> default
      | Required
      | Proto2 None
      | Proto3 -> begin
          default_of_field_type field_type
          |> read
          |> function
          | Ok v -> v
          | Error _ -> failwith "Default value not decodeable"
        end
    in
    let v = ref default in
    let get () = return !v in
    let read field =
      read field >>| fun value -> v := value
    in
    ([index, read], get)
  | Repeated (index, spec, _) ->
    let read_field = function
      | `Length_delimited -> None
      | `Varint -> Some Reader.read_varint
      | `Fixed_64_bit -> Some Reader.read_fixed64
      | `Fixed_32_bit -> Some Reader.read_fixed32
    in
    let rec read_repeated reader decode read_f = match Reader.has_more reader with
      | false -> return ()
      | true ->
        decode reader >>= fun field ->
          read_f field >>= fun () ->
            read_repeated reader decode read_f
    in
    let (field_type, read_type) = type_of_spec spec in
    let v = ref [] in
    let get () = return (List.rev !v) in
    let rec read field = match field, read_field field_type with
      | (Spec.Length_delimited _ as field), None ->
        read_type field >>| fun v' -> v := v' :: !v
      | Spec.Length_delimited { offset; length; data }, Some read_field ->
        read_repeated (Reader.create ~offset ~length data) read_field read
      | field, _ -> read_type field >>| fun v' -> v := v' :: !v
    in
    ([index, read], get)
  | Oneof oneofs ->
    let make_reader: a result ref -> a oneof -> (int * unit decoder) = fun v (Oneof_elem (index, spec, constr)) ->
      let _, read = type_of_spec spec in
      let read field =
        read field >>| fun value -> v := Ok (constr value)
      in
      (index, read)
    in
    let v = ref (Error `Oneof_missing) in
    let get () = !v in
    List.map ~f:(make_reader v) oneofs, get

module Map = struct
  include Map.Make (struct type t = int let compare = compare end)
  let of_alist_exn l = List.fold_left ~init:empty ~f:(fun acc (k, v) ->
    if mem k acc then
      invalid_arg "Duplicate keys in list"
    else
      add k v acc
  ) l
end

(** Read fields - map based for nlogn lookup *)
let read_fields_map reader_list =
  let map = Map.of_alist_exn reader_list in
  let rec read reader =
    match Reader.has_more reader with
    | false -> return ()
    | true -> begin
        match Reader.read_field reader with
        | Ok (index, field) -> begin
            match Map.find_opt index map with
            | Some f ->
              f field >>= fun () ->
              read reader
            | None ->
              read reader
          end
        | Error err -> Error (err :> error)
      end
  in
  read

(** Read fields - array based for O(1) lookup *)
let read_fields_array max_index reader_list =
  let default _ = Ok () in
  let readers = Array.init (max_index + 1) ~f:(fun _ -> default) in
  List.iter ~f:(fun (idx, f) -> readers.(idx) <- f) reader_list;

  let rec read reader =
    match Reader.has_more reader with
    | false -> return ()
    | true -> begin
        match Reader.read_field reader with
        | Ok (index, field) when index <= max_index ->
          readers.(index) field >>= fun () ->
          read reader
        | Ok _ -> return ()
        | Error err -> Error (err :> error)
      end
  in
  read

let deserialize: type constr t. (constr, t) compound_list -> constr -> Reader.t -> t result = fun spec constr ->
  let max_index =
    let rec inner: type a b. int -> (a, b) compound_list -> int = fun acc -> function
      | Cons (Oneof oneofs, rest) ->
        let rec max_elt: type c. int -> c oneof list -> int = fun acc -> function
          | Oneof_elem (idx, _, _) :: rest -> max_elt (max idx acc) rest
          | [] -> acc
        in
        let acc = max_elt acc oneofs in
        inner acc rest
      | Cons (Basic (idx, _, _), rest) ->
        inner (max acc idx) rest
      | Cons (Repeated (idx, _, _), rest) ->
        inner (max acc idx) rest
      | Nil -> acc
    in
    inner 0 spec
  in
  (* For even better optimization, the first pass could assume that
     all fields are written (if at all) in the same order as the spec.
     If we reach the end of the reader list, we revert to use read_fields_array
     or read_fields_map
  *)
  let read_fields = match max_index < 1024 with
    | true -> read_fields_array max_index
    | false -> read_fields_map
  in
  let rec apply: type constr t. constr -> (constr, t) sentinal_list -> t result = fun constr -> function
    | SCons (sentinal, rest) ->
      sentinal () >>= fun v -> apply (constr v) rest
    | SNil -> return constr
  in
  (* We first make a list of sentinal_getters, which we can map to the constr *)
  let rec make_sentinals: type a b. (a, b) compound_list -> (a, b) sentinal_list * (int * unit decoder) list = function
    | Cons (spec, rest) ->
      (* Ouch. Oneofs would return multiple reads and indexes, but only one sentinal *)
      let (readers, sentinal) = sentinal spec in
      (* Fuck. This is getting all backwards. *)
      let (sentinals, reader_list) = make_sentinals rest in
      SCons (sentinal, sentinals), List.rev_append readers reader_list
    | Nil -> SNil, []
  in
  fun reader ->
    let sentinals, reader_list = make_sentinals spec in
    (* Read the fields one by one, and apply the reader - if found *)
    read_fields reader_list reader >>= fun () -> apply constr sentinals


(** Module to construct a spec *)
module C = struct
  let double = Double
  let float = Float
  let int32 = Int32
  let int64 = Int64
  let uint32 = UInt32
  let uint64 = UInt64
  let sint32 = SInt32
  let sint64 = SInt64
  let fixed32 = Fixed32
  let fixed64 = Fixed64
  let sfixed32 = SFixed32
  let sfixed64 = SFixed64

  let int32_int = Int32_int
  let int64_int = Int64_int
  let uint32_int = UInt32_int
  let uint64_int = UInt64_int
  let sint32_int = SInt32_int
  let sint64_int = SInt64_int
  let fixed32_int = Fixed32_int
  let fixed64_int = Fixed64_int
  let sfixed32_int = SFixed32_int
  let sfixed64_int = SFixed64_int

  let bool = Bool
  let string = String
  let bytes = Bytes
  let enum f = Enum f
  let message f = Message f
  let message_opt f = Message_opt f

  let some v = Some v
  let none = None
  let proto2 v = Proto2 v
  let proto2_bytes v = Proto2 (Some (Bytes.of_string v))
  let proto3 = Proto3
  let required = Required

  let repeated (i, s, p) = Repeated (i, s, p)
  let basic (i, s, d) = Basic (i, s, d)
  let oneof s = Oneof s
  let oneof_elem s = Oneof_elem s

  let packed = Packed
  let not_packed = Not_packed

  let ( ^:: ) a b = Cons (a, b)
  let nil = Nil
end
