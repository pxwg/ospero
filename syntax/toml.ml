open Ospero_kernel
open Frontend

exception Error of Diagnostic.t

type state = { file : string; text : string; stop : int; mutable pos : int }

let span st start stop = { Provenance.file = st.file; start; stop }
let fail st ?(at = st.pos) message =
  raise (Error (Diagnostic.make ~span:(span st at (min st.stop (at + 1))) (Invalid ("TOML: " ^ message))))

let peek st = if st.pos < st.stop then Some st.text.[st.pos] else None
let looking st prefix =
  let n = String.length prefix in
  st.pos + n <= st.stop && String.sub st.text st.pos n = prefix

let rec blank st = match peek st with
  | Some (' ' | '\t') -> st.pos <- st.pos + 1; blank st
  | _ -> ()

let comment st =
  if peek st = Some '#' then
    while st.pos < st.stop && st.text.[st.pos] <> '\n' do st.pos <- st.pos + 1 done

(* Blank space, comments and newlines, as allowed inside arrays. *)
let rec space st =
  blank st; comment st;
  match peek st with
  | Some ('\n' | '\r') -> st.pos <- st.pos + 1; space st
  | _ -> ()

let line_end st =
  blank st; comment st;
  match peek st with
  | None -> ()
  | Some '\n' -> st.pos <- st.pos + 1
  | Some '\r' when st.pos + 1 < st.stop && st.text.[st.pos + 1] = '\n' -> st.pos <- st.pos + 2
  | Some _ -> fail st "expected the end of the line"

let bare = function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true | _ -> false

let escape st buffer =
  let hex n =
    if st.pos + n > st.stop then fail st "truncated unicode escape";
    let digits = String.sub st.text st.pos n in
    st.pos <- st.pos + n;
    match int_of_string_opt ("0x" ^ digits) with
    | Some code when Uchar.is_valid code -> Buffer.add_utf_8_uchar buffer (Uchar.of_int code)
    | _ -> fail st "invalid unicode escape"
  in
  match peek st with
  | None -> fail st "unterminated escape"
  | Some c ->
      st.pos <- st.pos + 1;
      match c with
      | 'b' -> Buffer.add_char buffer '\b'
      | 't' -> Buffer.add_char buffer '\t'
      | 'n' -> Buffer.add_char buffer '\n'
      | 'f' -> Buffer.add_char buffer '\012'
      | 'r' -> Buffer.add_char buffer '\r'
      | '"' -> Buffer.add_char buffer '"'
      | '\\' -> Buffer.add_char buffer '\\'
      | 'u' -> hex 4
      | 'U' -> hex 8
      | _ -> fail st ~at:(st.pos - 1) "unknown escape"

(* The opening delimiter has been consumed. A newline right after a
   multi-line opening delimiter is dropped. *)
let string_body st ~quote ~multi ~escapes =
  let buffer = Buffer.create 16 in
  let close = if multi then String.make 3 quote else String.make 1 quote in
  if multi then begin
    if looking st "\r\n" then st.pos <- st.pos + 2
    else if looking st "\n" then st.pos <- st.pos + 1
  end;
  let rec go () =
    if looking st close then st.pos <- st.pos + String.length close
    else match peek st with
      | None -> fail st "unterminated string"
      | Some '\n' when not multi -> fail st "newline in a single-line string"
      | Some '\\' when escapes -> st.pos <- st.pos + 1; escape st buffer; go ()
      | Some c -> Buffer.add_char buffer c; st.pos <- st.pos + 1; go ()
  in
  go ();
  Buffer.contents buffer

let string_literal st =
  let quote = st.text.[st.pos] in
  let multi = looking st (String.make 3 quote) in
  st.pos <- st.pos + (if multi then 3 else 1);
  string_body st ~quote ~multi ~escapes:(quote = '"')

let key_part st =
  let start = st.pos in
  match peek st with
  | Some ('"' | '\'') ->
      if looking st "\"\"\"" || looking st "'''" then fail st "multi-line strings cannot be keys";
      let name = string_literal st in
      Provenance.located ~span:(span st start st.pos) name
  | Some c when bare c ->
      while st.pos < st.stop && bare st.text.[st.pos] do st.pos <- st.pos + 1 done;
      Provenance.located ~span:(span st start st.pos) (String.sub st.text start (st.pos - start))
  | _ -> fail st "expected a key"

let rec key st =
  blank st;
  let part = key_part st in
  blank st;
  if peek st = Some '.' then (st.pos <- st.pos + 1; part :: key st) else [ part ]

