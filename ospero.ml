module Core = Ospero_kernel

module Syntax = struct
  include Ospero_kernel.Syntax
  include Ospero_syntax.Rules
  module Lang = Ospero_syntax.Lang
end
