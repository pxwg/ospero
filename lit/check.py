"""Verify the book and both generations against the working tree."""
from argparse import ArgumentParser
from html.parser import HTMLParser
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LIT = ROOT / "lit"


class Book(HTMLParser):
    def __init__(self):
        super().__init__()
        self.blocks = {}
        self.targets = {}
        self.ids = set()
        self.links = set()
        self.block = None
        self.code = False
        self.ref = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            key = attrs["id"]
            if key in self.ids:
                raise ValueError(f"duplicate HTML anchor: {key}")
            self.ids.add(key)
        if tag == "details":
            self.block = attrs["id"]
            self.blocks[self.block] = []
            if attrs["data-target"]:
                self.targets[self.block] = attrs["data-target"]
        if tag == "code":
            self.code = True
        if tag == "a":
            ref = attrs["href"].removeprefix("#")
            self.links.add(ref)
            if self.code:
                self.ref = True
                self.blocks[self.block].append(("include", ref))

    def handle_endtag(self, tag):
        if tag == "code":
            self.code = False
        if tag == "a":
            self.ref = False

    def handle_data(self, data):
        if self.code and not self.ref:
            self.blocks[self.block].append(("text", data))

    def expand(self, key):
        pieces = self.blocks[key]
        includes = {f"<<{value}>>": value for kind, value in pieces if kind == "include"}
        source = "".join(f"<<{value}>>" if kind == "include" else value for kind, value in pieces)
        return "".join(self.expand(includes[line.strip()]) if line.strip() in includes else line
                       for line in source.splitlines(keepends=True))


def run(*args):
    return subprocess.check_output(args, cwd=ROOT)


def compare(label, actual, expected):
    if actual.keys() != expected.keys():
        raise ValueError(f"{label}: missing {expected.keys() - actual.keys()}, "
                         f"unexpected {actual.keys() - expected.keys()}")
    for path in sorted(expected):
        if actual[path] != expected[path]:
            raise ValueError(f"{label}: {path} differs")
    print(f"{label}: {len(expected)} files identical", flush=True)


def tree(directory):
    return {p.relative_to(directory).as_posix(): p.read_bytes()
            for p in directory.rglob("*") if p.is_file()}


def check(work, playground):
    tracked = run("git", "ls-files", "-z", "--", "*.ml", "*.mli", "dune", "*/dune", "dune-project",
                  "*.opam", ".github/workflows/*", "LICENSE").decode().split("\0")
    paths = {p for p in tracked if p and not p.startswith("lit/")}
    paths.update(["lit/seed.py", "lit/test/examples.ml", "lit/test/dune"])
    expected = {p: (ROOT / p).read_bytes() for p in paths}
    for generation in ("first", "second"):
        workspace = work / generation
        shutil.copytree(LIT / "notes", workspace / "notes")
        seed = LIT / "seed.py" if generation == "first" else work / "first/out/lit/seed.py"
        run(sys.executable, seed, "tangle", workspace)
        out = workspace / "out"
        compare(generation, tree(out), expected)
        book = Book()
        book.feed(run(sys.executable, seed, "weave", workspace).decode())
        book.close()
        if book.links - book.ids:
            raise ValueError(f"dangling links: {book.links - book.ids}")
        compare("HTML", {path: book.expand(key).encode() for key, path in book.targets.items()},
                expected)
    if playground:
        workspace = work / "playground"
        notes = workspace / "lit-note"
        notes.mkdir(parents=True)
        # The original playground discovers Org documents in one directory.
        for i, card in enumerate(sorted((LIT / "notes").rglob("*.org"))):
            shutil.copyfile(card, notes / f"{i}.org")
        run(playground, "tangle", workspace)
        compare("playground tangle", tree(workspace / "out"), expected)
        woven = json.loads(run(playground, "weave", workspace))
        if woven["diagnostics"]:
            raise ValueError(woven["diagnostics"])
        cards = {card["id"]: card for card in woven["cards"]}

        def expand(key):
            return "".join(piece["text"] if "text" in piece else expand(piece["id"])
                           for piece in cards[key]["pieces"])

        compare("playground weave", {c["target"]: expand(key).encode()
                for key, c in cards.items() if c["target"]}, expected)
    subprocess.run(["opam", "exec", "--", "dune", "build", "--root", out, "@install", "@runtest"],
                   cwd=ROOT, check=True)
    print("Generated library built and examples passed.")


if __name__ == "__main__":
    parser = ArgumentParser()
    parser.add_argument("--playground", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        check(Path(tmp), args.playground.resolve() if args.playground else None)
