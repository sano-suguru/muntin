"""Reads scripts/bench_headers.sh's loopback lines (SERVER ROUND SHAPE KIND
key=value...) from standard input and prints, per server, shape and kind,
the number of rounds and each value's median over them."""

import collections
import statistics
import sys

rows = collections.defaultdict(list)
for line in sys.stdin:
    fields = line.rstrip("\n").split("\t")
    if len(fields) < 5 or not fields[1].startswith("round="):
        continue
    server, _, shape, kind = fields[:4]
    rows[(shape, kind, server)].append(dict(f.split("=", 1) for f in fields[4:]))
for (shape, kind, server), runs in sorted(rows.items()):
    keys = [k for k in runs[0] if k != "bytes"]
    medians = " ".join(
        f"{k}={statistics.median(float(r[k]) for r in runs):g}" for k in keys
    )
    print(f"{shape}\t{kind}\t{server}\trounds={len(runs)}\t{medians}")
