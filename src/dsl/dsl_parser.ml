type error = {
  range : Dsl_syntax.range;
  message : string;
}

exception Failed of error

type state = {
  file : string;
  text : string;
  mutable pos : int;
}

let peek state =
  if state.pos < String.length state.text then Some state.text.[state.pos]
  else None

let range state start stop : Dsl_syntax.range =
  { file = state.file; start; stop }

let located state start value : _ Dsl_syntax.located =
  { value; range = range state start state.pos }

let fail state start stop message =
  raise (Failed { range = range state start stop; message })

let fail_here state message =
  let stop = ref state.pos in
  if !stop < String.length state.text then begin
    incr stop;
    while !stop < String.length state.text
          && Char.code state.text.[!stop] land 0xC0 = 0x80 do
      incr stop
    done
  end;
  fail state state.pos !stop message

let skip_whitespace state =
  while
    match peek state with
    | Some (' ' | '\t' | '\r' | '\n') -> true
    | _ -> false
  do
    state.pos <- state.pos + 1
  done

let expect state character =
  skip_whitespace state;
  if peek state = Some character then state.pos <- state.pos + 1
  else fail_here state (Printf.sprintf "Expected '%c'" character)

let is_start = function
  | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
  | _ -> false

let is_continue = function
  | '0' .. '9' | '\'' -> true
  | character -> is_start character

let identifier state =
  let start = state.pos in
  (match peek state with
   | Some character when is_start character -> ()
   | _ -> fail_here state "Expected an identifier");
  while
    match peek state with
    | Some character -> is_continue character
    | None -> false
  do
    state.pos <- state.pos + 1
  done;
  located state start (String.sub state.text start (state.pos - start))

let string_literal state =
  let start = state.pos in
  if peek state <> Some '"' then fail_here state "Expected a string";
  state.pos <- state.pos + 1;
  let buffer = Buffer.create 32 in
  let rec loop () =
    match peek state with
    | None | Some ('\n' | '\r') ->
        fail state start state.pos "Unterminated string"
    | Some '"' ->
        state.pos <- state.pos + 1;
        located state start (Buffer.contents buffer)
    | Some '\\' ->
        state.pos <- state.pos + 1;
        let character =
          match peek state with
          | Some '"' -> '"'
          | Some '\\' -> '\\'
          | Some 'n' -> '\n'
          | Some 'r' -> '\r'
          | Some 't' -> '\t'
          | _ -> fail_here state "Invalid string escape"
        in
        Buffer.add_char buffer character;
        state.pos <- state.pos + 1;
        loop ()
    | Some character ->
        Buffer.add_char buffer character;
        state.pos <- state.pos + 1;
        loop ()
  in
  loop ()

let integer_literal state =
  let start = state.pos in
  if peek state = Some '-' then state.pos <- state.pos + 1;
  let digits = state.pos in
  while
    match peek state with Some ('0' .. '9') -> true | _ -> false
  do state.pos <- state.pos + 1 done;
  if state.pos = digits then fail_here state "Expected integer digits";
  let text = String.sub state.text start (state.pos - start) in
  match int_of_string_opt text with
  | Some value -> value
  | None -> fail state start state.pos "Integer is out of range"

let rec data_value state : Dsl_syntax.value Dsl_syntax.located =
  skip_whitespace state;
  let start = state.pos in
  let value : Dsl_syntax.value =
    match peek state with
    | Some '"' -> String (string_literal state).value
    | Some ('-' | '0' .. '9') -> Int (integer_literal state)
    | Some '[' ->
        state.pos <- state.pos + 1;
        skip_whitespace state;
        let rec elements reversed =
          let element = data_value state in
          skip_whitespace state;
          match peek state with
          | Some ']' ->
              state.pos <- state.pos + 1;
              List.rev (element :: reversed)
          | Some ',' ->
              state.pos <- state.pos + 1;
              elements (element :: reversed)
          | _ -> fail_here state "Expected ',' or ']'"
        in
        if peek state = Some ']' then begin
          state.pos <- state.pos + 1;
          List []
        end else List (elements [])
    | Some '{' ->
        state.pos <- state.pos + 1;
        let rec fields reversed =
          skip_whitespace state;
          match peek state with
          | Some '}' ->
              state.pos <- state.pos + 1;
              List.rev reversed
          | None -> fail state start state.pos "Unterminated record"
          | _ ->
              let name = identifier state in
              expect state '=';
              let value = data_value state in
              let field : Dsl_syntax.field = { name; value } in
              fields (field :: reversed)
        in
        Record (fields [])
    | Some character when is_start character ->
        let word = identifier state in
        (match word.value with
         | "true" -> Bool true
         | "false" -> Bool false
         | _ ->
             fail state word.range.start word.range.stop
               "Expected a data value; names and calls are not supported here")
    | _ -> fail_here state "Expected a data value"
  in
  (* Values must end at whitespace, a separator, or a closing delimiter. *)
  (match peek state with
   | None | Some (' ' | '\t' | '\r' | '\n' | ',' | ']' | '}') -> ()
   | _ -> fail_here state "Expected a separator after data value");
  located state start value