let scalar_token st =
  let start = st.pos in
  let token = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '+' | '-' | '.' | ':' -> true
    | _ -> false
  in
  while st.pos < st.stop && token st.text.[st.pos] do st.pos <- st.pos + 1 done;
  if st.pos = start then fail st "expected a value";
  let raw = String.sub st.text start (st.pos - start) in
  let digits = String.concat "" (String.split_on_char '_' raw) in
  let value : Value.t =
    match raw with
    | "true" -> Bool true
    | "false" -> Bool false
    | _ ->
        let decimal = not (String.contains raw '.' || String.contains raw ':') in
        match decimal, int_of_string_opt digits with
        | true, Some i -> Int i
        | _ -> Other raw
  in
  Provenance.located ~span:(span st start st.pos) value

(* Entries keep their full key path until [group] nests them. A header with
   no entries still declares its table. *)
type entry = { path : string Provenance.located list; value : Value.t Provenance.located option }

let rec value st : Value.t Provenance.located =
  let start = st.pos in
  let at v = Provenance.located ~span:(span st start st.pos) v in
  match peek st with
  | Some ('"' | '\'') -> let s = string_literal st in at (Value.String s)
  | Some '[' ->
      st.pos <- st.pos + 1;
      let rec items acc =
        space st;
        if peek st = Some ']' then (st.pos <- st.pos + 1; List.rev acc)
        else begin
          let item = value st in
          space st;
          match peek st with
          | Some ',' -> st.pos <- st.pos + 1; items (item :: acc)
          | Some ']' -> st.pos <- st.pos + 1; List.rev (item :: acc)
          | _ -> fail st "expected , or ] in an array"
        end
      in
      let items = items [] in
      at (Value.Array items)
  | Some '{' ->
      st.pos <- st.pos + 1;
      let rec entries acc =
        blank st;
        if peek st = Some '}' && acc = [] then (st.pos <- st.pos + 1; [])
        else begin
          let entry = pair st in
          blank st;
          match peek st with
          | Some ',' -> st.pos <- st.pos + 1; entries (entry :: acc)
          | Some '}' -> st.pos <- st.pos + 1; List.rev (entry :: acc)
          | _ -> fail st "expected , or } in an inline table"
        end
      in
      let entries = entries [] in
      at (Value.Table (group entries))
  | _ -> scalar_token st

and pair st =
  let path = key st in
  blank st;
  if peek st <> Some '=' then fail st "expected =";
  st.pos <- st.pos + 1;
  blank st;
  { path; value = Some (value st) }

(* Nest dotted keys and headers into tables. Repeated keys are kept, so the
   decoder reports them as duplicates. *)
and group entries : Value.field list =
  let cover (spans : Provenance.span option list) =
    match List.filter_map Fun.id spans with
    | [] -> None
    | s :: rest ->
        Some (List.fold_left (fun (a : Provenance.span) (b : Provenance.span) ->
          { a with start = min a.start b.start; stop = max a.stop b.stop }) s rest)
  in
  let rec build = function
    | [] -> []
    | { path = []; _ } :: rest -> build rest
    | { path = [ name ]; value = Some v } :: rest -> (name, v) :: build rest
    | ({ path = name :: _; _ } :: _) as all ->
        let inside, rest =
          List.partition (fun e -> match e.path with
            | n :: _ :: _ -> n.Provenance.value = name.Provenance.value
            | [ n ] -> n.value = name.value && e.value = None
            | [] -> false) all
        in
        let inner = List.map (fun e -> { e with path = List.tl e.path }) inside in
        let spans =
          List.concat_map (fun e ->
            (List.hd e.path).Provenance.span ::
            (match e.value with Some v -> [ v.Provenance.span ] | None -> [])) inside
        in
        let table = Provenance.located ?span:(cover spans) (Value.Table (build inner)) in
        (name, table) :: build rest
  in
  build entries

let document st =
  let table = ref [] in
  let entries = ref [] in
  let rec go () =
    space st;
    match peek st with
    | None -> ()
    | Some '[' ->
        if looking st "[[" then fail st "arrays of tables are not supported";
        st.pos <- st.pos + 1;
        let path = key st in
        if peek st <> Some ']' then fail st "expected ] after a table name";
        st.pos <- st.pos + 1;
        line_end st;
        table := path;
        entries := { path; value = None } :: !entries;
        go ()
    | Some _ ->
        let entry = pair st in
        line_end st;
        entries := { entry with path = !table @ entry.path } :: !entries;
        go ()
  in
  go ();
  group (List.rev !entries)

let parse ~file text ~start ~stop =
  let st = { file; text; stop; pos = start } in
  try Ok (document st) with Error diagnostic -> Error [ diagnostic ]
