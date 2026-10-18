"""Prints scripts/bench_load.sh's runs as Markdown tables (Python standard
library only). Not run by CI.

    python3 bench/load/summarize.py RUNS_FILE

One row per worker count, case, protocol and implementation: the outcomes
summed over the rounds (bench/load/load.c says what each one means), and
the median over the rounds of the ok answers per second, their latency
percentiles, the server's CPU time per ok answer and its peak resident
memory. `flare/muntin` is the median of the rounds' ratios of ok answers
per second, with the smallest and the largest. A row marked `†` had answers
that were not ok: its rate is not a throughput comparison, read it with
the counts beside it. Stop runs get their own table: before and after the
signal, and when the server ended."""

import statistics
import sys
from collections import defaultdict

OUT = ["sent", "ok", "status", "invalid", "disconnected", "timeout"]


def num(v):
    return None if v in ("-", "") else float(v)


def med(rows, key):
    values = [num(r[key]) for r in rows if num(r.get(key, "-")) is not None]
    return statistics.median(values) if values else None


def fmt(v, scale=1.0, digits=0):
    return "-" if v is None else f"{v / scale:,.{digits}f}"


def total(rows, key):
    return sum(int(r[key]) for r in rows)


def ratio(by_impl):
    pairs = defaultdict(dict)
    for impl, rows in by_impl.items():
        for r in rows:
            pairs[r["round"]][impl] = float(r["ok_per_s"])
    values = [p["flare"] / p["muntin"] for p in pairs.values() if p.get("muntin") and p.get("flare")]
    if not values:
        return "-"
    return f"{statistics.median(values):.2f} ({min(values):.2f}–{max(values):.2f})"


def main():
    runs = []
    with open(sys.argv[1]) as f:
        for line in f:
            if line.strip():
                runs.append(dict(field.split("=", 1) for field in line.split()))
    groups = defaultdict(lambda: defaultdict(list))
    order = []
    for r in runs:
        key = (r["workers"], r["case"], r["proto"])
        if key not in groups:
            order.append(key)
        groups[key][r["impl"]].append(r)
    rounds = max(int(r["round"]) for r in runs)
    print(f"Rounds: {rounds}. Counts are sums over the rounds; rates, latencies, CPU and memory are medians.")
    for workers in sorted({k[0] for k in order}, key=int):
        print(f"\n### {workers} worker(s)\n")
        print("| case | proto | impl | sent | ok | status | invalid | disconnected | timeout | ok/s | p50 ms | p99 ms "
              "| server CPU µs/ok | peak RSS MiB | flare/muntin |")
        print("|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
        for key in order:
            if key[0] != workers or key[1] == "stop":
                continue
            by_impl = groups[key]
            for impl in ("muntin", "flare"):
                rows = by_impl.get(impl, [])
                if not rows:
                    continue
                counts = [total(rows, k) for k in OUT]
                bad = "†" if any(counts[2:]) else ""
                print(f"| {key[1]} | {key[2]} | {impl} | " + " | ".join(f"{c:,}" for c in counts)
                      + f" | {fmt(med(rows, 'ok_per_s'))}{bad} | {fmt(med(rows, 'p50_us'), 1000, 2)}"
                      f" | {fmt(med(rows, 'p99_us'), 1000, 2)} | {fmt(med(rows, 'srv_cpu_us_per_ok'), 1, 1)}"
                      f" | {fmt(med(rows, 'srv_rss_peak_kib'), 1024, 1)} | {ratio(by_impl) if impl == 'flare' else ''} |")
        slow = [k for k in order if k[0] == workers and any("slow_sent" in r for rs in groups[k].values() for r in rs)]
        if slow:
            print("\nThe slow requests of the runs above and below that send them (`GET /slow/20`):\n")
            print("| case | proto | impl | slow sent | slow ok | not ok | slow p50 ms | slow p99 ms |")
            print("|---|---|---|--:|--:|--:|--:|--:|")
            for key in slow:
                for impl in ("muntin", "flare"):
                    rows = groups[key].get(impl, [])
                    if not rows:
                        continue
                    sent, ok = total(rows, "slow_sent"), total(rows, "slow_ok")
                    print(f"| {key[1]} | {key[2]} | {impl} | {sent:,} | {ok:,} | {sent - ok:,}"
                          f" | {fmt(med(rows, 'slow_p50_us'), 1000, 1)} | {fmt(med(rows, 'slow_p99_us'), 1000, 1)} |")
        stops = [k for k in order if k[0] == workers and k[1] == "stop"]
        if stops:
            print("\nStop (SIGTERM 1 s into the window): requests sent before the signal and from it on, and the"
                  " server's end\n")
            print("| proto | impl | before: sent | ok | not ok | after: sent | ok | invalid | disconnected | timeout "
                  "| connect failed | exit ms |")
            print("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
            for key in stops:
                for impl in ("muntin", "flare"):
                    rows = groups[key].get(impl, [])
                    if not rows:
                        continue
                    sent = total(rows, "sent") + total(rows, "slow_sent")
                    ok = total(rows, "ok") + total(rows, "slow_ok")
                    exits = sorted(r["exit_ms"] for r in rows)
                    print(f"| {key[2]} | {impl} | {sent:,} | {ok:,} | {sent - ok:,} | {total(rows, 'after_sent'):,}"
                          f" | {total(rows, 'after_ok'):,} | {total(rows, 'after_invalid'):,}"
                          f" | {total(rows, 'after_disconnected'):,} | {total(rows, 'after_timeout'):,}"
                          f" | {total(rows, 'connect_failed'):,} | {', '.join(exits)} |")
    warm = sum(int(r["warmup_bad"]) for r in runs)
    stray = sum(int(r["stray"]) for r in runs)
    print(f"\nWarm-up requests not ok, all runs: {warm:,}. Connections with stray bytes: {stray:,}.")
    reasons = defaultdict(int)
    for r in runs:
        for key in ("invalid_as", "disconnected_as", "status_as"):
            if r[key] != "-":
                for item in r[key].split("|"):
                    n, _, text = item.partition(":")
                    reasons[(r["workers"], r["case"] + " " + r["proto"], r["impl"], key.split("_")[0], text.replace("_", " "))] += int(n)
    if reasons:
        print("\nWhy, all rounds (workers, case and protocol, impl, outcome, reason: count; warm-up included): "
              + "; ".join(f"{w} {c} {i} {o} {t}: {n:,}" for (w, c, i, o, t), n in sorted(reasons.items())))


if __name__ == "__main__":
    main()
