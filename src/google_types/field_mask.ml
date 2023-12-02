(************************************************)
(*       AUTOGENERATED FILE - DO NOT EDIT!      *)
(************************************************)
(* Generated by: ocaml-protoc-plugin            *)
(* https://github.com/issuu/ocaml-protoc-plugin *)
(************************************************)
(*
  Source: google/protobuf/field_mask.proto
  Syntax: proto3
  Parameters:
    debug=false
    annot='[@@deriving sexp_of]'
    opens=[Core]
    int64_as_int=true
    int32_as_int=true
    fixed_as_int=false
    singleton_record=false
*)

open Ocaml_protoc_plugin.Runtime [@@warning "-33"]
open Core [@@warning "-33"]
module Google = struct
  module Protobuf = struct
    module rec FieldMask : sig
      val name': unit -> string
      type t = string list [@@deriving sexp_of]
      val make : ?paths:string list -> unit -> t
      val to_proto: t -> Runtime'.Writer.t
      val from_proto: Runtime'.Reader.t -> (t, [> Runtime'.Result.error]) result
    end = struct 
      let name' () = "field_mask.google.protobuf.FieldMask"
      type t = string list[@@deriving sexp_of]
      let make =
        fun ?paths () -> 
        let paths = match paths with Some v -> v | None -> [] in
        paths
      
      let to_proto =
        let apply = fun ~f:f' paths -> f' [] paths in
        let spec = Runtime'.Serialize.C.( repeated (1, string, packed) ^:: nil ) in
        let serialize = Runtime'.Serialize.serialize [] (spec) in
        fun t -> apply ~f:serialize t
      
      let from_proto =
        let constructor = fun _extensions paths -> paths in
        let spec = Runtime'.Deserialize.C.( repeated (1, string, packed) ^:: nil ) in
        let deserialize = Runtime'.Deserialize.deserialize [] spec constructor in
        fun writer -> deserialize writer |> Runtime'.Result.open_error
      
    end
  end
end