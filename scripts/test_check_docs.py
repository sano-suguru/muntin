#!/usr/bin/env python3
"""Tests scripts/check_docs.py: each case writes a small repository, changes
it and expects the check to pass or fail, so a change that lets the check
miss an oversized document or a broken reference, or refuse a sound one,
fails here. Run by scripts/check_docs.sh; standard library only.
"""

import pathlib
import subprocess
import sys
import tempfile

CHECK = pathlib.Path(__file__).resolve().parent / "check_docs.py"

PAGE = """\
# Page

## Text bodies (`FromBody`)

## Notes

## Notes

<a id="kept-anchor"></a>

See [the guide](../GUIDE.md#start), [this section](#text-bodies-frombody),
[the second notes](#notes-1), [an old anchor](#kept-anchor),
[`App`](../../src/muntin/app.mojo) and [upstream](https://example.com/x#y).
`scripts/check.sh` runs `tests/test_x.mojo`; `tests/*_fail/` is a pattern.

```mojo
app.get["/"](not_a_link)  # [x](missing.md)
```
"""


def write(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def run(files):
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        write(root, {
            "README.md": "# Readme\n\n[Guide](docs/GUIDE.md)\n",
            "docs/GUIDE.md": "# Guide\n\n## Start\n",
            "docs/reference/page.md": PAGE,
            "docs/history/decisions/m3-001-application-state-decision.md": "x" * 5000,
            "src/muntin/app.mojo": "# See docs/reference/page.md.\n",
            "scripts/check.sh": "",
            "tests/test_x.mojo": "",
            **files,
        })
        r = subprocess.run(
            [sys.executable, "-I", str(CHECK), str(root)],
            capture_output=True, text=True,
        )
        return r.returncode, r.stderr


CASES = [
    ("sound documents", {}, None),
    ("a link to a missing file", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](reference/gone.md)\n",
    }, "reference/gone.md: no such file"),
    ("a link to a missing heading", {
        "README.md": "# Readme\n\n[Guide](docs/GUIDE.md#stop)\n",
    }, 'no heading or id "stop" in docs/GUIDE.md'),
    ("a link to a missing heading in the same file", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#finish)\n",
    }, 'no heading or id "finish"'),
    ("a missing path in backticks", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\nRun `scripts/gone.sh`.\n",
    }, "`scripts/gone.sh`: no such file"),
    ("a missing path in backticks in history", {
        "docs/history/deferrals.md": "# Deferrals\n\nWas `scripts/gone.sh`.\n",
    }, None),
    ("a missing document named in code", {
        "tests/test_x.mojo": "# See docs/reference/gone.md.\n",
    }, "tests/test_x.mojo:1: docs/reference/gone.md: no such file"),
    ("a link after a long fence that holds a shorter one", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n````text\n```\n````\n[x](gone.md)\n",
    }, "gone.md: no such file"),
    ("a link-like line inside a long fence that holds a shorter one", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n````text\n```\n[x](gone.md)\n```\n````\n",
    }, None),
    ("a link-like line inside a tilde fence that holds backticks", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n~~~\n```\n[x](gone.md)\n~~~\n",
    }, None),
    ("a link after a fence in a block quote", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n> ```\n> code\n> ```\n\n[x](gone.md)\n",
    }, "gone.md: no such file"),
    ("a fence that never closes", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n```\n[x](gone.md)\n",
    }, "docs/GUIDE.md:5: this fence has no closing fence"),
    ("a reference definition to a missing file", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x][g]\n\n[g]: gone.md\n",
    }, "gone.md: no such file"),
    ("a reference definition to a missing heading", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x][g]\n\n[g]: <../README.md#stop> \"title\"\n",
    }, 'no heading or id "stop" in README.md'),
    ("a sound reference definition and a footnote", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x][g][^1]\n\n[g]: ../README.md#readme\n[^1]: Not a link.\n",
    }, None),
    ("links to setext and quoted headings", {
        "docs/GUIDE.md": ("# Guide\n\n## Start\n\n[a](#usage) [b](#more-usage) [c](#quoted)"
                          " [d](#listed)\n\nUsage\n-----\n\nMore\nusage\n=====\n\n"
                          "> ## Quoted\n\n- ### Listed\n"),
    }, None),
    ("a link to a thematic break, not a heading", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[a](#text)\n\nText\n\n---\n",
    }, 'no heading or id "text"'),
    ("a link to a list item above a rule", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[a](#--item)\n\n- item\n---\n",
    }, 'no heading or id "--item"'),
    ("a link to a paragraph that a code block separates from a rule", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[a](#text)\n\nText\n```\ncode\n```\n---\n",
    }, 'no heading or id "text"'),
    ("a quote marker inside a top-level fence", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n```text\n> ```\n[x](gone.md)\n```\n",
    }, None),
    ("a fence inside a block quote, closed inside it", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n> ```\n> [x](gone.md)\n> ```\n",
    }, None),
    ("a link after a quote that ends with its fence still open", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n> ```\n> code\n\n[x](gone.md)\n",
    }, "gone.md: no such file"),
    ("a link-like line in indented code", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n    [x](gone.md)\n",
    }, None),
    ("a link to a setext heading in a list item", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#usage)\n\n- Usage\n  -----\n",
    }, None),
    ("a link to text above a quoted rule", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#usage)\n\nUsage\n> -----\n",
    }, 'no heading or id "usage"'),
    ("a link to quoted text above an unquoted rule", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#usage)\n\n> Usage\n-----\n",
    }, 'no heading or id "usage"'),
    ("a reference definition with its destination on the next line", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x][g]\n[g]:\n  gone.md\n",
    }, "GUIDE.md:7: gone.md: no such file"),
    ("an HTML comment above a fence", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n<!-- note -->\n```\n[x](gone.md)\n```\n",
    }, None),
    ("a link to a quoted setext heading with a lazy line", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#usage-continued)\n\n> Usage\ncontinued\n> -----\n",
    }, None),
    ("a link to a heading just after a list", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n[x](#usage)\n\n- item\n\nUsage\n  -----\n",
    }, None),
    ("a link after a comment of several lines", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n<!--\nnote\n-->\n[x](gone.md)\n",
    }, "gone.md: no such file"),
    ("a link after an autolink", {
        "docs/NOTES.md": "# Notes\n\n<https://example.com>\n[x](gone.md)\n",
    }, "NOTES.md:4: gone.md: no such file"),
    ("a link after inline HTML that starts a line", {
        "docs/NOTES.md": "# Notes\n\n<code>x</code> and\n[x](gone.md)\n",
    }, "NOTES.md:4: gone.md: no such file"),
    ("a link after a tag that cannot interrupt a paragraph", {
        "docs/NOTES.md": "# Notes\n\ntext\n<span>\n[x](gone.md)\n",
    }, "NOTES.md:5: gone.md: no such file"),
    ("a link after an HTML block and a blank line", {
        "docs/NOTES.md": "# Notes\n\n<details>\n[x](skipped.md)\n\n[x](gone.md)\n",
    }, "NOTES.md:6: gone.md: no such file"),
    ("a link-like line in an HTML block that ends a quote", {
        "docs/NOTES.md": "# Notes\n\n> text\n<div>\n[x](gone.md)\n",
    }, None),
    ("a link after a one-line comment", {
        "docs/NOTES.md": "# Notes\n\n<!-- note -->\n[x](gone.md)\n",
    }, "NOTES.md:4: gone.md: no such file"),
    ("a link-like line in a comment across a blank line", {
        "docs/NOTES.md": "# Notes\n\n<!--\ncomment\n\n[example](gone.md)\n-->\n",
    }, None),
    ("a list item and a quote in a comment, and a link after it", {
        "docs/NOTES.md": "# Notes\n\n<!--\n- [example](gone.md)\n> [example](gone.md)\n-->\n[x](lost.md)\n",
    }, ["error: docs/NOTES.md:7: lost.md: no such file"]),
    ("a list item in a pre block, and a link after it", {
        "docs/NOTES.md": "# Notes\n\n<pre>\n- [example](gone.md)\n</pre>\n\n[x](lost.md)\n",
    }, ["error: docs/NOTES.md:7: lost.md: no such file"]),
    ("a list item in a div block, and a link after it", {
        "docs/NOTES.md": "# Notes\n\n<div>\n- [example](gone.md)\n\n[x](lost.md)\n",
    }, ["error: docs/NOTES.md:6: lost.md: no such file"]),
    ("a comment in a list item, and a link after the item", {
        "docs/NOTES.md": "# Notes\n\n- <!--\n  - [example](gone.md)\n  -->\n\n[x](lost.md)\n",
    }, ["error: docs/NOTES.md:7: lost.md: no such file"]),
    ("a link-like line in a pre block across a blank line", {
        "docs/NOTES.md": "# Notes\n\n<pre>\n\n[example](gone.md)\n</pre>\n",
    }, None),
    ("a fence in a list item across a blank line", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n\n- ```\n  code\n\n  [x](gone.md)\n  ```\n",
    }, None),
    ("the guide at its budget", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n".ljust(20 * 1024, "x"),
    }, None),
    ("the guide over its budget", {
        "docs/GUIDE.md": "# Guide\n\n## Start\n".ljust(20 * 1024 + 1, "x"),
    }, "docs/GUIDE.md: 20481 bytes, over its budget of 20480"),
    ("a reference page over its budget", {
        "docs/reference/other.md": "x" * (28 * 1024 + 1),
    }, "docs/reference/other.md: 28673 bytes"),
    ("a new decision record over its budget", {
        "docs/history/decisions/m3-099-new-decision.md": "x" * 5000,
    }, "m3-099-new-decision.md: 5000 bytes"),
]


def main():
    failed = 0
    for name, files, expected in CASES:
        code, err = run(files)
        if expected is None:
            ok = code == 0
        elif isinstance(expected, list):
            ok = code != 0 and err.splitlines() == expected  # these errors only
        else:
            ok = code != 0 and expected in err
        print(f"{'ok' if ok else 'FAIL'}: {name}")
        if not ok:
            failed += 1
            print(f"  exit {code}, stderr:\n{err}")
    if failed:
        sys.exit(1)


main()
