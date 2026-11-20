(** The public entry point for the core and language implementations. *)
module Core = Ospero_kernel

module Syntax = struct
  include Ospero_kernel.Syntax
  module Lang = Ospero_syntax.Lang
end
