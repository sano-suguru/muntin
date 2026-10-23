#!/usr/bin/env python3
"""The kit of M3-086, the comparison by authors new to Muntin: it prepares
the workspace an author starts a task in, and checks what the author
delivers against hidden checks the author never sees. Not run by CI.

    python3 -I scripts/compare_authors.py prepare TASK PROGRAM DIR
    python3 -I scripts/compare_authors.py check TASK PROGRAM DIR
    python3 -I scripts/compare_authors.py selftest
    python3 -I scripts/compare_authors.py selftest places
    python3 -I scripts/compare_authors.py places TRANSCRIPT DIR [LISTING]

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
checks/TASK.tsv, in bench/compare/notes/scenario.tsv's steps; then it matches
DIR's API.md against each `doc REGEX WHAT` line of that file. It prints each
step and `misses N of M`, the checks that failed of all of them (all of
them when the program does not build). It exits 0 either way: a miss is a
result, not an error.

`selftest` prepares each task and program, requires the unchanged workspace
to miss at least one check (the task is not done already) and the workspace
with the reference solution applied to miss none: solutions/TASK_PROGRAM.diff,
or the fault undone, and solutions/TASK_API.diff on API.md when there is one.
Exits 1 otherwise.

`places` reads an author's transcript (Claude Code's JSONL) of a run in
workspace DIR and prints, as JSON, the run's wall-clock seconds, assistant
turns, tool calls and builds, and its places looked: the distinct paths
under DIR that a Read, Grep or Glob call or a reading command (cat, grep,
ls, sed, find and the like) names, each a path of the workspace or a glob
pattern matching one, and which of them are the framework's (docs/, lib/,
flare-src/, examples/, README.md); and the existing paths outside DIR that
one named, other than temporary ones (/tmp, /dev, /proc). A Bash call is
split as the shell splits it (quotes, operators, redirections, the call's
own variables) and starts in the directory the transcript gives it; a
command's patterns, scripts and option values are not paths; a recursive
grep, rg, ls or find with no path reads its directory. Reads by other
programs (python3, a loop's variable) are not seen. The workspace's paths
are LISTING's, one per line relative to DIR, when given, else DIR's on disk.
`selftest places` checks the splitting on PLACES_CASES alone; `selftest`
runs it first.

Needs pixi, patch, git and Python 3.9 or later, standard library only.
"""

import contextlib
import datetime
import fnmatch
import glob
import io
import json
import os
import pathlib
import re
import shlex
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
PIXI = shutil.which("pixi") or str(pathlib.Path.home() / ".pixi" / "bin" / "pixi")
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
        f"exec {PIXI} run --manifest-path {ROOT / 'pixi.toml'} --frozen -e flare "
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
    lines = (KIT / "checks" / f"{task}.tsv").read_text().splitlines()
    docs = [l.split("\t")[1:] for l in lines if l.startswith("doc\t")]
    scenario = work / "scenario.tsv"
    scenario.write_text("".join(l + "\n" for l in lines if not l.startswith("doc\t")))
    total = sum(1 for l in lines if l.split("\t")[0] in ("req", "field", "log", "said", "doc"))
    if compare_notes.build(work / "notes.mojo", work / "notes", work) != 0:
        print(f"does not build:\n{(work / 'notes.log').read_text()}")
        print(f"misses {total} of {total}")
        return total, total
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        compare_notes.run_scenario(task, compare_notes.Served(work / "notes", work / "run"), scenario)
    api = (pathlib.Path(workspace) / "API.md").read_text()
    for pattern, what in docs:
        verdict = "ok" if re.search(pattern, api, re.M) else "FAIL"
        captured.write(f"{verdict}\t{task}\t{what}\n")
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
            api = KIT / "solutions" / f"{task}_API.diff"
            if api.exists():
                patch(ws / "API.md", api)
            print(f"== {name}, solved")
            misses, _ = check(task, program, ws, quiet=True)
            if misses:
                print(f"FAIL\t{name}: the reference solution misses {misses}")
                ok = False
    print("selftest passed" if ok else "selftest FAILED")
    return ok


READERS = {"cat", "head", "tail", "sed", "grep", "egrep", "rg", "less", "more", "awk",
           "ls", "find", "wc", "nl", "diff", "tree", "file", "stat"}
# The options of a reading command that take the next word as their value.
VALUED = {
    "grep": {"-e", "-f", "-A", "-B", "-C", "-m", "--include", "--exclude", "--exclude-dir",
             "--regexp", "--file", "--max-count", "--context"},
    "rg": {"-e", "-f", "-A", "-B", "-C", "-m", "-g", "-t", "-T", "--glob", "--type",
           "--type-not", "--regexp", "--file", "--max-count", "--context"},
    "sed": {"-e", "-f", "--expression", "--file"},
    "awk": {"-f", "-v", "-F"},
    "head": {"-n", "-c"},
    "tail": {"-n", "-c"},
    "ls": {"-I", "--ignore"},
    "tree": {"-L", "-I", "-P"},
}
VALUED["egrep"] = VALUED["grep"]
OPERATORS = {";", "&", "&&", "|", "||", "(", ")", "\n", ";;", "|&"}
FRAMEWORK = ("docs", "lib", "flare-src", "examples", "README.md")
TEMP = ("/tmp", "/dev", "/proc")


