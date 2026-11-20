(** The public entry point for the core and language implementations. *)
module Core = Ospero_kernel

(** The Syntax contract of the core, with rule tables for writing adapters
    and the default language adapters. *)
module Syntax = struct
  include Ospero_kernel.Syntax
  include Ospero_syntax.Rules
  module Lang = Ospero_syntax.Lang
end
