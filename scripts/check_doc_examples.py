#!/usr/bin/env python3
"""Checks that every Mojo example in the user documentation is the text of a
file that a check builds, so an example cannot drift from what runs.

Each ```mojo block in README.md, docs/GUIDE.md and docs/reference/*.md is
preceded, on the line just above it, by one of:

    <!-- example: PATH -->
        the block is the whole file PATH;
    <!-- example: PATH#ID [OLD=NEW ...] -->
        the block is the regions marked ID in PATH, each between a line
        "# example: ID" and the next line "# example: end", dedented, joined
        by two blank lines, then with each identifier OLD written NEW (the
        example's names where the file must use others: comments and
        strings included, but not a path segment such as "/OLD");
    <!-- example: none: REASON -->
        no file holds the block; REASON says why.

A block whose info string names mojo but is fenced any other way (indented,
four backticks, tildes, more after "mojo"), and a fenced block of any kind
without its closing fence, are errors, so no example can leave the check by
its fence. Every region in a .mojo file under tests/, examples/ and adapters/
must be shown by some block, and a file's regions must not nest. Exits nonzero on
any mismatch, printing a diff from the file's text to the block's.
Standard library only: python3 -I scripts/check_doc_examples.py [ROOT],
where ROOT (the repository by default) is for scripts/test_check_doc_examples.py.
"""

import difflib
import pathlib
import re
import sys
import textwrap

ROOT = (
    pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1
    else pathlib.Path(__file__).resolve().parent.parent
)
DOCS = ["README.md", "docs/GUIDE.md", *sorted(
    str(p.relative_to(ROOT)) for p in (ROOT / "docs/reference").glob("*.md")
)]
SOURCE_DIRS = ["tests", "examples", "adapters"]

MARKER = re.compile(r"<!-- example: (.*) -->")
REGION = re.compile(r"^\s*# example: (\S+)$")
RENAME = re.compile(r"^(\w+)=(\w+)$")
# An opening fence: three or more backticks (an info string without one) or
# tildes, as CommonMark has it.
FENCE = re.compile(r"\s*(`{3,}(?=[^`]*$)|~{3,})(.*)$")
MOJO_INFO = re.compile(r"\W*mojo\b", re.IGNORECASE)


def regions(path):
    """Maps each region ID in path to the list of its regions' texts."""
    found = {}
    current = None
    lines = []
    for n, line in enumerate(path.read_text().split("\n"), 1):
        m = REGION.match(line)
        if not m:
            if current is not None:
                lines.append(line)
            continue
        name = m.group(1)
        if name == "end":
            if current is None:
                raise ValueError(f"{path.relative_to(ROOT)}:{n}: end without a region")
            found.setdefault(current, []).append(textwrap.dedent("\n".join(lines)))
            current = None
        elif current is not None:
            raise ValueError(f"{path.relative_to(ROOT)}:{n}: region {name} inside {current}")
        else:
            current, lines = name, []
    if current is not None:
        raise ValueError(f"{path.relative_to(ROOT)}: region {current} has no end")
    return found


def blocks(doc):
    """Yields (line number, marker text or None, block text) for each ```mojo
    block, or (line number, "", error) for a Mojo block fenced any other way.

    Every fenced block is followed to its closing fence (the same character,
    at least as many, nothing else on the line), so a ```mojo line inside
    another block is that block's text when that block's fence is longer. A
    block with no closing fence before the end or before the next opening
    fence is an error: it would hide the blocks after it."""
    lines = (ROOT / doc).read_text().split("\n")
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        fence, info = m.group(1), m.group(2)
        close = re.compile(r"\s*" + re.escape(fence[0]) + "{%d,}\\s*$" % len(fence))
        j = i + 1
        while j < len(lines) and not close.match(lines[j]):
            # An opening fence no shorter than this one, with an info string,
            # is the next block: nested text uses a longer outer fence.
            inner = FENCE.match(lines[j])
            if inner and inner.group(2).strip() and close.match(inner.group(1)):
                break
            j += 1
        if j == len(lines) or not close.match(lines[j]):
            yield i + 1, "", "this fenced block has no closing fence"
            return
        if lines[i] == "```mojo":
            if lines[j] != "```":
                yield j + 1, "", "a Mojo block's closing fence must be exactly ```"
            else:
                m = MARKER.fullmatch(lines[i - 1]) if i > 0 else None
                yield i + 1, m.group(1) if m else None, "\n".join(lines[i + 1 : j])
        elif MOJO_INFO.match(info):
            yield i + 1, "", "a Mojo block's fence must be exactly ```mojo"
        i = j + 1


def main():
    errors = []
    shown = set()
    cache = {}
    counts = {"file": 0, "none": 0}

    def source_regions(path):
        if path not in cache:
            cache[path] = regions(ROOT / path)
        return cache[path]

    for doc in DOCS:
        for line, marker, text in blocks(doc):
            where = f"{doc}:{line}"
            if marker == "":
                errors.append(f"{where}: {text}")
                continue
            if marker is None:
                errors.append(f"{where}: no '<!-- example: ... -->' line above the block")
                continue
            if marker.startswith("none:"):
                if not marker[5:].strip():
                    errors.append(f"{where}: 'none:' needs a reason")
                counts["none"] += 1
                continue
            source, *renames = marker.split()
            path, _, name = source.partition("#")
            if not (ROOT / path).is_file():
                errors.append(f"{where}: {path} not found")
                continue
            if not name:
                expected = (ROOT / path).read_text().removesuffix("\n")
            else:
                try:
                    found = source_regions(path).get(name)
                except ValueError as e:
                    errors.append(str(e))
                    continue
                if not found:
                    errors.append(f"{where}: no region '# example: {name}' in {path}")
                    continue
                shown.add((path, name))
                expected = "\n\n\n".join(r.strip("\n") for r in found)
            pairs = {}
            for r in renames:
                m = RENAME.match(r)
                if not m:
                    errors.append(f"{where}: '{r}' is not OLD=NEW")
                    break
                pairs[m.group(1)] = m.group(2)
            else:
                if pairs:
                    # An identifier, not a path segment such as /OLD.
                    words = re.compile(r"(?<![\w/])(" + "|".join(map(re.escape, pairs)) + r")\b")
                    expected = words.sub(lambda m: pairs[m.group(1)], expected)
                if expected != text:
                    diff = difflib.unified_diff(
                        expected.split("\n"), text.split("\n"),
                        source, where, lineterm="",
                    )
                    errors.append(f"{where}: differs from {source}\n" + "\n".join(diff))
                counts["file"] += 1

    for d in SOURCE_DIRS:
        for p in sorted((ROOT / d).rglob("*.mojo")):
            path = str(p.relative_to(ROOT))
            try:
                names = source_regions(path)
            except ValueError as e:
                errors.append(str(e))
                continue
            for name in names:
                if (path, name) not in shown:
                    errors.append(f"{path}: region '{name}' is shown by no example")

    for e in dict.fromkeys(errors):
        print(f"error: {e}", file=sys.stderr)
    if errors:
        return 1
    print(f"ok: {counts['file']} examples are their files' text; "
          f"{counts['none']} have no file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
