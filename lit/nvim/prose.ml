open Ospero.Core

type link = { target : Graph.Vertex_id.t; label : string option; span : Provenance.span }

let bracket = Str.regexp {|\[\[\(id\|include\):\([^][ 	]+\)\(\]\[\([^]]*\)\)?\]\]|}
let block = Str.regexp_case_fold {|^[ 	]*#\+begin_\(src\|example\|export\|comment\)\b|}
let drawer = Str.regexp_case_fold {|^[ 	]*:\(properties\|logbook\):[ 	]*$|}
let verbatim = Str.regexp {|\(^\|[ 	([]\)\(=[^= 	][^=]*=\|~[^~]+~\|[$][^$]+[$]\)|}
let links file source =
  let offset = ref 0 and closed_by = ref None and result = ref [] in
  String.split_on_char '\n' source |> List.iter (fun line ->
    let lower = String.trim line |> String.lowercase_ascii in
    (match !closed_by with
     | Some close -> if lower = close then closed_by := None
     | None when Str.string_match block line 0 ->
         closed_by := Some ("#+end_" ^ String.lowercase_ascii (Str.matched_group 1 line))
     | None when Str.string_match drawer line 0 -> closed_by := Some ":end:"
     | None when String.starts_with ~prefix:"#" lower -> ()
     | None ->
         let ignored = ref [] in
         let rec literals from =
           match Str.search_forward verbatim line from with
           | start -> let stop = Str.match_end () in
               ignored := (start, stop) :: !ignored; literals stop
           | exception Not_found -> () in
         literals 0;
         let rec scan from =
           match Str.search_forward bracket line from with
           | start ->
               let stop = Str.match_end () and id = Str.matched_group 2 line in
               let label = try Some (Str.matched_group 4 line) with Not_found -> None in
               if not (List.exists (fun (a,b) -> a <= start && start < b) !ignored) then
                 result := { target = Result.get_ok (Graph.Vertex_id.of_string id); label;
                   span = { file; start = !offset + start; stop = !offset + stop } } :: !result;
               scan stop
           | exception Not_found -> () in
         scan 0);
    offset := !offset + String.length line + 1);
  List.rev !result
