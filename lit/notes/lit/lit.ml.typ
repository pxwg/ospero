#import "/reader/book.typ": chunk

= 文学编程构建命令 <lit:lit.ml>

命令行先报告观察与验证的问题。通过验证后，tangle 写出代码文件，weave 写出阅读器。

#chunk(id: <source-lit-lit-ml>)[
```ocaml
open Lit_model

let rec ensure_directory path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR -> ()
  | _ -> fail "%s is not a directory" path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      ensure_directory (Filename.dirname path);
      Unix.mkdir path 0o755

let write path body =
  let dir = Filename.dirname path in
  ensure_directory dir;
  (match (Unix.lstat path).st_kind with
   | Unix.S_REG -> ()
   | _ -> fail "%s is not a regular file" path
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let staged, channel = Filename.open_temp_file ~temp_dir:dir ".lit-" ".tmp" in
  Fun.protect ~finally:(fun () -> close_out_noerr channel; if Sys.file_exists staged then Sys.remove staged)
    (fun () -> output_string channel body; close_out channel;
      Unix.chmod staged 0o644; Unix.rename staged path)

let run command workspace =
  let workspace = Unix.realpath workspace in
  let files = sources workspace in
  if Files.is_empty files then fail "no Typst cards in %s" workspace;
  let obs, diagnostics = observe_sources files in
  match problems obs diagnostics with
  | [] ->
      let cards = code_cards obs in
      (match command with
       | "tangle" ->
           let out = Filename.concat workspace "out" in
           List.iter (fun (target, body) -> write (Filename.concat out target) body) (outputs cards)
       | "weave" -> write (Filename.concat workspace "index.html") (Lit_reader.render workspace obs cards)
       | _ -> assert false)
  | problems ->
      List.iter (fun (span, message) ->
        let location = match span with
          | None -> workspace
          | Some (span : P.span) ->
              let source = Files.find span.file files in
              let line = ref 1 and start = ref 0 in
              for i = 0 to span.start - 1 do
                if source.[i] = '\n' then (incr line; start := i + 1)
              done;
              Printf.sprintf "%s:%d:%d" span.file !line (span.start - !start + 1) in
        Printf.eprintf "%s: %s\n" location message) problems;
      exit 1

let () =
  match Array.to_list Sys.argv with
  | [_; ("tangle" | "weave") as command; workspace] ->
      (try run command workspace with
       | Failure message | Sys_error message -> prerr_endline message; exit 1
       | Unix.Unix_error (code, _, path) ->
           Printf.eprintf "%s: %s\n" path (Unix.error_message code); exit 1)
  | _ -> prerr_endline "usage: lit (tangle|weave) WORKSPACE"; exit 2
```
]

#chunk(id: <file-lit-lit-ml>, target: "lit/lit.ml")[
```ocaml
<<source-lit-lit-ml>>
```
]