let argument state =
  skip_whitespace state;
  let start = state.pos in
  let value =
    match peek state with
    | Some '"' -> Dsl_syntax.String (string_literal state).value
    | _ -> Dsl_syntax.Reference (identifier state).value
  in
  located state start value

let arguments state =
  expect state '(';
  skip_whitespace state;
  if peek state = Some ')' then begin
    state.pos <- state.pos + 1;
    []
  end else
    let rec loop acc =
      let value = argument state in
      skip_whitespace state;
      match peek state with
      | Some ')' ->
          state.pos <- state.pos + 1;
          List.rev (value :: acc)
      | Some ',' ->
          state.pos <- state.pos + 1;
          loop (value :: acc)
      | _ -> fail_here state "Expected ',' or ')'"
    in
    loop []

let rec invocation state =
  (* The caller consumed @; the function name must follow immediately. *)
  let name = identifier state in
  let arguments = arguments state in
  let after_arguments = state.pos in
  skip_whitespace state;
  let body =
    if peek state = Some '[' then Some (body state)
    else begin state.pos <- after_arguments; None end
  in
  { Dsl_syntax.name; arguments; body }

and body state =
  expect state '[';
  let opening = state.pos - 1 in
  let contents = ref [] in
  let buffer = Buffer.create 64 in
  let text_start = ref state.pos in
  let depth = ref 0 in
  let flush () =
    if Buffer.length buffer > 0 then begin
      contents :=
        located state !text_start (Dsl_syntax.Text (Buffer.contents buffer))
        :: !contents;
      Buffer.clear buffer
    end
  in
  let append character =
    Buffer.add_char buffer character;
    state.pos <- state.pos + 1
  in
  let rec loop () =
    match peek state with
    | None -> fail state opening state.pos "Unterminated body"
    | Some ']' when !depth = 0 ->
        flush ();
        state.pos <- state.pos + 1;
        List.rev !contents
    | Some '[' -> incr depth; append '['; loop ()
    | Some ']' -> decr depth; append ']'; loop ()
    | Some '@' ->
        flush ();
        let start = state.pos in
        state.pos <- state.pos + 1;
        let action = invocation state in
        contents := located state start (Dsl_syntax.Action action) :: !contents;
        text_start := state.pos;
        loop ()
    | Some '\\' ->
        state.pos <- state.pos + 1;
        (match peek state with
         | Some ('@' | '[' | ']' | '\\' as character) -> append character
         | _ -> Buffer.add_char buffer '\\');
        loop ()
    | Some character -> append character; loop ()
  in
  loop ()

let label state =
  skip_whitespace state;
  let name = identifier state in
  expect state '=';
  skip_whitespace state;
  let identity = string_literal state in
  Dsl_syntax.Label { name; identity }

let note state =
  skip_whitespace state;
  let target = identifier state in
  expect state '{';
  let title = ref None in
  let metadata = ref None in
  let contents = ref None in
  let rec fields () =
    skip_whitespace state;
    match peek state with
    | None -> fail_here state "Unterminated note"
    | Some '}' ->
        state.pos <- state.pos + 1;
        let title =
          match !title with
          | Some title -> title
          | None -> fail state target.range.start state.pos "Missing title"
        in
        let body =
          match !contents with
          | Some contents -> contents
          | None -> fail state target.range.start state.pos "Missing body"
        in
        Dsl_syntax.Note { target; title; metadata = !metadata; body }
    | _ ->
        let field = identifier state in
        expect state '=';
        skip_whitespace state;
        (match field.value with
         | "title" when !title = None -> title := Some (string_literal state)
         | "body" when !contents = None -> contents := Some (body state)
         | "metadata" when !metadata = None ->
             if peek state <> Some '{' then
               fail_here state "Expected a metadata record";
             metadata := Some (data_value state)
         | "title" | "body" | "metadata" ->
             fail state field.range.start field.range.stop "Duplicate field"
         | _ ->
             fail state field.range.start field.range.stop "Unknown note field");
        fields ()
  in
  fields ()

let parse ~file text =
  let state = { file; text; pos = 0 } in
  let rec declarations acc =
    skip_whitespace state;
    match peek state with
    | None -> List.rev acc
    | _ ->
        let start = state.pos in
        let keyword = identifier state in
        let declaration =
          match keyword.value with
          | "label" -> label state
          | "note" -> note state
          | _ ->
              fail state keyword.range.start keyword.range.stop
                "Expected 'label' or 'note'"
        in
        declarations (located state start declaration :: acc)
  in
  try Ok (declarations []) with Failed error -> Error error
