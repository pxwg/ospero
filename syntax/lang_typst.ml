open Ospero_kernel
module Identity_rules = Rules.Identity_rules
module Action_rules = Rules.Action_rules

let language = Result.get_ok (Text.Language.of_string "typst")

type value = Value.t

type heading = {
  level : int;
  title : string Provenance.located;
  label : string Provenance.located option;
  metadata : Value.field list Frontend.read option;
}

type node =
  | Call of {
      name : string Provenance.located;
      arguments : argument list;
      trailing : Text.t Provenance.located list;
      inner : node Provenance.located list;
    }
  | Reference of {
      target : string Provenance.located;
      supplement : Text.t Provenance.located option;
    }
  | Card of Card.nested

and argument = {
  name : string Provenance.located option;
  value : value Provenance.located;
}

type context = value Card.context

let values = Value.rules

let identities =
  Identity_rules.empty
  |> Identity_rules.register ~name:"heading-label" (fun (h : heading Provenance.located) ->
       match h.value.metadata, h.value.label with
       | None, _ -> Rules.No_match
       | Some _, None ->
           let insertion = Option.map (fun (s : Provenance.span) -> { s with start = s.stop })
             h.value.title.span in
           Rules.Invalid [ Frontend.Diagnostic.make ?span:h.span
             (Missing_identity { insertion; prefix = " <"; suffix = ">" }) ]
       | Some _, Some label ->
           match Graph.Vertex_id.of_string label.value with
           | Ok id -> Rules.Matched { label with value = id }
           | Error message -> Rules.Invalid [ Card.invalid ?span:label.span message ])

(* {1 Lexing}

   Positions are byte offsets into the text. Markup, code, raw text, math
   and comments are distinguished so that only real markup is read. *)

type st = {
  file : string;
  text : string;
  len : int;
  mutable heads : (heading, value) Card.heading list;
}

let span st start stop = { Provenance.file = st.file; start; stop }
let at st start stop =
  Provenance.located ~span:(span st start stop) (String.sub st.text start (stop - start))
let char st i = if i < st.len then st.text.[i] else '\000'
let looking st i s =
  let n = String.length s in
  i + n <= st.len && String.sub st.text i n = s

let is_alnum = function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true | _ -> false
let is_ident_start c = is_alnum c && not (c >= '0' && c <= '9') || c = '_'
let is_ident c = is_alnum c || c = '_' || c = '-'
let is_label c = is_alnum c || c = '_' || c = '-' || c = ':' || c = '.'
let is_blank c = c = ' ' || c = '\t' || c = '\r'

let span_while st i p = let j = ref i in while !j < st.len && p st.text.[!j] do incr j done; !j
let line_end st i = match String.index_from_opt st.text i '\n' with Some e -> e | None -> st.len
let line_begin st i = match String.rindex_from_opt st.text (i - 1) '\n' with
  | Some b when i > 0 -> b + 1 | _ -> 0

let skip_line_comment st i = line_end st i

let rec skip_block_comment st i depth =
  if i >= st.len then st.len
  else if looking st i "/*" then skip_block_comment st (i + 2) (depth + 1)
  else if looking st i "*/" then (if depth = 1 then i + 2 else skip_block_comment st (i + 2) (depth - 1))
  else skip_block_comment st (i + 1) depth

let skip_raw st i =
  let n = span_while st i (fun c -> c = '`') - i in
  if n = 2 then i + 2
  else
    let fence = String.make n '`' in
    let rec find j = if j >= st.len then None else if looking st j fence then Some j else find (j + 1) in
    match find (i + n) with Some j -> j + n | None -> i + n

let rec skip_math st i =
  if i >= st.len then st.len
  else match st.text.[i] with
    | '\\' -> skip_math st (i + 2)
    | '$' -> i + 1
    | _ -> skip_math st (i + 1)

