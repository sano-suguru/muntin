#!/usr/bin/env python3
"""The kit of M3-086, the comparison by authors new to Muntin: it prepares
the workspace an author starts a task in, and checks what the author
delivers against hidden checks the author never sees. Not run by CI.

    python3 -I scripts/compare_authors.py prepare TASK PROGRAM DIR
    python3 -I scripts/compare_authors.py check TASK PROGRAM DIR
    python3 -I scripts/compare_authors.py selftest

TASK is one of tasks/*.md under bench/compare/authors (me, tag, journal,
bad-request); PROGRAM is muntin or flare: the notes application of
bench/compare/notes written with Muntin as it is now
(bench/compare/authors/notes_muntin.mojo) or against Flare alone
(bench/compare/notes/notes_flare.mojo).

`prepare` makes DIR, which must not exist, holding what the author gets and
nothing else: the program as notes_PROGRAM.mojo, with the task's fault
(faults/TASK_PROGRAM.diff) planted when it has one; store.mojo, with
tag_store.diff applied for the tag task; API.md, the contract with the
clients; TASK.md; a tokens file; build.sh and serve.sh; and the framework's
own documentation and source: Muntin's README.md, docs/GUIDE.md and
docs/reference/ under docs/, its packages under lib/ and its examples/; or
Flare's README.md, docs/, examples/ and source (flare-src/), from a checkout
of the tag pixi.toml pins, cloned once into build/compare_authors.

`check` builds DIR's notes_PROGRAM.mojo with the kit's store.mojo (not
DIR's) and this repository's src/ and adapters/flare/, and runs it through
checks/TASK.tsv, in bench/compare/notes/scenario.tsv's steps; it prints
each step and `misses N of M`, the checks that failed of all of them (all of
them when the program does not build). It exits 0 either way: a miss is a
result, not an error.

`selftest` prepares each task and program, requires the unchanged workspace
to miss at least one check (the task is not done already) and the workspace
with the reference solution applied to miss none: solutions/TASK_PROGRAM.diff,
or the fault undone. Exits 1 otherwise.

Needs pixi, patch, git and Python 3.9 or later, standard library only.
"""

import contextlib
import io
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import compare_notes  # noqa: E402  (its server driver and scenario runner)

KIT = ROOT / "bench" / "compare" / "authors"
NOTES = ROOT / "bench" / "compare" / "notes"
OUT = ROOT / "build" / "compare_authors"
TASKS = ("me", "tag", "journal", "bad-request")
PROGRAMS = ("muntin", "flare")
SOURCE = {"muntin": KIT / "notes_muntin.mojo", "flare": NOTES / "notes_flare.mojo"}


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def patch(path, diff, reverse=False):
    cmd = ["patch", "-s", "--no-backup-if-mismatch", str(path), str(diff)]
    if reverse:
        cmd.insert(1, "-R")
    if subprocess.run(cmd).returncode != 0:
        fail(f"{diff} does not apply to {path}")


def flare_checkout():
    tag = re.search(r'^flare = \{ git = "([^"]+)", tag = "([^"]+)" \}',
                    (ROOT / "pixi.toml").read_text(), re.M)
    if not tag:
        fail("pixi.toml pins no Flare tag")
    dest = OUT / f"flare-{tag.group(2)}"
    if not dest.exists():
        OUT.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "--branch", tag.group(2),
                        tag.group(1), str(dest)], check=True)
    return dest


def store_for(task, dest):
    shutil.copy(NOTES / "store.mojo", dest)
    if task == "tag":
        patch(dest, KIT / "tag_store.diff")


