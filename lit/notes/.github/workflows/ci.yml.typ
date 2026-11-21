#import "/reader/book.typ": chunk

= ci.yml <.github:workflows:ci.yml>

#chunk(id: <source-github-workflows-ci-yml>)[
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  install:
    name: ${{ matrix.os }} / OCaml ${{ matrix.ocaml }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-24.04
            ocaml: 5.5.1
            dune: dune.3.24.2
          - os: macos-latest
            ocaml: 5.5.1
            dune: dune
    steps:
      - uses: actions/checkout@v4
      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: ${{ matrix.ocaml }}
      - name: Install package
        run: |
          opam lint ospero.opam
          opam install ${{ matrix.dune }} --yes
          opam install . --yes
      - name: Check installed library
        shell: bash
        run: |
          consumer_dir=$(mktemp -d)
          trap 'rm -rf "$consumer_dir"' EXIT
          echo '(lang dune 3.5)' > "$consumer_dir/dune-project"
          echo '(executable (name main) (libraries ospero))' > "$consumer_dir/dune"
          cat > "$consumer_dir/main.ml" <<'OCAML'
          module Lang = Ospero.Syntax.Lang
          module Typst = Lang.Typst
          module Org = Lang.Org
          module Markdown = Lang.Markdown

          let () =
            let open Ospero.Core in
            let input = Provenance.located "ospero" in
            match (Syntax.Args.encode Syntax.Args.string input).value with
            | Frontend.Payload.String "ospero" -> ()
            | _ -> failwith "unexpected payload"
          OCAML
          opam exec -- dune exec --root "$consumer_dir" ./main.exe
          cmp LICENSE "$(opam var doc)/ospero/LICENSE"
```
]

#chunk(id: <file-github-workflows-ci-yml>, target: ".github/workflows/ci.yml")[
```yaml
<<source-github-workflows-ci-yml>>
```
]