let string_literal st i =
  let b = Buffer.create 16 in
  let rec go j =
    if j >= st.len then None
    else match st.text.[j] with
      | '"' -> Some (j + 1, Buffer.contents b)
      | '\\' when j + 1 < st.len ->
          (match st.text.[j + 1] with
           | 'n' -> Buffer.add_char b '\n'; go (j + 2)
           | 't' -> Buffer.add_char b '\t'; go (j + 2)
           | 'r' -> Buffer.add_char b '\r'; go (j + 2)
           | 'u' when char st (j + 2) = '{' ->
               (match String.index_from_opt st.text (j + 3) '}' with
                | Some k ->
                    (match int_of_string_opt ("0x" ^ String.sub st.text (j + 3) (k - j - 3)) with
                     | Some code when Uchar.is_valid code ->
                         Buffer.add_utf_8_uchar b (Uchar.of_int code); go (k + 1)
                     | _ -> go (k + 1))
                | None -> None)
           | c -> Buffer.add_char b c; go (j + 2))
      | c -> Buffer.add_char b c; go (j + 1)
  in
  go (i + 1)

let skip_string st i = match string_literal st i with Some (j, _) -> j | None -> st.len

let content_text st start stop =
  Provenance.located ~span:(span st start stop)
    { Text.text = String.sub st.text start (stop - start); language }

let heading_marker st i =
  let j = span_while st i (fun c -> c = '=') in
  if j > i && (j >= st.len || st.text.[j] = ' ' || st.text.[j] = '\n') then Some (j - i) else None

(* Code mode: skip until a top-level character satisfying [stop], or an
   unmatched closer. Content blocks inside are markup. *)
let rec skip_code st i ~stop =
  let rec go i closers =
    if i >= st.len then st.len
    else
      let c = st.text.[i] in
      if closers = [] && stop c then i
      else match c with
        | '"' -> go (skip_string st i) closers
        | '/' when char st (i + 1) = '/' -> go (skip_line_comment st i) closers
        | '/' when char st (i + 1) = '*' -> go (skip_block_comment st i 0) closers
        | '(' -> go (i + 1) (')' :: closers)
        | '{' -> go (i + 1) ('}' :: closers)
        | '[' -> let q, _ = markup st ~top:false (i + 1) in go (q + 1) closers
        | ')' | '}' | ']' ->
            (match closers with
             | c' :: rest when c' = c -> go (i + 1) rest
             | _ -> i)
        | _ -> go (i + 1) closers
  in
  go i []

(* Markup from [i]. Nested markup stops at its unmatched closing bracket,
   whose position is returned. Top-level markup also reports headings. *)
