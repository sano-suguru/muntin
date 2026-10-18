#!/usr/bin/env bash
# Muntin's Server against Flare alone under load, with every response
# checked: the application of bench/overhead (bench/load/server_muntin.mojo,
# server_flare.mojo, which add a blocking `GET /slow/{ms}`), both with every
# server setting at its default, loaded by bench/load/load.c over HTTP/1.1
# keep-alive and prior-knowledge h2c. Linux only; not run by CI.
#
#   ./scripts/bench_load.sh
#
# It first runs bench/load/test_load.py, which checks that the client counts
# a broken answer as broken; a failure there ends the script before anything
# is measured. Then, for each case below and worker count, ROUNDS times, it
# starts a fresh server of each implementation (in odd rounds muntin first,
# in even ones flare first), runs the client against it and kills it, and
# prints the client's line (bench/load/load.c says what each field means)
# prefixed with `round= workers= case= impl=`. The lines also go to
# build/bench_load/runs.txt, and bench/load/summarize.py prints them as
# tables: counts summed over the rounds, rates and percentiles as the
# median of the rounds, and `flare/muntin`, the ratio of the median ok
# answers per second.
#
# Every request carries a browser's navigation fields (load.c, BROWSER)
# except `plaintext-bare`'s. Cases, each over h1 (64 connections) and h2c (8
# connections of 8 streams) unless it says otherwise:
# - plaintext-bare, plaintext: GET /plaintext;
# - json-get: GET /json; json-post: POST /json, a 23-byte JSON body;
# - echo-1m: POST /echo with 1 MiB (4 connections, 1 stream each);
# - middleware: plaintext with the middleware, whose header is required;
# - slow-mix: plaintext, every 200th request `GET /slow/20` instead;
# - overload: every request `GET /slow/2`, from 1024 h1 connections or 64
#   h2c connections of 16 streams: more waiting than the workers answer
#   within the idle timeout (500 ms by default in both);
# - stop: slow-mix, with SIGTERM to the server 1 s into an 8 s window; the
#   `after_` fields count the requests sent from the signal on, `exit_ms`
#   when the server ended.
#
# CPUs: the allowed CPUs (at least 4) are split in two; the first half runs
# the servers, the second the client, one thread per CPU.
#
# Settings, from the environment:
#   ROUNDS    rounds (default 3)
#   DURATION  measured seconds of each run (default 5; stop runs 8)
#   WARMUP    warm-up seconds before it (default 1)
#   WORKERS   worker counts (default "1 2")
#   CASES     the cases to run (default: all, in the order above)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $(uname -s) != Linux ]]; then
    echo "error: bench_load.sh runs on Linux only" >&2
    exit 1
