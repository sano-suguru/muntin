#!/usr/bin/env bash
# Head-of-line blocking measurement: what one slow handler does to the other
# requests of the process, Muntin's Server against Flare alone, by protocol,
# worker count and idle timeout (bench/hol/hol_client.py says what one run
# measures and prints). Not run by CI.
#
#   ./scripts/bench_hol.sh [RUNS] [SLOW_MS]
#
# RUNS is the number of runs per case (default 3), each against a freshly
# started server; SLOW_MS is how long the slow handler blocks its thread
# (default 1000). It builds bench/hol/hol_muntin.mojo and hol_flare.mojo in
# the `flare` environment, then for each server, worker count (1, 4), idle
# timeout (Flare's default 500 ms; 60000 ms) and client mode prints one line
# per run: `<server> workers=<n> idle_ms=<ms> ` and the client's line; then,
# RUNS times per server with 4 workers, how it spreads long-lived connections
# over them (the client's `spread` mode).
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

pid=
start_server() { # SERVER WORKERS IDLE_MS: starts it and sets pid and port
    local out="$dir/port.txt"
    : >"$out"
    "./$dir/hol_$1" "$2" "$3" >"$out" 2>&1 &
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

for server in muntin flare; do
    for workers in 1 4; do
        for idle in 500 60000; do
            for mode in h1-new h1-pool h2c-same h2c-other; do
                for ((run = 1; run <= runs; run++)); do
                    start_server "$server" "$workers" "$idle"
                    printf '%s workers=%s idle_ms=%s ' "$server" "$workers" "$idle"
                    python3 -I bench/hol/hol_client.py "$port" "$mode" "$slow_ms"
                    stop_server
                done
            done
        done
    done
done
for server in muntin flare; do
    for ((run = 1; run <= runs; run++)); do
        start_server "$server" 4 60000
        printf '%s workers=4 ' "$server"
        python3 -I bench/hol/hol_client.py "$port" spread "$slow_ms"
        stop_server
    done
done