and markup st ~top i =
  let nodes = ref [] in
  let add n = nodes := n :: !nodes in
  let rec go i depth line_start =
    if i >= st.len then st.len
    else
      let c = st.text.[i] in
      if line_start && is_blank c then go (i + 1) depth true
      else if top && line_start && looking st i "///" then go (metadata_block i) depth false
      else if top && line_start && heading_marker st i <> None then go (heading i None) depth false
      else match c with
        | '\n' -> go (i + 1) depth true
        | '\\' -> go (i + 2) depth false
        | 'h' when (looking st i "https://" || looking st i "http://")
                   && (i = 0 || not (is_alnum st.text.[i - 1])) ->
            (* A bare URL runs to the next blank; its slashes are not a comment. *)
            go (span_while st i (fun c -> not (is_blank c || c = '\n' || c = ']'))) depth false
        | '/' when char st (i + 1) = '/' && (i = 0 || st.text.[i - 1] <> ':') ->
            go (skip_line_comment st i) depth false
        | '/' when char st (i + 1) = '*' -> go (skip_block_comment st i 0) depth false
        | '`' -> go (skip_raw st i) depth false
        | '$' -> go (skip_math st (i + 1)) depth false
        | '#' -> let j, found = code st i in List.iter add found; go j depth false
        | '@' when (i = 0 || not (is_alnum st.text.[i - 1])) && is_label (char st (i + 1)) ->
            go (reference i) depth false
        | '[' when not top -> go (i + 1) (depth + 1) false
        | ']' when not top -> if depth = 0 then i else go (i + 1) (depth - 1) false
        | _ -> go (i + 1) depth false
  and reference i =
    let j = span_while st (i + 1) is_label in
    let j = let j = ref j in while !j > i + 1 && (st.text.[!j - 1] = '.' || st.text.[!j - 1] = ':') do decr j done; !j in
    (* [@b\[shown\]]: the supplement is kept with the reference it labels. *)
    let supplement, stop =
      if char st j = '[' then
        let q, _ = markup st ~top:false (j + 1) in
        Some (content_text st (j + 1) q), min st.len (q + 1)
      else None, j
    in
    add (Provenance.located ~span:(span st i stop)
           (Reference { target = at st (i + 1) j; supplement }));
    stop
  (* Consecutive /// lines; metadata only when a heading follows directly. *)
  and metadata_block i =
    let block_start = line_begin st i in
    let rec lines j =
      let s = span_while st j is_blank in
      if looking st s "///" then lines (min st.len (line_end st s + 1)) else j, s
    in
    let block_stop, next = lines block_start in
    match heading_marker st next with
    | Some _ ->
        let blanked = Bytes.of_string (String.sub st.text block_start (block_stop - block_start)) in
        let rec blank j =
          if j < Bytes.length blanked then begin
            let s = ref j in
            while !s < Bytes.length blanked && is_blank (Bytes.get blanked !s) do incr s done;
            Bytes.blit_string "   " 0 blanked !s 3;
            match Bytes.index_from_opt blanked !s '\n' with Some e -> blank (e + 1) | None -> ()
          end
        in
        blank 0;
        let padded = String.make block_start ' ' ^ Bytes.to_string blanked in
        let fields = Toml.parse ~file:st.file padded ~start:block_start ~stop:block_stop in
        let stop = if block_stop > block_start && st.text.[block_stop - 1] = '\n' then block_stop - 1 else block_stop in
        heading next (Some (block_start, stop, fields))
    | None -> block_stop
  and heading i metadata =
    let level = Option.get (heading_marker st i) in
    let e = line_end st i in
    let t0 = span_while st (i + level) is_blank in
    let t1 = ref e in
    while !t1 > t0 && is_blank st.text.[!t1 - 1] do decr t1 done;
    let label, t1 =
      if !t1 > t0 && st.text.[!t1 - 1] = '>' then
        let l1 = !t1 - 1 in
        let l0 = ref l1 in
        while !l0 > t0 && is_label st.text.[!l0 - 1] do decr l0 done;
        if !l0 > t0 && st.text.[!l0 - 1] = '<' && !l0 < l1 then begin
          let stop = ref (!l0 - 1) in
          while !stop > t0 && is_blank st.text.[!stop - 1] do decr stop done;
          Some (at st !l0 l1), !stop
        end else None, !t1
      else None, !t1
    in
    let title = at st t0 t1 in
    let start, metadata_span, fields =
      match metadata with
      | Some (s, stop, fields) -> s, Some (span st s stop), Some fields
      | None -> line_begin st i, None, None
    in
    st.heads <-
      { Card.level;
        identity = Provenance.located ~span:(span st i e) { level; title; label; metadata = fields };
        title = span st t0 t1;
        metadata = Option.fold fields ~none:(Ok []) ~some:(Result.map Value.fields);
        metadata_span; start; body_start = min st.len (e + 1) }
      :: st.heads;
    i + level
  in
  let stop = go i 0 true in
  stop, List.rev !nodes

(* An embedded expression at [#]. Calls become nodes; statements and other
   expressions are skipped. *)
and code st i =
  let j = i + 1 in
  let c = char st j in
  if is_ident_start c then begin
    let rec path k =
      let e = span_while st k is_ident in
      if char st e = '.' && is_ident_start (char st (e + 1)) then path (e + 1) else e
    in
    let e = path j in
    let first = String.sub st.text j (span_while st j is_ident - j) in
    if List.mem first [ "let"; "set"; "show"; "import"; "include"; "if"; "for"; "while"; "context"; "return" ]
    then skip_code st e ~stop:(fun c -> c = '\n'), []
    else
      let rec postfix p arguments trailing inner =
        match char st p with
        | '(' ->
            let q, args, nodes = arguments_list st (p + 1) in
            postfix q (arguments @ args) trailing (inner @ nodes)
        | '[' ->
            let q, nodes = markup st ~top:false (p + 1) in
            postfix (min st.len (q + 1)) arguments (trailing @ [ content_text st (p + 1) q ]) (inner @ nodes)
        | _ -> p, arguments, trailing, inner
      in
      let p, arguments, trailing, inner = postfix e [] [] [] in
      if p = e then e, []
      else [ Provenance.located ~span:(span st i p) (Call { name = at st j e; arguments; trailing; inner }) ]
           |> fun nodes -> p, nodes
  end
  else match c with
    | '[' -> let q, nodes = markup st ~top:false (j + 1) in min st.len (q + 1), nodes
    | '(' | '{' -> skip_code st j ~stop:(fun _ -> false) |> (fun q -> min st.len (q + 1)), []
    | _ -> j, []

(* Arguments after an opening parenthesis, up to and past the closing one. *)
and arguments_list st i =
  let rec items i acc nodes =
    let i = skip_space st i in
    if i >= st.len then st.len, List.rev acc, nodes
    else if st.text.[i] = ')' then i + 1, List.rev acc, nodes
    else
      let name, i =
        let e = span_while st i is_ident in
        let colon = skip_space st e in
        if is_ident_start (char st i) && char st colon = ':' then Some (at st i e), skip_space st (colon + 1)
        else if char st i = '"' then
          match string_literal st i with
          | Some (e, key) when char st (skip_space st e) = ':' ->
              Some (Provenance.located ~span:(span st i e) key), skip_space st (skip_space st e + 1)
          | _ -> None, i
        else None, i
      in
      let i, value, found = expr st i in
      let i = skip_space st i in
      let acc = { name; value } :: acc in
      match char st i with
      | ',' -> items (i + 1) acc (nodes @ found)
      | ')' -> i + 1, List.rev acc, nodes @ found
      | _ ->
          let q = skip_code st i ~stop:(fun c -> c = ',' || c = ')') in
          items (if char st q = ',' then q + 1 else q) acc (nodes @ found)
  in
  items i [] []

and skip_space st i =
  let i = span_while st i (fun c -> is_blank c || c = '\n') in
  if looking st i "//" then skip_space st (skip_line_comment st i)
  else if looking st i "/*" then skip_space st (skip_block_comment st i 0)
  else i

(* A literal value. Anything else is read up to the next argument and kept
   as [Other]. *)
and expr st i =
  let located start stop v = Provenance.located ~span:(span st start stop) v in
  let atom, nodes =
    match char st i with
    | '"' ->
        (match string_literal st i with
         | Some (e, s) -> Some (e, Value.String s), []
         | None -> None, [])
    | '<' ->
        let e = span_while st (i + 1) is_label in
        if e > i + 1 && char st e = '>' then Some (e + 1, Value.Label (String.sub st.text (i + 1) (e - i - 1))), []
        else None, []
    | '[' ->
        let q, nodes = markup st ~top:false (i + 1) in
        Some (min st.len (q + 1), Value.Contents (content_text st (i + 1) q).value), nodes
    | '(' ->
        let e, items, nodes = arguments_list st (i + 1) in
        let named = List.filter (fun a -> a.name <> None) items in
        let raw = String.sub st.text i (e - i) in
        let trailing_comma = let k = ref (e - 2) in while !k > i && (is_blank st.text.[!k] || st.text.[!k] = '\n') do decr k done; st.text.[!k] = ',' in
        let value =
          if String.trim (String.sub raw 1 (String.length raw - 2)) = ":" then Value.Table []
          else if items <> [] && List.length named = List.length items then
            Value.Table (List.map (fun a -> Option.get a.name, a.value) items)
          else if named <> [] then Value.Other raw
          else match items with
            | [ single ] when not trailing_comma -> single.value.value
            | _ -> Value.Array (List.map (fun a -> a.value) items)
        in
        Some (e, value), nodes
    | c when (c >= '0' && c <= '9') || (c = '-' && let d = char st (i + 1) in d >= '0' && d <= '9') ->
        let e = span_while st (i + 1) (fun c -> is_alnum c || c = '.' || c = '_' || c = '%') in
        let raw = String.sub st.text i (e - i) in
        Some (e, match int_of_string_opt raw with Some n when not (String.contains raw '.') -> Value.Int n | _ -> Value.Other raw), []
    | c when is_ident_start c ->
        let e = span_while st i is_ident in
        (match String.sub st.text i (e - i) with
         | "true" -> Some (e, Value.Bool true), []
         | "false" -> Some (e, Value.Bool false), []
         | _ -> None, [])
    | _ -> None, []
  in
  let stops c = c = ',' || c = ')' in
  match atom with
  | Some (e, v) when stops (char st (skip_space st e)) || skip_space st e >= st.len -> e, located i e v, nodes
  | _ ->
      let q = skip_code st i ~stop:stops in
      let q' = let k = ref q in while !k > i && (is_blank st.text.[!k - 1] || st.text.[!k - 1] = '\n') do decr k done; !k in
      q, located i q' (Value.Other (String.sub st.text i (q' - i))), nodes

