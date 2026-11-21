"""Check both tangle generations, the HTML reader, and the generated library."""
from pathlib import Path
from html.parser import HTMLParser
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LIT = ROOT / "lit"
TOOLS = {
    "lit/dune", "lit/engine/dune", "lit/engine/lit_model.ml", "lit/lit.ml",
    "lit/lit_reader.ml", "lit/nvim/dune", "lit/nvim/lit_lsp.ml",
    "lit/test/dune", "lit/test/examples.ml",
}


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def compare(label, actual, expected):
    if actual.keys() != expected.keys():
        raise ValueError(f"{label}: missing {expected.keys() - actual.keys()}, "
                         f"unexpected {actual.keys() - expected.keys()}")
    changed = [path for path in sorted(expected) if actual[path] != expected[path]]
    if changed:
        raise ValueError(f"{label}: different files: {', '.join(changed)}")
    print(f"{label}: {len(expected)} files identical", flush=True)


def tree(directory):
    return {p.relative_to(directory).as_posix(): p.read_bytes()
            for p in directory.rglob("*") if p.is_file()}


class Reader(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.cards = {"home"}
        self.blocks = {}
        self.targets = {}
        self.links = set()
        self.block_owners = {}
        self.card = "home"
        self.block = None
        self.code = False
        self.splice = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "template":
            self.card = attrs["data-id"]
            if self.card in self.cards:
                raise ValueError(f"duplicate card: {self.card}")
            self.cards.add(self.card)
        if tag == "details" and "data-block" in attrs:
            self.block = attrs["data-block"]
            if self.block in self.blocks:
                raise ValueError(f"duplicate block: {self.block}")
            self.block_owners[self.block] = self.card
            self.blocks[self.block] = []
            if "data-target" in attrs:
                self.targets[self.block] = attrs["data-target"]
        if self.block is not None and tag == "code":
            self.code = True
        if tag == "a" and "data-card" in attrs:
            target = attrs.get("data-block")
            self.links.add((attrs["data-card"], target))
            if self.code and target is not None:
                self.blocks[self.block].append((True, (target, attrs["data-padding"])))
                self.splice = True
        if "data-embed" in attrs:
            self.links.add((attrs["data-embed"], None))
        if "data-lit-chunk" in attrs:
            raise ValueError("chunk placeholder survived weave")

    def handle_endtag(self, tag):
        if tag == "template":
            self.card = "home"
        if tag == "details":
            self.block = None
        if tag == "code":
            self.code = False
        if tag == "a":
            self.splice = False

    def handle_data(self, data):
        if self.code and not self.splice:
            self.blocks[self.block].append((False, data))

    def check(self, expected):
        for card, block in self.links:
            if card not in self.cards or (block is not None and self.block_owners.get(block) != card):
                raise ValueError(f"dangling reader link: {card}, {block}")

        def expand(key, active):
            if key in active:
                raise ValueError(f"reader splice cycle: {key}")
            output = []
            after_splice = False
            for splice, piece in self.blocks[key]:
                if splice:
                    target, padding = piece
                    body = expand(target, active | {key})
                    output.append("\n".join(padding + line if line.strip() else line
                                            for line in body.split("\n")))
                else:
                    output.append(piece.removeprefix("\n") if after_splice else piece)
                after_splice = splice
            return "".join(output)

        compare("HTML", {path: expand(key, set()).encode() for key, path in self.targets.items()}, expected)


def check_indentation(workspace):
    notes = workspace / "notes"
    notes.mkdir(parents=True)
    shutil.copytree(LIT / "reader", workspace / "reader")
    (workspace / "index.typ").write_text("= Guide <home>\n")
    source = notes / "indentation.typ"
    fixture = '''#import "/reader/book.typ": chunk

= Indentation <indentation>

#chunk(id: <leaf>)[
  ```ocaml
  let answer =
    42

  let enabled = true
  ```
]

#chunk(id: <wrapper>)[
    ```ocaml
    module Demo = struct
      <<leaf>>
    end
    ```
]

#chunk(id: <output>, target: "example.ml")[
  ```ocaml
  <<wrapper>>
  module Again = struct
      <<leaf>>
  end
  ```
]

#chunk(id: <literal>, target: "literal.txt", noweb: false)[
  ```text
    <<literal-marker>>
  ```
]
'''
    source.write_text(fixture)
    command = ["opam", "exec", "--", "dune", "exec", "--no-print-directory", "./lit/lit.exe", "--"]
    expected = {
        "example.ml": b"module Demo = struct\n  let answer =\n    42\n\n  let enabled = true\nend\n"
                      b"module Again = struct\n    let answer =\n      42\n\n    let enabled = true\nend\n",
        "literal.txt": b"  <<literal-marker>>\n",
    }
    run(*command, "tangle", workspace)
    compare("indentation", tree(workspace / "out"), expected)
    run(*command, "weave", workspace)
    book = Reader()
    book.feed((workspace / "index.html").read_text())
    book.close()
    book.check(expected)

    for original, replacement, message in (
        ("  let answer =", " let answer =", "code line starts to the left of its fence"),
        ("\n  ```\n]", "\n ```\n]", "align the closing code fence with its opening fence"),
    ):
        source.write_text(fixture.replace(original, replacement, 1))
        line = fixture[:fixture.index(original)].count("\n") + 1 + original.startswith("\n")
        result = subprocess.run([*command, "tangle", workspace], cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 1 or f"{source}:{line}:1: {message}" not in result.stderr:
            raise ValueError(f"expected a located indentation diagnostic, got: {result.stderr}")
        if tree(workspace / "out") != expected:
            raise ValueError("failed tangle modified the output")


def check(work):
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", "*.ml", "*.mli", "dune",
                                      "*/dune", "dune-project", "*.opam", ".github/workflows/*", "LICENSE"],
                                      cwd=ROOT).decode().split("\0")
    paths = {p for p in tracked if p and not p.startswith("lit/")} | TOOLS
    expected = {p: (ROOT / p).read_bytes() for p in paths}
    project = ROOT
    for generation in ("first", "second"):
        workspace = work / generation
        shutil.copytree(LIT / "notes", workspace / "notes")
        shutil.copytree(LIT / "reader", workspace / "reader")
        shutil.copyfile(LIT / "index.typ", workspace / "index.typ")
        if generation == "first":
            run("typst", "compile", "--root", workspace, workspace / "index.typ", work / "standalone.pdf")
        command = ["opam", "exec", "--", "dune", "exec", "--root", project, "--no-print-directory",
                   "./lit/lit.exe", "--"]
        run(*command, "tangle", workspace)
        project = workspace / "out"
        compare(generation, tree(project), expected)
        run(*command, "weave", workspace)
        book = Reader()
        book.feed((workspace / "index.html").read_text())
        book.close()
        book.check(expected)
    run("opam", "exec", "--", "dune", "build", "--root", project,
        "@install", "@runtest", "lit/nvim/lit_lsp.exe")
    print("Generated library and language server built. Examples passed.")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary).resolve()
        check_indentation(work / "indentation")
        check(work)
