open StdLabels
open Ocaml_protoc_plugin


module Reference = struct
  open Ctypes
  open Foreign
  (* extern "C" char* protobuf2json(const char *google_include_dir, const char *proto, const char* type, const char* in_data)  *)
  let protobuf2json = foreign "protobuf2json" (string @-> string @-> string @-> string @-> int @-> returning string)
  let to_json ~proto_file ~message_type data =
    let include_path = "/usr/include/" in
    protobuf2json include_path proto_file message_type data (String.length data)
end

module type T = sig
  type t [@@deriving show, eq]
  val to_proto' : Writer.t -> t -> Writer.t
  val to_proto : t -> Writer.t
  val from_proto : Reader.t -> t Result.t
  val name' : unit -> string
  val merge: t -> t -> t
  val to_json: ?enum_names:bool -> ?json_names:bool -> ?omit_default_values:bool -> t -> Yojson.Basic.t
  val from_json_exn: Yojson.Basic.t -> t
  val from_json: Yojson.Basic.t -> t Result.t
end

let hexlify data =
  let acc = ref [] in
  String.iter ~f:(fun ch -> (acc := Char.code ch :: !acc)) data;
  List.rev !acc
  |> List.map ~f:(Printf.sprintf "%02x")
  |> String.concat ~sep:"-"
  |> Printf.printf "Buffer: '%s'\n"

let dump_protoc ?(protoc_args=[]) name data =
  let protobuf_file, type_name =
    match String.split_on_char ~sep:'.' name with
    | protobuf_name :: type_name ->
      Printf.sprintf "%s.proto" (String.uncapitalize_ascii protobuf_name),
      String.concat ~sep:"." type_name
      | _ -> failwith "Illegal type name"
  in
  let filename = Filename.temp_file name ".bin" in
  let cout = open_out filename in
  output_string cout data;
  close_out cout;
  Printf.printf "%!";
  let res = Sys.command
      (Printf.sprintf
         "protoc %s --decode=%s %s < %s 2>/dev/null"
         (String.concat ~sep:" " protoc_args)
         type_name
         protobuf_file
         filename)
  in
  Sys.remove filename;
  match res with
  | 0 -> ()
  | n -> Printf.printf "'protoc' exited with status code: %d\n" n

let test_merge (type t) (module M : T with type t = t) (t: t) =
  Test_runtime.set_stragegy Test_runtime.Standard;
  let iterations = [1;2;3;4] in
  let writer = Writer.init () in
  let _ =
    List.fold_left ~init:(writer, t) ~f:(fun (writer, expect) i ->
      let writer = M.to_proto' writer t in
      let contents = Writer.contents writer |> Reader.create in
      let () =
        match M.from_proto contents with
        | Error err ->  Printf.printf "Error decoding after %d iterations: %s\n" i (Result.show_error err)
        | Ok observed when M.equal expect observed -> ()
        | Ok observed ->
          Printf.printf "Wrong value after %d iterations\nExpect: %s\nObserved:%s\n" i ([%show: M.t] expect) ([%show: M.t] observed)
      in
      (writer, M.merge expect t)
    ) iterations
  in
  ()

