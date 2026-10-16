"""Reads scripts/bench_headers.sh's loopback lines (SERVER round=N SHAPE KIND
key=value...) from standard input and prints, per shape, kind and server,
the number of rounds and each value's median over them: median.py ROUNDS
CASES SERVER..., where CASES is a file of `SHAPE<tab>KIND` lines (what
`bench/headers/load.py --cases` prints). Fails, printing why, on a line of
another form, a server or case not named, or unless every named server has
exactly one line of every named case in each of rounds 1 to ROUNDS, with
the same keys."""

import collections
import statistics
import sys

rounds, servers = int(sys.argv[1]), sys.argv[3:]
cases = [tuple(line.rstrip("\n").split("\t")) for line in open(sys.argv[2])]
if not cases or any(len(c) != 2 for c in cases):
    raise SystemExit(f"error: {sys.argv[2]} is not SHAPE<tab>KIND lines")
rows = collections.defaultdict(dict)
problems = []
for n, line in enumerate(sys.stdin, 1):
    fields = line.rstrip("\n").split("\t")
    try:
        server, rnd, shape, kind = fields[:4]
        if server not in servers or (shape, kind) not in cases or not rnd.startswith("round="):
            raise ValueError
        values = dict(f.split("=", 1) for f in fields[4:])
        if not values:
            raise ValueError
        for k, v in values.items():
            float(v)
        r = int(rnd[len("round="):])
    except ValueError:
        problems.append(f"line {n} is not SERVER round=N SHAPE KIND key=value... of a named server and case: {line!r}")
        continue
    if r in rows[(shape, kind, server)]:
        problems.append(f"line {n}: a second {shape} {kind} line for {server} round {r}")
    rows[(shape, kind, server)][r] = values
for shape, kind in cases:
    for server in servers:
        got = rows.get((shape, kind, server), {})
        if sorted(got) != list(range(1, rounds + 1)):
            problems.append(f"{shape} {kind} {server}: rounds {sorted(got)}, expected 1 to {rounds}")
        elif len({tuple(v) for v in got.values()}) != 1:
            problems.append(f"{shape} {kind} {server}: rounds report different keys")
if problems:
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    raise SystemExit(1)
for (shape, kind, server), runs in sorted(rows.items()):
    first = next(iter(runs.values()))
    keys = [k for k in first if k != "bytes"]
    medians = " ".join(
        f"{k}={statistics.median(float(r[k]) for r in runs.values()):g}" for k in keys
    )
    print(f"{shape}\t{kind}\t{server}\trounds={len(runs)}\t{medians}")