fi
uint() { # NAME VALUE: refuses VALUE unless a decimal integer 1..999999
    if ! [[ $2 =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "error: $1 must be an integer from 1 to 999999: $2" >&2
        exit 1
    fi
}
rounds="${ROUNDS-3}"
duration="${DURATION-5}"
warmup="${WARMUP-1}"
uint ROUNDS "$rounds"
uint DURATION "$duration"
uint WARMUP "$warmup"
read -r -a workers <<<"${WORKERS-1 2}"
for w in "${workers[@]}"; do uint WORKERS "$w"; done
all_cases=(plaintext-bare plaintext json-get json-post echo-1m middleware slow-mix overload stop)
read -r -a cases <<<"${CASES-${all_cases[*]}}"
for c in "${cases[@]}"; do
    if [[ " ${all_cases[*]} " != *" $c "* ]]; then
        echo "error: unknown case: $c" >&2
        exit 1
    fi
done

allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)"
cpus=()
IFS=, read -r -a ranges <<<"$allowed"
for r in "${ranges[@]}"; do
    if [[ $r =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((i = BASH_REMATCH[1]; i <= BASH_REMATCH[2]; i++)); do cpus+=("$i"); done
    elif [[ $r =~ ^[0-9]+$ ]]; then
        cpus+=("$r")
    fi
done
if ((${#cpus[@]} < 4)); then
    echo "error: needs at least 4 allowed CPUs, found: $allowed" >&2
    exit 1
fi
half=$((${#cpus[@]} / 2))
srv_pin=(taskset -c "$(IFS=,; echo "${cpus[*]:0:half}")")
cli_pin=(taskset -c "$(IFS=,; echo "${cpus[*]:half}")")
threads=$((${#cpus[@]} - half))

FLARE=(pixi run --frozen -e flare mojo)
echo "# $(git rev-parse HEAD)$(git diff --quiet HEAD -- src adapters bench scripts || echo ' (modified)')"
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1
cc --version | head -n 1
python3 --version
uname -srm
sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | sort | uniq -c
echo "# servers on CPUs ${cpus[*]:0:half}, the client on ${cpus[*]:half} ($threads threads)"

out=build/bench_load
mkdir -p "$out"
cc -O2 -Wall -Werror -pthread -o "$out/load" bench/load/load.c
python3 -I bench/load/test_load.py "$out/load" | tail -n 1
for prog in server_muntin server_flare; do
    "${FLARE[@]}" build -I src -I adapters/flare -I bench/overhead "bench/load/$prog.mojo" -o "$out/$prog"
done

printf '{"name":"Ada","age":36}' >"$out/json-post.body"
printf '{"id":1,"name":"Ada","age":36}' >"$out/json-post.expect"
python3 -I -c 'import sys; sys.stdout.buffer.write(bytes((i * 7 + i // 251) % 256 for i in range(1 << 20)))' \
    >"$out/echo-1m.body"

pid=
start_server() { # IMPL WORKERS MIDDLEWARE: sets pid and port
    local log="$out/$1.log"
    : >"$log"
    "${srv_pin[@]}" "./$out/server_$1" 0 "$2" "$3" >"$log" 2>&1 &
    pid=$!
    port=
    for _ in $(seq 100); do
        port="$(sed -n 's/^ready \([0-9]*\)$/\1/p' "$log")"
        [[ -n $port ]] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    if [[ -z $port ]]; then
        echo "error: $1 did not start:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 0.2 # the workers
}
stop_server() {
    if [[ -n $pid ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
    fi
}
trap stop_server EXIT

client_args() { # CASE PROTO: the client's arguments but --port and --pid; sets args and mw
    local proto=$2 dur=$duration headers=browser
    mw=0
    [[ $1 == stop ]] && dur=8
    [[ $1 == plaintext-bare ]] && headers=none
    args=(--proto "$proto" --threads "$threads" --warmup "$warmup" --duration "$dur" --headers "$headers")
    case $1 in
    echo-1m) args+=(--conns 4) ;;
    overload) if [[ $proto == h1 ]]; then args+=(--conns 1024); else args+=(--conns 64 --streams 16); fi ;;
    *) if [[ $proto == h1 ]]; then args+=(--conns 64); else args+=(--conns 8 --streams 8); fi ;;
    esac
    case $1 in
    plaintext-bare | plaintext) args+=(--path /plaintext --expect-text 'Hello, World!') ;;
    json-get) args+=(--path /json --expect-text '{"message":"Hello, World!"}') ;;
    json-post)
        args+=(--method POST --path /json --body "$out/json-post.body" --content-type application/json
            --expect "$out/json-post.expect")
        ;;
    echo-1m) args+=(--method POST --path /echo --body "$out/echo-1m.body" --expect "$out/echo-1m.body") ;;
    middleware)
        mw=1
        args+=(--path /plaintext --expect-text 'Hello, World!' --require-header 'X-Trace: 1')
        ;;
    slow-mix | stop)
        args+=(--path /plaintext --expect-text 'Hello, World!' --slow-path /slow/20 --slow-every 200)
        if [[ $1 == stop ]]; then args+=(--term-at 1000); fi
        ;;
    overload) args+=(--path /slow/2 --expect-text slow) ;;
    esac
}

: >"$out/runs.txt"
for ((r = 1; r <= rounds; r++)); do
    impls=(muntin flare)
    ((r % 2 == 0)) && impls=(flare muntin)
    for w in "${workers[@]}"; do
        for c in "${cases[@]}"; do
            for proto in h1 h2c; do
                client_args "$c" "$proto"
                for impl in "${impls[@]}"; do
                    start_server "$impl" "$w" "$mw"
                    line="$("${cli_pin[@]}" "./$out/load" --port "$port" --pid "$pid" "${args[@]}")"
                    stop_server
                    echo "round=$r workers=$w case=$c impl=$impl $line" | tee -a "$out/runs.txt"
                done
            done
        done
    done
done
echo
python3 -I bench/load/summarize.py "$out/runs.txt"
