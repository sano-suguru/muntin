#!/usr/bin/env python3
"""Developer-experience comparison on a small application with state,
authentication, a failing dependency, start-up settings and one change: the
notes application written with Muntin (bench/compare/notes/notes_muntin.mojo)
and against Flare alone (notes_flare.mojo), both on the storage and settings
of bench/compare/notes/store.mojo. Not run by CI.

    python3 -I scripts/compare_notes.py

In the `flare` environment, it
1. counts each program's code lines (not blank, not a comment, not the module
   docstring), its import lines and the names it imports, and the code lines
   each file of the change (bench/compare/notes/change/*.diff) adds and
   removes;
2. builds both programs, and both with the change applied, and runs each
   through its scenario (scenario.tsv, then scenario_v2.tsv for the changed
   ones), restarting it, breaking and restoring its journal as the scenario
   says; it fails if a program answers otherwise (status, body and any
   field the scenario names) or does not log what the scenario names. It prints what each program wrote to standard error
   during each request. Then it prints both answers to defaults.tsv, which
   the scenario leaves open;
3. plants each mistake in mistakes.txt in a copy of the program it names and
   reports whether the copy builds: the compiler's first error if not,
   otherwise what the copy answers to the mistake's request and what it
   wrote to standard error. It builds at most COMPARE_JOBS copies at once
   (default 4), and fails if a copy does not build without a compiler error
   (such as a compiler killed for lack of memory), which is not a rejected
   mistake.

Builds and journals go under build/compare_notes. Every request has a 10 s
limit, on a new connection; a transfer that fails (such as a body shorter
than its Content-Length) fails a specified request whatever was received.
Needs pixi, patch and Python 3.9 or later, standard library only.
"""

import concurrent.futures
import http.client
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "bench" / "compare" / "notes"
OUT = ROOT / "build" / "compare_notes"
MOJO = ["pixi", "run", "--frozen", "-e", "flare", "mojo"]
TOKENS = "t-ada ada\nt-bo bo\n"
# The journal each defaults and mistake run starts on; the change adds a column.
SEED = "1\tada\tbuy milk\n2\tbo\tcall Ada\n"
SEED_V2 = "1\tada\tbuy milk\thome\n2\tbo\tcall Ada\twork\n"
PROGRAMS = ("muntin", "flare")