def without_heredocs(cmd):
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        out.append(lines[i])
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", lines[i])
        i += 1
        if m:
            while i < len(lines) and lines[i].strip() != m.group(1):
                i += 1
            i += 1
    return "\n".join(out)


def commands(cmd):
    """The simple commands of a shell command line, each a list of words, as
    the shell splits them: quotes kept together, operators and newlines
    between commands, redirections apart (the word after `<` is kept as
    ("<", word), the word after `>` or `>>` dropped)."""
    lexer = shlex.shlex(without_heredocs(cmd), posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        tokens = list(lexer)
    except ValueError:  # an unclosed quote: the shell would not run it either
        return []
    out, words, redirect = [], [], None
    for t in tokens:
        if redirect:
            if redirect.startswith("<") and not t.isdigit():
                words.append(("<", t))
            redirect = None
        elif t in OPERATORS or (t and set(t) <= set(";&|\n")):
            if words:
                out.append(words)
            words = []
        elif t and set(t) <= set("<>&"):
            redirect = ">" if t.startswith("<<") else t  # a here-document's word is no file
            # `2>&1`: the shell's descriptor before it and after it are not words
            if words and isinstance(words[-1], str) and words[-1].isdigit():
                words.pop()
        else:
            words.append(t)
    if words:
        out.append(words)
    return out


def read_arguments(words):
    """The arguments of a reading command that name the paths it reads."""
    name, valued = words[0], VALUED.get(words[0], set())
    paths, operands, expect_value, expression = [], [], False, False
    pattern_given = False
    for w in words[1:]:
        if isinstance(w, tuple):  # `< file`
            paths.append(w[1])
            continue
        if expect_value:
            expect_value = False
            continue
        if name == "find" and (expression or w.startswith("-") or w in ("(", "!")):
            expression = True
            continue
        if w == "--":
            continue
        if w.startswith("--"):
            if w.split("=", 1)[0] in ("--regexp", "--file", "--expression"):
                pattern_given = True
            expect_value = w in valued
            continue
        if w.startswith("-") and len(w) > 1:
            flag = w[:2]
            if flag in ("-e", "-f") and name in ("grep", "egrep", "rg", "sed"):
                pattern_given = True
            if name == "awk" and flag == "-f":
                pattern_given = True
            expect_value = flag in valued and len(w) == 2
            continue
        operands.append(w)
    if name in ("grep", "egrep", "rg", "sed", "awk") and not pattern_given:
        operands = operands[1:]
    paths += operands
    recursive = name == "rg" or (name in ("grep", "egrep") and any(
        w in ("--recursive", "--dereference-recursive")
        or (isinstance(w, str) and re.fullmatch(r"-[a-zA-Z]*[rR][a-zA-Z]*", w)) for w in words[1:]))
    if not paths and (recursive or name in ("ls", "tree", "find")):
        paths = ["."]
    return paths


def resolve_cd(cwd, words):
    target = next((w for w in words[1:] if isinstance(w, str) and not w.startswith("-")), None)
    if target is None or target == "~":
        return str(pathlib.Path.home())
    return os.path.normpath(os.path.join(cwd, os.path.expanduser(target)))


KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}", "time"}


def expanded(word, env):
    if isinstance(word, tuple):
        return (word[0], expanded(word[1], env))
    return re.sub(r"\$(\w+)|\$\{(\w+)\}",
                  lambda m: env.get(m.group(1) or m.group(2), m.group(0)), word)


def bash_places(cmd, cwd):
    """The paths a Bash call's reading commands read, run from CWD, with the
    variables the call itself sets expanded."""
    found, env = [], {}
    for words in commands(cmd):
        while words and isinstance(words[0], str) and words[0] in KEYWORDS:
            words = words[1:]
        while words and isinstance(words[0], str) and re.fullmatch(r"\w+=.*", words[0]):
            name, value = words[0].split("=", 1)
            if len(words) == 1:
                env[name] = expanded(value, env)
            words = words[1:]  # `X=1` alone sets X; `LC_ALL=C grep ...` runs grep
        if not words or not isinstance(words[0], str):
            continue
        words = [expanded(w, env) for w in words]
        if words[0] in ("cd", "pushd"):
            cwd = resolve_cd(cwd, words)
        elif os.path.basename(words[0]) in READERS:
            words = [os.path.basename(words[0])] + words[1:]
            found += [os.path.normpath(os.path.join(cwd, a)) for a in read_arguments(words)]
    return found


