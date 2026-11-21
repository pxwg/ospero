#import "/reader/book.typ": chunk

= examples.ml <lit:test:examples.ml>

#chunk(id: <source-lit-test-examples-ml>)[
```ocaml
open Ospero.Core

let parallel_edges_survive_mapping () =
  let id = Graph.Vertex_id.of_string "A" |> Result.get_ok in
  let loop name =
    { Graph.id = Graph.Edge_id.of_string name |> Result.get_ok;
      source = id; target = id; relation = () }
  in
  let loops = [loop "first"; loop "second"] in
  let graph = Graph.assemble [{ Graph.id; note = "A" }] loops |> Result.get_ok in
  let mapped = Graph.map graph ~vertex:(fun v -> String.length v.note) ~edge:(fun _ -> ()) in
  assert (Graph.incoming mapped id = Some loops);
  assert (Graph.outgoing mapped id = Some loops)

let two_ports_share_one_intermediate () =
  let calls = ref 0 in
  let count = Clone.operation 1 (function
    | [x] -> incr calls; x + 1
    | _ -> assert false)
  in
  let before = Clone.tuple 1 [count] in
  let after = Clone.tuple 1 [Clone.projection 1 0; Clone.projection 1 0] in
  assert (Clone.apply (Clone.compose ~before ~after) [3] = [4; 4]);
  assert (!calls = 1)

let empty_typst_supplement_uses_default () =
  let module Typst = Ospero.Syntax.Lang.Typst in
  let source = "@b @b[]后 @b[别名]" in
  let scan = Typst.scan ~file:"references.typ" source in
  let references = List.filter_map (fun (node : _ Provenance.located) ->
    match node.value, node.span with
    | Typst.Reference { target; supplement }, Some span ->
        Some (target.value, Option.map (fun (text : Text.t Provenance.located) -> text.value.text) supplement,
              String.sub source span.start (span.stop - span.start))
    | _ -> None) scan.nodes in
  assert (references = ["b", None, "@b"; "b", None, "@b[]"; "b", Some "别名", "@b[别名]"])

let () =
  empty_typst_supplement_uses_default ();
  parallel_edges_survive_mapping ();
  two_ports_share_one_intermediate ()
```
]

#chunk(id: <file-lit-test-examples-ml>, target: "lit/test/examples.ml")[
```ocaml
<<source-lit-test-examples-ml>>
```
]