let test_json ~debug (type t) (module M : T with type t = t) (t: t) =
  ignore debug;
  let json_ref t =
    let proto_file, message_type =
      match M.name' () |> String.split_on_char ~sep:'.' with
      | hd :: tl ->
        let proto_file = hd ^ ".proto" in
        let message_type = String.concat ~sep:"." tl in
        proto_file, message_type
      | _ -> failwith "Illegal name"
    in
    let proto = M.to_proto t |> Writer.contents in
    let json = Reference.to_json ~proto_file ~message_type proto in
    try
      Yojson.Basic.from_string json
    with
    | _ ->
      Printf.printf "Unable to parse reference json:\n  '%s'\n" json;
      failwith "Could not parse reference json"
  in

  let test_json ?enum_names ?json_names ?omit_default_values t =
    let compare ~message t json =
      match (M.from_json_exn json = t) with
      | true -> ()
      | false ->
        let observed = M.from_json_exn json |> json_ref in
        Printf.printf "Json encode/decode not identical. %s\n  Expect:  %s\n  Observe: %s\n" message
          (Yojson.Basic.to_string json) (Yojson.Basic.to_string observed)
      | exception exn ->
        Printf.printf "Json encode/decode failed for %s: %s\n" message (Yojson.Basic.to_string json);
        Printf.printf "  Error: %s\n" (Printexc.to_string exn);
    in
    (* May fail! *)
    let () =
      try
        let json = M.to_json ?enum_names ?json_names ?omit_default_values t in
        compare ~message:"Ocaml proto plugin" t json
      with | exn -> Printf.printf "Cannot serialize to json\n  Error: %s\n" (Printexc.to_string exn)
    in
    (* compare ~message:"Protobuf reference implementation" t (to_json_ref t); *)
    t
  in
  (* Compare reference json *)
  let () = try
      let json' = json_ref t in
      let t' = M.from_json_exn json' in
      if t <> t' then Printf.printf "Cannot deserialize reference json.\n";
      if t <> t' || debug then
        Printf.printf "Json: %s\nRef:  %s\n"
          (Yojson.Basic.pretty_to_string (M.to_json t))
          (Yojson.Basic.pretty_to_string json');
    with
    | exn -> Printf.printf "Cannot deserialize reference json\n  Error: %s\n" (Printexc.to_string exn);
  in
  t
  |> test_json
  |> test_json ~enum_names:false
  |> test_json ~json_names:false
  |> test_json ~omit_default_values:false
  |> test_json ~enum_names:false ~json_names:false ~omit_default_values:false
  |> ignore

let test_decode (type t) (module M : T with type t = t) strategy expect data =
  let reader = Reader.create data in
  Test_runtime.set_stragegy strategy;
  match M.from_proto reader with
  | Ok observed -> begin
      match M.equal expect observed with
      | true -> ()
      | false ->
        Printf.printf "\n%s: Expect: %s\nObserved:%s\n" (Test_runtime.show_strategy strategy) ([%show: M.t] expect) ([%show: M.t] observed)
     end
  | Error err ->
    Printf.printf "\n%s:Decode failed: %s \n" (Test_runtime.show_strategy strategy) (Result.show_error err)
  | exception exn ->
    Reader.reset reader 0;
    let fields = Reader.to_list reader in
    Printf.printf "\n%s:Decode failed: %s\n" (Test_runtime.show_strategy strategy) (Printexc.to_string exn);
    Printf.printf "\n%s:Data: %s\n" (Test_runtime.show_strategy strategy) (List.map ~f:fst fields |> List.map ~f:string_of_int |> String.concat ~sep:", ")

(** Create a common function for testing. *)
let test_encode (type t) ?dump ?(debug_json=false) ?(protoc=true) ?protoc_args (module M : T with type t = t) ?(skip_json=false) ?(validate : t option) ?(expect : t option) (t : t) =
  let expect = Option.value ~default:t expect in
  let () = match validate with
    | Some v when v <> expect -> Printf.printf "Validate match failed\n"
    | _ -> ()
  in
  let data = M.to_proto expect |> Writer.contents in
  let data_speed = M.to_proto' (Writer.init ~mode:Speed ()) expect |> Writer.contents in
  let data_space = M.to_proto' (Writer.init ~mode:Space ()) expect |> Writer.contents in
  let data_balanced = M.to_proto' (Writer.init ~mode:Balanced ()) expect |> Writer.contents in

  let () =
    match dump with
    | Some _ -> hexlify data
    | None -> ()
  in
  let () = match protoc with
    | true -> dump_protoc ?protoc_args (M.name' ()) data
    | false -> ()
  in

  test_decode (module M) Test_runtime.Standard expect data_space;
  test_decode (module M) Test_runtime.Standard expect data_speed;
  test_decode (module M) Test_runtime.Standard expect data_balanced;
  test_decode (module M) Test_runtime.Standard expect data;
  test_decode (module M) Test_runtime.Fast expect data;
  test_decode (module M) Test_runtime.Full expect data;
  test_merge (module M) expect;
  if (not skip_json) then test_json ~debug:debug_json (module M) expect;
  ()
