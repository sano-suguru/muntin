#!/usr/bin/env python3
"""Tests scripts/check_doc_examples.py: each case writes a small repository,
changes it and expects the check to pass or fail, so a change that lets the
check miss a drifted example, or refuse a matching one, fails here. Run by
scripts/check.sh; standard library only.
"""

import pathlib
import subprocess
import sys
import tempfile

CHECK = pathlib.Path(__file__).resolve().parent / "check_doc_examples.py"

TEST = """\
from muntin import App


# example: hello
def hello() -> String:
    return "hello"
# example: end


def other_main() raises:
    var app = App()
    # example: hello
    app.get["/other"](hello)  # GET /other -> 200 "hello"
    # example: end
"""

EXAMPLE = """\
def hello() -> String:
    return "hello"


app.get["/other"](hello)  # GET /other -> 200 "hello"\
"""

PAGE = """\
# Page

<!-- example: tests/test_x.mojo#hello -->
```mojo
{example}
```

<!-- example: examples/whole.mojo -->
```mojo
def main():
    pass
```

<!-- example: none: a sketch -->
```mojo
...
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
            "README.md": "# Readme\n",
            "docs/GUIDE.md": "# Guide\n",
            "docs/reference/page.md": PAGE.format(example=EXAMPLE),
            "tests/test_x.mojo": TEST,
            "examples/whole.mojo": "def main():\n    pass\n",
            **files,
        })
        r = subprocess.run(
            [sys.executable, "-I", str(CHECK), str(root)],
            capture_output=True, text=True,
        )
        return r.returncode == 0, r.stdout + r.stderr


CASES = [
    ("pass", "the file's text", {}),
    ("fail", "a code line differs", {
        "tests/test_x.mojo": TEST.replace('return "hello"', 'return "hi"')}),
    ("fail", "a comment differs", {
        "docs/reference/page.md": PAGE.format(
            example=EXAMPLE.replace("200", "201"))}),
    ("fail", "a whole file differs", {"examples/whole.mojo": "def main():\n    return\n"}),
    ("fail", "a block without a marker", {
        "docs/GUIDE.md": "# Guide\n\n```mojo\nx\n```\n"}),
    ("fail", "a Mojo fence not written ```mojo", {
        "docs/GUIDE.md": "# Guide\n\n- item:\n  ```mojo\n  x\n  ```\n"}),
    ("fail", "a drifted example fenced with four backticks", {
        "docs/GUIDE.md": "# Guide\n\n<!-- example: tests/test_x.mojo#hello -->\n````mojo\n"
        + EXAMPLE.replace("200", "201") + "\n````\n"}),
    ("fail", "a drifted example fenced with tildes", {
        "docs/GUIDE.md": "# Guide\n\n<!-- example: tests/test_x.mojo#hello -->\n~~~mojo\n"
        + EXAMPLE.replace("200", "201") + "\n~~~\n"}),
    ("fail", "a block without a marker fenced with four backticks", {
        "docs/GUIDE.md": "# Guide\n\n````mojo\nx\n````\n"}),
    ("fail", "a block without a marker fenced with tildes", {
        "docs/GUIDE.md": "# Guide\n\n~~~mojo\nx\n~~~\n"}),
    ("fail", "a whole-file example fenced with four backticks", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).replace(
            "```mojo\ndef main():\n    pass\n```",
            "````mojo\ndef main():\n    return\n````")}),
    ("fail", "a block without its closing fence", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).removesuffix("```\n")}),
    ("fail", "an unclosed block hiding a drifted one after it", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).removesuffix("```\n")
        + "\n<!-- example: examples/whole.mojo -->\n```mojo\ndef main():\n    return\n```\n"}),
    ("fail", "a Mojo block closed by four backticks", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).replace(
            "    pass\n```", "    pass\n````")}),
    ("fail", "a drifted example with its marker inside a quote", {
        "docs/GUIDE.md": "# Guide\n\n" + "\n".join(
            "> " + line for line in (
                "<!-- example: tests/test_x.mojo#hello -->\n```mojo\n"
                + EXAMPLE.replace("200", "201") + "\n```").split("\n")) + "\n"}),
    ("fail", "an example without a marker inside a quote", {
        "docs/GUIDE.md": "# Guide\n\n> ```mojo\n> x\n> ```\n"}),
    ("fail", "an example inside a list item", {
        "docs/GUIDE.md": "# Guide\n\n- ```mojo\n  x\n  ```\n"}),
    ("fail", "a marker with no ```mojo block after it", {
        "docs/GUIDE.md": "# Guide\n\n<!-- example: tests/test_x.mojo#hello -->\n\nText.\n"}),
    ("fail", "Mojo code in an HTML block", {
        "docs/GUIDE.md": '# Guide\n\n<pre><code class="language-mojo">x\n</code></pre>\n'}),
    ("pass", "a ```mojo line inside another block is text", {
        "docs/GUIDE.md": "# Guide\n\n````markdown\n```mojo\nx\n```\n````\n"}),
    ("fail", "a marker naming a missing region", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).replace("#hello", "#bye")}),
    ("fail", "a marker naming a missing file", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).replace(
            "examples/whole.mojo", "examples/gone.mojo")}),
    ("fail", "none without a reason", {
        "docs/reference/page.md": PAGE.format(example=EXAMPLE).replace(
            "none: a sketch", "none:")}),
    ("fail", "a region no block shows", {
        "tests/test_y.mojo": "# example: orphan\nx = 1\n# example: end\n"}),
    ("fail", "a region without its end", {
        "tests/test_x.mojo": TEST.replace("    # example: end\n", "")}),
    ("fail", "a region inside another", {
        "tests/test_x.mojo": TEST.replace(
            "    # example: end\n", "    # example: inner\n    # example: end\n")}),
    ("pass", "a renamed identifier", {
        "tests/test_x.mojo": TEST.replace("hello", "x_hello").replace(
            '"x_hello"', '"hello"').replace("/other", "/x_hello"),
        "docs/reference/page.md": PAGE.format(
            example=EXAMPLE.replace("/other", "/x_hello")).replace(
            "#hello -->", "#x_hello x_hello=hello -->"),
    }),
    ("fail", "a rename does not touch a path segment", {
        "tests/test_x.mojo": TEST.replace("hello", "x_hello").replace(
            '"x_hello"', '"hello"').replace("/other", "/x_hello"),
        "docs/reference/page.md": PAGE.format(
            example=EXAMPLE.replace("/other", "/hello")).replace(
            "#hello -->", "#x_hello x_hello=hello -->"),
    }),
]


def main():
    failures = 0
    for want, name, files in CASES:
        ok, out = run(files)
        got = "pass" if ok else "fail"
        if got != want:
            failures += 1
            print(f"FAIL: {name}: expected {want}, got {got}", file=sys.stderr)
            print("    " + out.replace("\n", "\n    "), file=sys.stderr)
        else:
            print(f"ok: {name} ({want})")
    if failures:
        print(f"error: {failures} of {len(CASES)} cases failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