def prepare(task, program, dest):
    if task not in TASKS or program not in PROGRAMS:
        fail(f"no task {task!r} or program {program!r}")
    dest = pathlib.Path(dest)
    if dest.exists():
        fail(f"{dest} exists")
    dest.mkdir(parents=True)
    main = dest / f"notes_{program}.mojo"
    shutil.copy(SOURCE[program], main)
    fault = KIT / "faults" / f"{task}_{program}.diff"
    if fault.exists():
        patch(main, fault)
    store_for(task, dest / "store.mojo")
    shutil.copy(KIT / "API.md", dest / "API.md")
    shutil.copy(KIT / "tasks" / f"{task}.md", dest / "TASK.md")
    (dest / "tokens").write_text(compare_notes.TOKENS)
    if program == "muntin":
        docs = dest / "docs"
        docs.mkdir()
        shutil.copy(ROOT / "README.md", docs / "README.md")
        shutil.copy(ROOT / "docs" / "GUIDE.md", docs / "GUIDE.md")
        shutil.copytree(ROOT / "docs" / "reference", docs / "reference")
        shutil.copytree(ROOT / "src" / "muntin", dest / "lib" / "muntin")
        for name in ("muntin_flare.mojo", "flare_internals.mojo"):
            shutil.copy(ROOT / "adapters" / "flare" / name, dest / "lib" / name)
        shutil.copytree(ROOT / "examples", dest / "examples")
        include = "-I lib -I ."
    else:
        src = flare_checkout()
        shutil.copy(src / "README.md", dest / "README.md")
        shutil.copytree(src / "docs", dest / "docs")
        shutil.copytree(src / "examples", dest / "examples")
        shutil.copytree(src / "flare", dest / "flare-src" / "flare")
        include = "-I ."
    (dest / "build.sh").write_text(
        "#!/bin/sh\n"
        f"# Builds ./notes from notes_{program}.mojo.\n"
        'cd "$(dirname "$0")" || exit 1\n'
        f"exec pixi run --manifest-path {ROOT / 'pixi.toml'} --frozen -e flare "
        f"mojo build {include} notes_{program}.mojo -o notes\n")
    (dest / "serve.sh").write_text(
        "#!/bin/sh\n"
        "# Serves ./notes on 127.0.0.1:PORT (default 8080), its journal in\n"
        "# journal.log, its tokens in tokens (t-ada is ada, t-bo is bo), texts\n"
        "# up to 40 bytes.\n"
        'cd "$(dirname "$0")" || exit 1\n'
        'exec ./notes "${1:-8080}" journal.log tokens 40\n')
    for name in ("build.sh", "serve.sh"):
        (dest / name).chmod(0o755)


def check(task, program, workspace, quiet=False):
    """Returns (misses, checks)."""
    work = OUT / "check" / f"{task}_{program}_{pathlib.Path(workspace).name}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    shutil.copy(pathlib.Path(workspace) / f"notes_{program}.mojo", work / "notes.mojo")
    store_for(task, work / "store.mojo")
    scenario = KIT / "checks" / f"{task}.tsv"
    total = sum(1 for l in scenario.read_text().splitlines()
                if l.split("\t")[0] in ("req", "field", "log"))
    if compare_notes.build(work / "notes.mojo", work / "notes", work) != 0:
        print(f"does not build:\n{(work / 'notes.log').read_text()}")
        print(f"misses {total} of {total}")
        return total, total
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        compare_notes.run_scenario(task, compare_notes.Served(work / "notes", work / "run"), scenario)
    report = captured.getvalue()
    misses = sum(1 for l in report.splitlines() if l.startswith("FAIL\t"))
    if not quiet:
        print(report, end="")
    else:
        print("".join(l + "\n" for l in report.splitlines() if l.startswith("FAIL\t")), end="")
    print(f"misses {misses} of {total}")
    return misses, total


def selftest():
    ok = True
    base = OUT / "selftest"
    if base.exists():
        shutil.rmtree(base)
    for task in TASKS:
        for program in PROGRAMS:
            name = f"{task}_{program}"
            ws = base / name
            prepare(task, program, ws)
            print(f"== {name}, as handed out")
            misses, _ = check(task, program, ws, quiet=True)
            if misses == 0:
                print(f"FAIL\t{name}: the task is done already")
                ok = False
            main = ws / f"notes_{program}.mojo"
            solution = KIT / "solutions" / f"{name}.diff"
            if solution.exists():
                patch(main, solution)
            else:
                patch(main, KIT / "faults" / f"{name}.diff", reverse=True)
            print(f"== {name}, solved")
            misses, _ = check(task, program, ws, quiet=True)
            if misses:
                print(f"FAIL\t{name}: the reference solution misses {misses}")
                ok = False
    print("selftest passed" if ok else "selftest FAILED")
    return ok


def main():
    args = sys.argv[1:]
    if args[:1] == ["prepare"] and len(args) == 4:
        prepare(*args[1:])
    elif args[:1] == ["check"] and len(args) == 4:
        check(*args[1:])
    elif args == ["selftest"]:
        sys.exit(0 if selftest() else 1)
    else:
        fail(__doc__.split("\n\n")[1].strip())


if __name__ == "__main__":
    main()
