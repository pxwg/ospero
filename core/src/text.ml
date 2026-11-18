module Language = struct
  type t = string

  let of_string = function
    | "" -> Error "Language name must be non-empty"
    | name -> Ok name

  let to_string name = name
  let equal = String.equal
  let compare = String.compare
end

type t = {
  text : string;
  language : Language.t;
}
