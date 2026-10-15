#!/usr/bin/env bash
# Request header conversion benchmark: the Flare adapter's
# `to_muntin_headers` in process by header shape
# (bench/headers/bench_headers.mojo says what it measures), then the same
# shapes over HTTP/1.1 loopback against a Muntin `Server` and against Flare's
# `HttpServer` alone (bench/headers/load.py says what it sends). Not run by
# CI.
#
#   ./scripts/bench_headers.sh [RUNS] [SECONDS]
#
# RUNS (default 11) is the number of timed in-process runs per case;
# SECONDS (default 5) how long each loaded case runs. The in-process program
# and each server are pinned with taskset, where it exists (Linux), to the
# last CPU this process may run on; the client is not pinned.
# Needs python3.
set -euo pipefail
cd "$(dirname "$0")/.."

runs="${1-11}"
seconds="${2-5}"
if ! [[ $runs =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "error: RUNS must be an integer from 1 to 999999: $runs" >&2
    exit 1
fi
if ! [[ $seconds =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "error: SECONDS must be an integer from 1 to 9999: $seconds" >&2
    exit 1
fi

FLARE=(pixi run --frozen -e flare mojo)
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1

pin=()
if command -v taskset >/dev/null && [[ -r /proc/self/status ]]; then
    allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)"
    cpu="${allowed##*[,-]}"
    if [[ $cpu =~ ^[0-9]+$ ]]; then
        pin=(taskset -c "$cpu")
    fi
fi

out=build/bench_headers
mkdir -p "$out"
for prog in bench_headers muntin_server flare_server; do
    "${FLARE[@]}" build -I src -I adapters/flare -I compat/flare/headers "bench/headers/$prog.mojo" -o "$out/$prog"
done

echo "# in process: to_muntin_headers (adapter) and the M3-066 rebuild (pieces)"
${pin[@]+"${pin[@]}"} "./$out/bench_headers" "$runs"

pid=
cleanup() {
    if [[ -n $pid ]]; then
        kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for server in muntin_server flare_server; do
    port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    ${pin[@]+"${pin[@]}"} "./$out/$server" "$port" >"$out/$server.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
        if python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$port" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    echo "# loopback: $server"
    python3 -I bench/headers/load.py "$port" "$seconds"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    pid=
done
