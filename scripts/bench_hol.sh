#!/usr/bin/env bash
# Head-of-line blocking measurement: what one slow handler does to the other
# requests of the process, Muntin's Server against Flare alone, by protocol,
# worker count, listener form and idle timeout (bench/hol/hol_client.py says
# what one run measures and prints). Linux only (the client's FIFO); not run
# by CI.
#
#   ./scripts/bench_hol.sh [RUNS] [SLOW_MS]
#
# RUNS is the number of runs per case (default 3), each against a freshly
# started server; SLOW_MS is how long the slow handler blocks its thread
# (default 1000). It builds bench/hol/hol_muntin.mojo and hol_flare.mojo in
# the `flare` environment, then prints one line per run, prefixed with its
# case (`<server> workers=<n> idle_ms=<ms> `), in four sections:
# - hold: every server, 1 and 4 workers, idle timeout 500 ms (Flare's
#   default) and 60000 ms, every client mode but `spread`. Servers: `muntin`,
#   `flare` (Flare's own workers, one SO_REUSEPORT listener each) and, with 4
#   workers only, `flare-shared` (the same with FLARE_REUSEPORT_WORKERS=0: one
#   listener shared by every worker, as Muntin's workers share one);
# - control: no slow request (SLOW_MS 0), `muntin` and `flare`, 1 worker,
#   500 ms, the kept-open modes: what the same probes get with nothing held;
# - idle: `muntin`, 1 worker, idle timeouts 750 to 2000 ms, the fixed pool
#   and h2c on one connection: where the lost requests stop;
# - spread: `muntin`, `flare` and `flare-shared` with 4 workers, how each
#   spreads kept-open connections over its workers; a run that loses a
#   connection is no measurement and ends the script with exit 1.
set -euo pipefail
cd "$(dirname "$0")/.."

runs="${1-3}"
slow_ms="${2-1000}"
for value in "$runs" "$slow_ms"; do
    if ! [[ $value =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "error: RUNS and SLOW_MS must be integers from 1 to 999999: $value" >&2
        exit 1
    fi
done

FLARE=(pixi run --frozen -e flare mojo)
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1
python3 --version
echo "# $(nproc) CPUs; $(uname -sm)"

dir=build/bench_hol
mkdir -p "$dir"
for prog in hol_muntin hol_flare; do
    "${FLARE[@]}" build -I src -I adapters/flare "bench/hol/$prog.mojo" -o "$dir/$prog"
done

fifo="$dir/signal.fifo"
pid=
start_server() { # SERVER WORKERS IDLE_MS: starts it and sets pid and port
    local out="$dir/port.txt" prog="$1" env=()
    if [[ $prog == flare-shared ]]; then
        prog=flare
        env=(FLARE_REUSEPORT_WORKERS=0)
    fi
    rm -f "$fifo"
    mkfifo "$fifo"
    : >"$out"
    env ${env[@]+"${env[@]}"} HOL_SIGNAL="$fifo" "./$dir/hol_$prog" "$2" "$3" >"$out" 2>&1 &
    pid=$!
    for _ in $(seq 50); do
        [[ -s $out ]] && break
        sleep 0.1
    done
    port="$(awk '$1 == "port" { print $2 }' "$out")"
    if [[ -z $port ]]; then
        echo "error: $1 did not report its port:" >&2
        cat "$out" >&2
        exit 1
    fi
    # Give a multi-worker server time to start its workers.
    sleep 0.3
}
stop_server() {
    if [[ -n $pid ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
    fi
}
trap stop_server EXIT

measure() { # SERVER WORKERS IDLE_MS MODE SLOW_MS: RUNS runs of one case
    for ((run = 1; run <= runs; run++)); do
        start_server "$1" "$2" "$3"
        printf '%s workers=%s idle_ms=%s ' "$1" "$2" "$3"
        python3 -I bench/hol/hol_client.py "$port" "$4" "$5" "$fifo"
        stop_server
    done
}

modes=(h1-new h1-pool h1-pool-fixed h2c-same h2c-other)
echo "## hold"
for server in muntin flare flare-shared; do
    for workers in 1 4; do
        [[ $server == flare-shared && $workers == 1 ]] && continue
        for idle in 500 60000; do
            for mode in "${modes[@]}"; do
                measure "$server" "$workers" "$idle" "$mode" "$slow_ms"
            done
        done
    done
done
echo "## control"
for server in muntin flare; do
    for mode in h1-pool h1-pool-fixed h2c-same; do
        measure "$server" 1 500 "$mode" 0
    done
done
echo "## idle"
for idle in 750 1000 1500 2000; do
    for mode in h1-pool-fixed h2c-same; do
        measure muntin 1 "$idle" "$mode" "$slow_ms"
    done
done
echo "## spread"
for server in muntin flare flare-shared; do
    measure "$server" 4 60000 spread "$slow_ms"
done