def places(transcript, workspace, listing=None):
    ws = os.path.normpath(workspace)
    if listing:
        present = {os.path.normpath(l.strip()) for l in open(listing) if l.strip()}
    else:
        present = {os.path.relpath(os.path.join(d, n), ws)
                   for d, dirs, files in os.walk(ws) for n in dirs + files}
    present.add(".")
    times, turns, calls, builds = [], 0, 0, 0
    seen, outside = set(), set()

    def add(p):
        if p == ws or p.startswith(ws + "/"):
            rel = os.path.relpath(p, ws)
            if rel in present or (any(ch in rel for ch in "*?[")
                                  and any(fnmatch.fnmatch(q, rel) for q in present)):
                seen.add(rel)
        elif not p.startswith(TEMP) and (os.path.exists(p) or glob.glob(p)):
            outside.add(p)

    for line in open(transcript):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("timestamp"):
            times.append(datetime.datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00")))
        if e.get("type") != "assistant":
            continue
        turns += 1
        cwd = e.get("cwd") or ws  # where each Bash call starts
        for c in e.get("message", {}).get("content", []):
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            calls += 1
            name, inp = c.get("name"), c.get("input", {})
            if name == "Read":
                add(os.path.normpath(inp.get("file_path", "")))
            elif name in ("Grep", "Glob"):
                add(os.path.normpath(inp.get("path") or cwd))
            elif name == "Bash":
                builds += len(re.findall(r"build\.sh", inp.get("command", "")))
                for p in bash_places(inp.get("command", ""), cwd):
                    add(p)
    framework = sorted(p for p in seen if p.split("/")[0] in FRAMEWORK)
    print(json.dumps({
        "seconds": round((max(times) - min(times)).total_seconds()) if times else None,
        "turns": turns,
        "tool_calls": calls,
        "builds": builds,
        "places": len(seen),
        "framework_places": len(framework),
        "framework": framework,
        "other": sorted(p for p in seen if p.split("/")[0] not in FRAMEWORK),
        "outside": sorted(outside),
    }, indent=1))


# Shell command lines and the paths `places` must take them to read, from /w.
PLACES_CASES = [
    ("grep -r 'open' flare-src/flare", ["flare-src/flare"]),
    ("grep -r 'open|write' flare-src/flare", ["flare-src/flare"]),
    ("grep -r -e open flare-src/flare", ["flare-src/flare"]),
    ("grep -rn -e 'a;b' -e c docs lib", ["docs", "lib"]),
    ("grep -A 3 'x' API.md", ["API.md"]),
    ("grep --include='*.md' -rn tag .", ["."]),
    ("grep -rn tag", ["."]),
    ("grep tag", []),
    ("rg open", ["."]),
    ("rg -g '*.mojo' 'a|b' lib", ["lib"]),
    ("cat API.md | grep -n 'POST|GET'", ["API.md"]),
    ("sed -n '1,20p;30p' notes.mojo", ["notes.mojo"]),
    ("sed -e 's/a/b/' -n x.md", ["x.md"]),
    ("awk -F'\\t' '{print $1}' journal.log", ["journal.log"]),
    ("head -n 20 docs/GUIDE.md && tail -5 store.mojo", ["docs/GUIDE.md", "store.mojo"]),
    ("ls", ["."]),
    ("ls -la docs/reference/ 2>/dev/null; echo done", ["docs/reference"]),
    ("find lib -name '*.mojo' -type f", ["lib"]),
    ("find . -name 'a b'", ["."]),
    ("cd docs && cat 'reference/groups.md'", ["docs/reference/groups.md"]),
    ("cd /w/lib\ncat muntin/app.mojo # a comment > x", ["lib/muntin/app.mojo"]),
    ("wc -l < API.md", ["API.md"]),
    ("cat > out.txt <<'EOF'\ncat secret\nEOF\ncat a.md", ["a.md"]),
    ("echo 'cat x' | sh", []),
    ("LC_ALL=C grep -c x a.md 2>&1", ["a.md"]),
    ("diff -u a.mojo b.mojo", ["a.mojo", "b.mojo"]),
    ("for f in a b; do cat x.md; done", ["x.md"]),
    ("if true; then grep -n y API.md; fi", ["API.md"]),
    ("D=/w/docs && cat $D/GUIDE.md ${D}/README.md", ["docs/GUIDE.md", "docs/README.md"]),
]


def places_selftest():
    ok = True
    for cmd, want in PLACES_CASES:
        got = [os.path.relpath(p, "/w") for p in bash_places(cmd, "/w")]
        if got != want:
            print(f"FAIL\tplaces of {cmd!r}: {got}, expected {want}")
            ok = False
    print(f"places: {len(PLACES_CASES)} command lines" + ("" if ok else ", some FAILED"))
    return ok


def main():
    args = sys.argv[1:]
    if args[:1] == ["prepare"] and len(args) == 4:
        prepare(*args[1:])
    elif args[:1] == ["check"] and len(args) == 4:
        check(*args[1:])
    elif args[:1] == ["places"] and len(args) in (3, 4):
        places(*args[1:])
    elif args == ["selftest"]:
        sys.exit(0 if places_selftest() and selftest() else 1)
    elif args == ["selftest", "places"]:
        sys.exit(0 if places_selftest() else 1)
    else:
        fail(__doc__.split("\n\n")[1].strip())


if __name__ == "__main__":
    main()