def step(title):
    print(f"\n== {title}", flush=True)


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def code_lines(text, module=True):
    if module and text.startswith('"""'):
        text = text[text.index('"""', 3) + 3 :]
    return [l for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


def sizes():
    print("file\tcode lines\timport lines\timported names")
    for name in ("notes_muntin", "notes_flare", "store"):
        code = code_lines((SRC / f"{name}.mojo").read_text())
        imports, names, depth = 0, 0, 0
        for line in code:
            s = line.strip()
            if depth or s.startswith(("from ", "import ")):
                imports += 1
                part = s.split(" import ", 1)[1] if " import " in s else s
                names += len([n for n in re.split(r"[(),\s]+", part) if n])
                depth += s.count("(") - s.count(")")
        print(f"{name}.mojo\t{len(code)}\t{imports}\t{names}")
    print("\nchange\tcode lines added\tcode lines removed")
    for name in ("notes_muntin", "notes_flare", "store"):
        diff = (SRC / "change" / f"{name}.diff").read_text().splitlines()
        body = [l for l in diff if not l.startswith(("---", "+++", "@@"))]

        def counted(sign):
            return len(code_lines("\n".join(l[1:] for l in body if l.startswith(sign)), module=False))

        print(f"{name}.diff\t{counted('+')}\t{counted('-')}")


def build(src, out, include):
    """Builds SRC to OUT with the store module from INCLUDE; returns the exit
    status, the compiler's output in OUT.log."""
    with open(f"{out}.log", "w") as log:
        cmd = [*MOJO, "build", "-I", "src", "-I", "adapters/flare", "-I", str(include)]
        return subprocess.run(
            [*cmd, str(src), "-o", str(out)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT
        ).returncode


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def ask(port, method, target, authorization="-", body="-", content_type="application/json"):
    """Sends one request; returns (status, headers, body) or raises OSError or
    http.client.HTTPException when the transfer fails."""
    headers = {}
    if authorization != "-":
        headers["Authorization"] = authorization
    data = None
    if body != "-":
        data = body.encode()
        if content_type != "-":
            headers["Content-Type"] = content_type
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request(method, target, body=data, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.getheaders(), resp.read()
    finally:
        conn.close()


class Served:
    """One program serving on a free port, its journal in DIR."""

    def __init__(self, binary, workdir):
        self.binary = binary
        self.dir = pathlib.Path(workdir)
        self.journal = self.dir / "journal.log"
        self.log = self.dir / "serve.log"
        self.proc = None
        self.port = None
        self.mark = 0
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "tokens").write_text(TOKENS)

    def start(self, max_text):
        self.stop()
        self.port = free_port()
        with open(self.log, "w") as log:
            self.proc = subprocess.Popen(
                [str(self.binary), str(self.port), str(self.journal), str(self.dir / "tokens"),
                 str(max_text)],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        for _ in range(100):
            try:
                ask(self.port, "GET", "/")
                self.mark = len(self.log.read_bytes())
                return
            except (OSError, http.client.HTTPException):
                if self.proc.poll() is not None:
                    break
                time.sleep(0.1)
        print(self.log.read_text(), file=sys.stderr)
        fail(f"{self.binary} did not answer on port {self.port}")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None

    def break_journal(self):
        if self.journal.exists():
            self.journal.rename(f"{self.journal}.saved")
        self.journal.mkdir()

    def restore_journal(self):
        self.journal.rmdir()
        saved = pathlib.Path(f"{self.journal}.saved")
        if saved.exists():
            saved.rename(self.journal)

    def logged(self):
        """What the program wrote since the previous call (or its start)."""
        data = self.log.read_bytes()
        new, self.mark = data[self.mark :], len(data)
        return new.decode(errors="replace")

    def since_start(self):
        return self.log.read_text(errors="replace")


def shown(body):
    return body.decode(errors="replace")


def print_log(text, indent="    "):
    for line in text.splitlines():
        print(f"{indent}stderr: {line}")


def run_scenario(name, served, path):
    """Runs the scenario in PATH against SERVED; returns False if any step
    fails."""
    ok, fields = True, {}
    for raw in path.read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        action, *args = raw.split("\t")
        if action == "start":
            served.start(args[0])
            print(f"{name}\tstarted, MAX_TEXT {args[0]}")
        elif action == "break":
            served.break_journal()
            print(f"{name}\tjournal broken")
        elif action == "restore":
            served.restore_journal()
            print(f"{name}\tjournal restored")
        elif action == "log":
            if args[0] in served.since_start():
                print(f"ok\t{name}\tlog names {args[0]!r}")
            else:
                print(f"FAIL\t{name}\tlog does not name {args[0]!r}")
                ok = False
        elif action == "field":
            got = fields.get(args[0].lower())
            if got == args[1]:
                print(f"ok\t{name}\t{args[0]}: {args[1]}")
            else:
                print(f"FAIL\t{name}\t{args[0]} is {got!r}, expected {args[1]!r}")
                ok = False
        elif action == "req":
            fields = {}
            method, target, authz, body, status, expected = args
            label = f"{method} {target} ({authz})"
            try:
                got_status, headers, got = ask(served.port, method, target, authz, body)
                fields = {k.lower(): v for k, v in headers}
            except (OSError, http.client.HTTPException) as e:
                print(f"FAIL\t{name}\t{label}\tthe transfer failed ({e!r})")
                print_log(served.logged())
                ok = False
                continue
            if got_status == int(status) and got == expected.encode():
                print(f"ok\t{name}\t{label}\t{status}")
            else:
                print(f"FAIL\t{name}\t{label}\t{got_status} {shown(got)}, expected {status} {expected}")
                ok = False
            print_log(served.logged())
        else:
            fail(f"{path}: unknown step {action!r}")
    served.stop()
    return ok


def seeded(served, seed=SEED, max_text=40):
    served.journal.write_text(seed)
    served.start(max_text)


def answer(served, method, target, authz, body, content_type):
    try:
        st, headers, got = ask(served.port, method, target, authz, body, content_type)
    except (OSError, http.client.HTTPException) as e:
        return f"the transfer failed ({e!r})"
    fields = {k.lower(): v for k, v in headers}
    extra = "".join(
        f"\t{k}: {fields[k]}" for k in ("content-type", "www-authenticate", "allow") if k in fields
    )
    return f"{st}{extra}\t{shown(got)}"


def parse_mistakes(path):
    blocks, cur = [], None
    for raw in path.read_text().splitlines():
        if raw.startswith("== "):
            name, prog, method, target, token, *body = raw[3:].split(" ", 5)
            cur = {"name": name, "prog": prog, "probe": (method, target, token, body[0] if body else "-"),
                   "broken": False, "hunks": []}
            blocks.append(cur)
        elif raw == "! broken-journal":
            cur["broken"] = True
        elif raw.startswith("- "):
            if not cur["hunks"] or cur["hunks"][-1][1]:
                cur["hunks"].append([[], []])
            cur["hunks"][-1][0].append(raw[2:])
        elif raw.startswith("+ ") and cur and cur["hunks"]:
            cur["hunks"][-1][1].append(raw[2:])
        elif raw.strip() and not raw.startswith("#"):
            fail(f"{path}: cannot read the line {raw!r}")
    for b in blocks:
        if not b["hunks"]:
            fail(f"{path}: {b['name']} ({b['prog']}) plants nothing")
    return blocks


def plant(block, source):
    lines = source.split("\n")
    edits = []
    for old, new in block["hunks"]:
        stripped = [l.strip() for l in lines]
        hits = [i for i in range(len(lines)) if stripped[i : i + len(old)] == old]
        if len(hits) != 1:
            fail(f"{block['name']} ({block['prog']}): expected the lines {old} exactly once, found {len(hits)}")
        i = hits[0]
        indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
        edits.append((i, len(old), [indent + l for l in new]))
    edits.sort()
    for (i, n, _), (j, _, _) in zip(edits, edits[1:]):
        if i + n > j:
            fail(f"{block['name']} ({block['prog']}): two runs of `-` lines overlap")
    for i, n, new in reversed(edits):
        lines[i : i + n] = new
    return "\n".join(lines)


def diagnostic(base):
    log = pathlib.Path(f"{base}.log").read_text().splitlines()
    src = pathlib.Path(f"{base}.mojo").read_text().split("\n")
    msg = next((l.split("note: ", 1)[1] for l in log if "note: constraint failed:" in l), None)
    if msg is None:
        msg = next((l.split("error: ", 1)[1] for l in log if re.match(r"\S+:\d+:\d+: error: ", l)), None)
    if msg is None:
        return None
    own = []
    for l in log:
        m = re.match(r"\S*" + re.escape(base.name) + r"\.mojo:(\d+):\d+: ", l)
        if m and int(m.group(1)) not in own:
            own.append(int(m.group(1)))
    where = "; ".join(f"line {n}: {src[n - 1].strip()}" for n in own)
    return f"{msg} [{len(log)} lines of compiler output; names {where}]"


def main():
    jobs = os.environ.get("COMPARE_JOBS", "4")
    if not re.fullmatch(r"[1-9][0-9]*", jobs):
        fail(f"COMPARE_JOBS must be a positive integer: {jobs}")
    subprocess.run([*MOJO, "--version"], cwd=ROOT, check=True)
    flare = subprocess.run(["pixi", "list", "--frozen", "-e", "flare", "^flare$"], cwd=ROOT,
                           check=True, capture_output=True, text=True)
    print(flare.stdout.strip().splitlines()[-1])
    shutil.rmtree(OUT, ignore_errors=True)
    v2 = OUT / "v2"
    v2.mkdir(parents=True)
    for f in SRC.glob("*.mojo"):
        shutil.copy(f, v2)
    for name in ("notes_muntin", "notes_flare", "store"):
        subprocess.run(["patch", "-s", "-p1", "-d", str(v2), "-i", str(SRC / "change" / f"{name}.diff")],
                       check=True)

    step("code size (lines that are not blank, a comment or the module docstring) and the change")
    sizes()

    step("build both programs, as written and with the change")
    targets = {}
    for prog in PROGRAMS:
        targets[prog] = (SRC / f"notes_{prog}.mojo", OUT / f"notes_{prog}", SRC)
        targets[f"{prog}-v2"] = (v2 / f"notes_{prog}.mojo", v2 / f"notes_{prog}", v2)
    with concurrent.futures.ThreadPoolExecutor(int(jobs)) as pool:
        status = dict(zip(targets, pool.map(lambda t: build(*t), targets.values())))
    for key, code in status.items():
        if code != 0:
            print(pathlib.Path(f"{targets[key][1]}.log").read_text())
            fail(f"{targets[key][0]} did not build")
        print(f"ok: {targets[key][1]}")

    passed = True
    for prog in PROGRAMS:
        step(f"the scenario (scenario.tsv), {prog}")
        served = Served(OUT / f"notes_{prog}", OUT / f"run_{prog}")
        passed &= run_scenario(prog, served, SRC / "scenario.tsv")
    for prog in PROGRAMS:
        step(f"the changed scenario (scenario_v2.tsv), {prog} with the change")
        served = Served(v2 / f"notes_{prog}", OUT / f"run_{prog}_v2")
        passed &= run_scenario(f"{prog}-v2", served, SRC / "scenario_v2.tsv")
    if not passed:
        fail("a program does not run its scenario as specified")

    step("left open by the scenario (defaults.tsv): status, fields, body, standard error")
    servers = {p: Served(OUT / f"notes_{p}", OUT / f"defaults_{p}") for p in PROGRAMS}
    for raw in (SRC / "defaults.tsv").read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        method, target, authz, body, ctype = raw.split("\t")
        sent = f"{method} {target} (Authorization: {authz.replace('-', 'none') if authz == '-' else authz})"
        if body != "-":
            sent += f" {body} (Content-Type: {'none' if ctype == '-' else ctype})"
        print(sent)
        for prog, served in servers.items():
            seeded(served)
            print(f"  {prog}\t{answer(served, method, target, authz, body, ctype)}")
            print_log(served.logged())
            served.stop()

    step(f"mistakes (mistakes.txt), built {jobs} at a time")
    blocks = parse_mistakes(SRC / "mistakes.txt")
    mistakes = OUT / "mistakes"
    mistakes.mkdir()
    builds = []
    for b in blocks:
        prog, changed = b["prog"].removesuffix("-v2"), b["prog"].endswith("-v2")
        tree = v2 if changed else SRC
        base = mistakes / f"{b['name']}_{b['prog']}"
        pathlib.Path(f"{base}.mojo").write_text(plant(b, (tree / f"notes_{prog}.mojo").read_text()))
        builds.append((pathlib.Path(f"{base}.mojo"), base, tree))
    with concurrent.futures.ThreadPoolExecutor(int(jobs)) as pool:
        codes = list(pool.map(lambda t: build(*t), builds))
    names = [b["name"] for b in blocks]
    unexplained = False
    for b, (_, base, _), code in zip(blocks, builds, codes):
        line = f"{b['name']}\t{b['prog']}\t"
        if names.count(b["name"]) < 2:
            line += "(no counterpart in the other program)\t"
        if code != 0:
            why = diagnostic(base)
            if why is None:
                why = f"no compiler error in {base}.log: the build failed for another reason"
                unexplained = True
            print(f"{line}does not build: {why}")
            continue
        method, target, token, body = b["probe"]
        served = Served(base, mistakes / f"run_{b['name']}_{b['prog']}")
        seeded(served, SEED_V2 if b["prog"].endswith("-v2") else SEED)
        if b["broken"]:
            served.break_journal()
        authz = "-" if token == "-" else f"Bearer {token}"
        print(f"{line}builds; {method} {target} -> {answer(served, method, target, authz, body, 'application/json')}")
        print_log(served.logged())
        served.stop()
    if unexplained:
        fail(f"a mistaken copy failed to build without a compiler error; see its log under {mistakes}")


if __name__ == "__main__":
    main()
