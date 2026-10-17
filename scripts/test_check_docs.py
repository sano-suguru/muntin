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
        else:
            ok = code != 0 and expected in err
        print(f"{'ok' if ok else 'FAIL'}: {name}")
        if not ok:
            failed += 1
            print(f"  exit {code}, stderr:\n{err}")
    if failed:
        sys.exit(1)


main()
