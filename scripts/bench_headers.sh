#!/usr/bin/env bash
# Request header conversion benchmark: the Flare adapter's
# `to_muntin_headers` and the rebuild M3-066 rejected, a prototype, in process by header
# shape (bench/headers/bench_headers.mojo says what it measures), then the
# same shapes over HTTP/1.1 loopback (bench/headers/load.py says what it
# sends) against three servers: a Muntin `Server` (`muntin_server`), the
# same with the adapter's conversion routed through the prototype
# (`muntin_pieces_server`, bench/headers/pieces_adapter.py, after
# bench/headers/write_to_pieces.mojo's tests of it pass) and Flare's
# `HttpServer` alone (`flare_server`). Not run by CI.
#
#   ./scripts/bench_headers.sh [RUNS] [SECONDS] [ROUNDS]
#
# RUNS (default 11) is the number of timed in-process runs per case;
# SECONDS (default 5) how long each loaded case runs; ROUNDS (default 1)
# how many times the three servers run in turn, each round starting one
# server later, so each is measured as often and in every position. Each
# loopback line starts with its server and round; each server's peak RSS
# follows its run (Linux), and the medians over the rounds come last
# (bench/headers/median.py, which fails unless every server has a line of
# every case bench/headers/load.py lists in every round). The in-process program and each server are
# pinned with taskset, where it exists (Linux), to the last CPU this
# process may run on; the client is not pinned.
# Needs python3.
set -euo pipefail
cd "$(dirname "$0")/.."

runs="${1-11}"
seconds="${2-5}"
rounds="${3-1}"
if ! [[ $runs =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "error: RUNS must be an integer from 1 to 999999: $runs" >&2
    exit 1
fi
if ! [[ $seconds =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "error: SECONDS must be an integer from 1 to 9999: $seconds" >&2
    exit 1
fi
if ! [[ $rounds =~ ^[1-9][0-9]{0,2}$ ]]; then
    echo "error: ROUNDS must be an integer from 1 to 999: $rounds" >&2
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
for prog in bench_headers write_to_pieces muntin_server flare_server; do
    "${FLARE[@]}" build -I src -I adapters/flare -I bench/headers "bench/headers/$prog.mojo" -o "$out/$prog"
done
python3 -I bench/headers/pieces_adapter.py adapters/flare "$out/pieces_adapter"
"${FLARE[@]}" build -I src -I "$out/pieces_adapter" -I bench/headers bench/headers/muntin_server.mojo -o "$out/muntin_pieces_server"

echo "# the prototype rebuild against the adapter's conversion (bench/headers/write_to_pieces.mojo)"
"./$out/write_to_pieces"

echo "# in process: to_muntin_headers (adapter) and the M3-066 rebuild (pieces)"
${pin[@]+"${pin[@]}"} "./$out/bench_headers" "$runs"

pid=
cleanup() {
    if [[ -n $pid ]]; then
        kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

servers=(muntin_server muntin_pieces_server flare_server)
: >"$out/loopback.log"
for round in $(seq 1 "$rounds"); do
    for i in 0 1 2; do
        server="${servers[$(((round - 1 + i) % 3))]}"
        port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
        ${pin[@]+"${pin[@]}"} "./$out/$server" "$port" >"$out/$server.log" 2>&1 &
        pid=$!
        for _ in $(seq 1 100); do
            if python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$port" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        echo "# loopback: $server round=$round"
        # Muntin's servers keep Server.bind's field limit, 100 (M3-066);
        # their answers past it must be 431.
        limit=100
        if [[ $server == flare_server ]]; then
            limit=0
        fi
        python3 -I bench/headers/load.py "$port" "$seconds" "$limit" |
            awk -v s="$server" -v r="round=$round" 'BEGIN { OFS = "\t" } { print s, r, $0 }' |
            tee -a "$out/loopback.log"
        if [[ -r /proc/$pid/status ]]; then
            echo "# $server round=$round peak_rss_kb=$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$pid/status")"
        fi
        kill "$pid"
        wait "$pid" 2>/dev/null || true
        pid=
    done
done
echo "# loopback medians over $rounds round(s)"
python3 -I bench/headers/load.py --cases >"$out/cases.tsv"
python3 -I bench/headers/median.py "$rounds" "$out/cases.tsv" "${servers[@]}" <"$out/loopback.log"