let scan ~file text ~start =
  let st = { file; text; len = String.length text; heads = [] } in
  let _, nodes = markup st ~top:true start in
  { Card.headings = List.rev st.heads; nodes }

let children = function Call { inner; _ } -> inner | Reference _ | Card _ -> []

(* {1 Named calls} *)

let rec needs_evaluation (v : value Provenance.located) =
  match v.value with
  | Other _ | Label _ -> [ v ]
  | Array items -> List.concat_map needs_evaluation items
  | Table fields -> List.concat_map (fun (_, v) -> needs_evaluation v) fields
  | String _ | Int _ | Bool _ | Contents _ -> []

let actions =
  Action_rules.empty
  |> Action_rules.register ~sugar:"named-call" (fun node (context : context) ->
       match node.Provenance.value with
       | Call { name; arguments; trailing; _ }
         when String.length name.value > 3 && String.sub name.value 0 3 = "zk." ->
           let name =
             { Provenance.value = String.sub name.value 3 (String.length name.value - 3);
               span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 3 }) name.span }
           in
           let positional = List.filter (fun a -> a.name = None) arguments in
           let evaluated = List.concat_map (fun a -> needs_evaluation a.value) arguments in
           let problems =
             List.map (fun a -> Card.invalid ?span:a.value.span "named calls take named arguments only") positional
             @ List.map (fun (v : _ Provenance.located) ->
                 Card.invalid ?span:v.span "this argument needs evaluation; only literals are read") evaluated
             @ (match trailing with
                | _ :: extra :: _ -> [ Card.invalid ?span:extra.span "a named call takes one body" ]
                | _ -> [])
           in
           if problems <> [] then Rules.Invalid problems
           else
             let fields =
               List.filter_map (fun a -> Option.map (fun n -> n, a.value) a.name) arguments
             in
             let body = match trailing with [ b ] -> Some b | _ -> None in
             (match context.named ~name ?body (Value.fields fields) with
              | Ok call ->
                  Rules.Matched
                    { Action_rules.call = Provenance.located ?span:node.span call; taken = node.span }
              | Error errors -> Rules.Invalid errors)
       | _ -> Rules.No_match)

