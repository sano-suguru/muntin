#!/usr/bin/env python3
"""JSON float reading cost: the working tree against a base revision, through
a `Json[T]` route (bench/json_float/bench_json_float.mojo says what a request
is). It measures M3-078's revisit condition. Not run by CI.

    python3 -I scripts/bench_json_float.py [--requests N] [--rounds N] [--base REV]

It exports the base's `src` (default 066e4d8, the last `main` that read
floats with Mojo's `atof`) under build/bench_json_float, builds the
benchmark against it and against the working tree's `src` (default
optimization), then runs the two programs in turn ROUNDS times (default 2),
REQUESTS requests per kind and route (default 60). For each run it prints
the program's table and its peak RSS and CPU time; then, among the kinds
both answer 200 on `/floats`, the one whose median p50 grew the most from
the base, both medians and their ratio. M3-078 is revisited when that ratio
passes 2.5 or the working tree's peak RSS is more than 10 % above the
base's. The base's other code differs too; `/count` (parsing alone) shows
how much. Linux and macOS; needs pixi, git and Python 3.9 or later, standard
library only.
"""

import argparse
import os
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "bench" / "json_float" / "bench_json_float.mojo"
OUT = ROOT / "build" / "bench_json_float"
MOJO = ["pixi", "run", "--frozen", "mojo"]


def export_src(rev: str, dest: Path) -> None:
    archive = subprocess.run(
        ["git", "archive", "--format=tar", rev, "src"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    subprocess.run(["tar", "-x", "-C", str(dest)], input=archive, check=True)


def build(src: Path, out: Path) -> None:
    subprocess.run(
        MOJO + ["build", "-I", str(src), str(BENCH), "-o", str(out)],
        cwd=ROOT, check=True,
    )


def run(program: Path, requests: int) -> tuple[list[list[str]], float, float]:
    """The program's rows, its peak RSS in MB and its CPU time in s."""
    proc = subprocess.Popen([str(program), str(requests)], stdout=subprocess.PIPE, text=True)
    out = proc.stdout.read()
    _, status, usage = os.wait4(proc.pid, 0)
    proc.returncode = os.waitstatus_to_exitcode(status)
    if proc.returncode != 0:
        sys.exit(f"error: {program} exited {proc.returncode}")
    # ru_maxrss is in KiB on Linux, bytes on macOS.
    scale = 1 << 20 if sys.platform == "darwin" else 1 << 10
    rows = [line.split("\t") for line in out.splitlines()]
    return rows, usage.ru_maxrss / scale, usage.ru_utime + usage.ru_stime


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests", type=int, default=60)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--base", default="066e4d8")
    args = parser.parse_args()
    if args.requests < 1 or args.rounds < 1:
        parser.error("--requests and --rounds must be at least 1")

    subprocess.run(MOJO + ["--version"], cwd=ROOT, check=True)
    base_rev = subprocess.run(
        ["git", "rev-parse", "--short", args.base],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.strip()
    export_src(args.base, OUT / "base")
    programs = {"base": OUT / "bench_base", "head": OUT / "bench_head"}
    build(OUT / "base" / "src", programs["base"])
    build(ROOT / "src", programs["head"])

    p50: dict[tuple[str, str], list[float]] = {}
    refused: set[str] = set()  # kinds a program answered other than 200
    rss: dict[str, list[float]] = {"base": [], "head": []}
    for round in range(1, args.rounds + 1):
        for name, program in programs.items():
            rows, peak, cpu = run(program, args.requests)
            label = f"base {base_rev}" if name == "base" else "working tree"
            print(f"\n== {label}, round {round}: peak RSS {peak:.1f} MB, CPU {cpu:.1f} s")
            print("kind\troute\tstatus\tp50 ms\tp95 ms\tp99 ms")
            for row in rows:
                print("\t".join(row[:3] + [f"{float(x):.2f}" for x in row[3:]]))
                p50.setdefault((name, row[0] + "\t" + row[1]), []).append(float(row[3]))
                if row[2] != "200":
                    refused.add(row[0])
            rss[name].append(peak)

    def median(name: str, kind: str) -> float:
        return statistics.median(p50[(name, kind + "\t/floats")])

    kinds = [key.split("\t")[0] for (name, key) in p50 if name == "head" and key.endswith("\t/floats")]
    kinds = [k for k in kinds if k not in refused]
    worst = max(kinds, key=lambda k: median("head", k) / median("base", k))
    head, base = median("head", worst), median("base", worst)
    print(f"\nlargest /floats growth: {worst}")
    print(f"median p50: {head:.2f} ms, base {base:.2f} ms, ratio {head / base:.2f} (M3-078: at most 2.5)")
    print(f"peak RSS: {max(rss['head']):.1f} MB, base {max(rss['base']):.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