let adapter ?(values = values) ?(identities = identities) ?(actions = actions)
    ?(define = "define") frontend =
  Card.adapter
    { Card.language; source = Fun.id; scan = (fun ~file text -> scan ~file text ~start:0);
      read = scan; nested = (fun n -> Card n); children }
    ~values ~identities ~actions ~define frontend

module Sugar = struct
  let references action make rules =
    rules
    |> Action_rules.bind ~sugar:"at-reference" action (fun node _ ->
         match node.Provenance.value with
         | Reference { target; _ } -> Rules.Matched (make target)
         | _ -> Rules.No_match)
    |> Action_rules.bind ~sugar:"ref-call" action (fun node _ ->
         match node.Provenance.value with
         | Call { name = { value = "ref"; _ }; arguments = [ { name = None; value = { value = Label l; span } } ]; trailing = []; _ } ->
             let span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 1; stop = s.stop - 1 }) span in
             Rules.Matched (make (Provenance.located ?span l))
         | _ -> Rules.No_match)

  (* The body must be exactly one reference. *)
  let include_note action make =
    Action_rules.bind ~sugar:"include-note" action (fun node _ ->
      match node.Provenance.value with
      | Call { name = { value = "include-note"; _ }; trailing = [ _ ]; inner; _ } ->
          (match inner with
           | [ { value = Reference { target; _ }; _ } ] -> Rules.Matched (make target)
           | _ -> Rules.Invalid [ Card.invalid ?span:node.span "include-note takes one @reference" ])
      | _ -> Rules.No_match)

  let nested_card action make =
    Card.nested_card (function Card n -> Some n | _ -> None) action make
end
