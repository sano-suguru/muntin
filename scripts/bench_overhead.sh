#!/usr/bin/env bash
# What Muntin costs on top of Flare: one application written with Muntin
# (bench/overhead/muntin_app.mojo) and against Flare alone
# (bench/overhead/flare_app.mojo), same Flare, compiler, machine and build
# (default optimization, -O3). Not run by CI.
#
#   ./scripts/bench_overhead.sh
#
# In the `flare` environment it builds three programs under
# build/bench_overhead, then
# 1. runs bench_adapter: nanoseconds per request in process, no network, by
#    request header count and body size, with and without middleware
#    (bench/overhead/bench_adapter.mojo says what it measures);
# 2. serves the application from each implementation on loopback and loads
#    it with wrk over HTTP/1.1 keep-alive: requests per second, latency p50
#    and p99 (wrk's), errors, and the server's peak resident memory (VmHWM;
#    Linux only, `-` elsewhere), for each worker count, middleware off and
#    on, endpoint and connection count.
#
# Endpoints: plaintext (GET /plaintext), plaintext-h16 (the same with 16
# more request header fields, X-Bench-000 to X-Bench-015; wrk alone sends
# only Host, and Content-Length with a body), json-get (GET /json),
# json-post (POST /json, a 23-byte JSON body), echo-1k and echo-1m (POST
# /echo, 1 KiB and 1 MiB). Before an endpoint is loaded, curl sends it once to every
# implementation; the run fails unless each answers 200 with the expected
# body and all answers are identical but for the Date field, so both
# implementations put the same bytes on the wire.
#
# Implementations: `muntin` (Muntin's Server: `serve(app)` for one worker,
# `serve[make](workers=n)` for more, which share one listener); `flare`
# (Flare's HttpServer with its defaults: for several workers, one
# SO_REUSEPORT listener per worker); `flare-shared` (several workers only:
# FLARE_REUSEPORT_WORKERS=0, one shared listener as Muntin's workers use).
# Flare's workers are not pinned to cores (bench/overhead/server_flare.mojo).
#
# CPUs: where taskset exists (Linux), the allowed CPUs (Cpus_allowed_list in
# /proc/self/status, at least 2) are split in two: the first half runs the
# servers, the second wrk and the in-process program (on its last CPU).
#
# Settings, from the environment:
#   DURATION  seconds of each measured wrk run (default 10)
#   WARMUP    seconds of the unmeasured wrk run before it (default 2)
#   CONNS     connection counts (default "1 16 256")
#   WORKERS   worker counts (default "1 N", N the server CPU count, at least 2)
#   RUNS      timed runs per in-process case (default 15)
#   WRK       the wrk command (default: wrk 4.2.0 from conda-forge through
#             `pixi exec`, linux-64 only; elsewhere set WRK=wrk)
# Needs curl, cmp and awk.
set -euo pipefail
cd "$(dirname "$0")/.."

uint() { # NAME VALUE: refuses VALUE unless a decimal integer 1..999999
    if ! [[ $2 =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "error: $1 must be an integer from 1 to 999999: $2" >&2
        exit 1
    fi
}
duration="${DURATION-10}"
warmup="${WARMUP-2}"
runs="${RUNS-15}"
uint DURATION "$duration"
uint WARMUP "$warmup"
uint RUNS "$runs"
read -r -a conns <<<"${CONNS-1 16 256}"
for c in "${conns[@]}"; do uint CONNS "$c"; done
if ((${#conns[@]} == 0)); then
    echo "error: CONNS is empty" >&2
    exit 1
fi

srv_pin=()
wrk_pin=()
bench_pin=()
srv_cpus=0
wrk_cpus=1
if command -v taskset >/dev/null && [[ -r /proc/self/status ]]; then
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
    if ((${#cpus[@]} < 2)); then
        echo "error: needs at least 2 allowed CPUs, found: $allowed" >&2
        exit 1
    fi
    half=$((${#cpus[@]} / 2))
    srv_list="$(IFS=,; echo "${cpus[*]:0:half}")"
    wrk_list="$(IFS=,; echo "${cpus[*]:half}")"
    srv_cpus=$half
    wrk_cpus=$((${#cpus[@]} - half))
    srv_pin=(taskset -c "$srv_list")
    wrk_pin=(taskset -c "$wrk_list")
    bench_pin=(taskset -c "${cpus[-1]}")
    echo "# servers on CPUs $srv_list, wrk on CPUs $wrk_list"
else
    echo "# no taskset: servers and wrk are not pinned"
fi
read -r -a workers <<<"${WORKERS-1 $((srv_cpus > 2 ? srv_cpus : 2))}"
for w in "${workers[@]}"; do uint WORKERS "$w"; done

if [[ -n ${WRK-} ]]; then
    read -r -a wrk <<<"$WRK"
else
    wrk=(pixi exec --spec 'wrk==4.2.0' -- wrk)
fi

FLARE=(pixi run --frozen -e flare mojo)
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1
"${wrk[@]}" -v 2>&1 | head -n 1 || true
if [[ -r /proc/cpuinfo ]]; then
    sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | sort | uniq -c
fi

out=build/bench_overhead
mkdir -p "$out"
for prog in bench_adapter server_muntin server_flare; do
    start=$(date +%s)
    "${FLARE[@]}" build -I src -I adapters/flare -I bench/routing -I bench/overhead \
        "bench/overhead/$prog.mojo" -o "$out/$prog"
    echo "# $prog built in $(($(date +%s) - start)) s"
done

echo
echo "== in process (ns per request)"
${bench_pin[@]+"${bench_pin[@]}"} "./$out/bench_adapter" "$runs"

# Request bodies, and wrk scripts that send them.
printf '{"name":"Ada","age":36}' >"$out/json-post.body"
head -c 1024 /dev/zero | tr '\0' a >"$out/echo-1k.body"
head -c 1048576 /dev/zero | tr '\0' a >"$out/echo-1m.body"
for ep in json-post echo-1k echo-1m; do
    {
        echo 'wrk.method = "POST"'
        echo "local f = assert(io.open(\"$out/$ep.body\", \"rb\"))"
        echo 'wrk.body = f:read("*a")'
        echo 'f:close()'
        if [[ $ep == json-post ]]; then
            echo 'wrk.headers["Content-Type"] = "application/json"'
        fi
    } >"$out/$ep.lua"
done
endpoints=(plaintext plaintext-h16 json-get json-post echo-1k echo-1m)
extra_headers=()
for ((i = 0; i < 16; i++)); do
    extra_headers+=(-H "$(printf 'X-Bench-%03d: value-%03d' "$i" "$i")")
done
path_of() { case $1 in plaintext*) echo /plaintext ;; json-*) echo /json ;; echo-*) echo /echo ;; esac; }
expect_of() { # ENDPOINT FILE: writes the body ENDPOINT must answer to FILE
    case $1 in
    plaintext*) printf 'Hello, World!' >"$2" ;;
    json-get) printf '{"message":"Hello, World!"}' >"$2" ;;
    json-post) printf '{"id":1,"name":"Ada","age":36}' >"$2" ;;
    echo-*) cp "$out/$1.body" "$2" ;;
    esac
}

CURL=(curl -s --noproxy '*' --max-time 10)
pids=()
cleanup() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

start_server() { # IMPL WORKERS MW LOG: starts it on a free port; sets pid and port
    local impl=$1 env=()
    local prog=server_flare
    if [[ $impl == muntin ]]; then
        prog=server_muntin
    elif [[ $impl == flare-shared ]]; then
        env=(env FLARE_REUSEPORT_WORKERS=0)
    fi
    ${env[@]+"${env[@]}"} ${srv_pin[@]+"${srv_pin[@]}"} "./$out/$prog" 0 "$2" "$3" >"$4" 2>&1 &
    pid=$!
    pids+=("$pid")
    port=
    for _ in $(seq 100); do
        port="$(sed -n 's/^ready \([0-9]*\)$/\1/p' "$4")"
        [[ -n $port ]] && return 0
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    echo "error: $impl did not start:" >&2
    cat "$4" >&2
    exit 1
}

stop_server() { # PID
    kill "$1" 2>/dev/null || true
    for _ in $(seq 100); do
        kill -0 "$1" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

peak_rss() { # PID: VmHWM in KiB, or -
    if [[ -r /proc/$1/status ]]; then
        awk '/^VmHWM:/ { print $2; found = 1 } END { if (!found) print "-" }' "/proc/$1/status"
    else
        echo -
    fi
}

check() { # ENDPOINT PORT FILE: sends ENDPOINT once; the answer's head (no Date) and body to FILE
    local ep=$1 url="http://127.0.0.1:$2$(path_of "$1")" args=()
    case $ep in
    json-post) args=(-H 'Content-Type: application/json' --data-binary "@$out/$ep.body") ;;
    echo-*) args=(--data-binary "@$out/$ep.body") ;;
    plaintext-h16) args=("${extra_headers[@]}") ;;
    esac
    "${CURL[@]}" -D "$3.head" -o "$3.body" ${args[@]+"${args[@]}"} "$url"
    tr -d '\r' <"$3.head" | grep -iv '^date:' >"$3.head.nodate"
    if ! head -n 1 "$3.head.nodate" | grep -q '^HTTP/1.1 200 '; then
        echo "error: $ep: $(head -n 1 "$3.head.nodate")" >&2
        exit 1
    fi
    if ! cmp -s "$3.body" "$out/expect.body"; then
        echo "error: $ep: unexpected body" >&2
        exit 1
    fi
}

to_us() { # wrk's latency (123.45us, 1.23ms, 2.00s) in microseconds
    awk -v v="$1" 'BEGIN {
        n = v + 0
        if (v ~ /us$/) print n; else if (v ~ /ms$/) print n * 1000;
        else if (v ~ /s$/) print n * 1000000; else print "?" }'
}

load() { # IMPL ENDPOINT PORT CONNS PID LABEL: one warm-up run and one measured run
    local ep=$2 c=$4 threads=$4 args=()
    ((threads > wrk_cpus)) && threads=$wrk_cpus
    if [[ -f $out/$ep.lua ]]; then
        args=(-s "$out/$ep.lua")
    elif [[ $ep == plaintext-h16 ]]; then
        args=("${extra_headers[@]}")
    fi
    local url="http://127.0.0.1:$3$(path_of "$ep")"
    ${wrk_pin[@]+"${wrk_pin[@]}"} "${wrk[@]}" -t "$threads" -c "$c" -d "${warmup}s" \
        --timeout 10s ${args[@]+"${args[@]}"} "$url" >/dev/null
    local result
    result="$(${wrk_pin[@]+"${wrk_pin[@]}"} "${wrk[@]}" -t "$threads" -c "$c" -d "${duration}s" \
        --timeout 10s --latency ${args[@]+"${args[@]}"} "$url")"
    local rps p50 p99 errors
    rps="$(awk '/^Requests\/sec:/ { print $2 }' <<<"$result")"
    p50="$(to_us "$(awk '$1 == "50%" { print $2 }' <<<"$result")")"
    p99="$(to_us "$(awk '$1 == "99%" { print $2 }' <<<"$result")")"
    errors="$(awk '
        /^  Non-2xx or 3xx responses:/ { n += $5 }
        /^  Socket errors:/ { gsub(",", ""); n += $4 + $6 + $8 + $10 }
        END { print n + 0 }' <<<"$result")"
    printf '%s\tc=%s\t%s\treq_s=%s\tp50_us=%s\tp99_us=%s\terrors=%s\tpeak_rss_kib=%s\n' \
        "$6" "$c" "$1" "$rps" "$p50" "$p99" "$errors" "$(peak_rss "$5")"
}

echo
echo "== over loopback (wrk, HTTP/1.1 keep-alive, ${duration} s after ${warmup} s of warm-up)"
for w in "${workers[@]}"; do
    impls=(muntin flare)
    ((w > 1)) && impls+=(flare-shared)
    for mw in 0 1; do
        for ep in "${endpoints[@]}"; do
            expect_of "$ep" "$out/expect.body"
            declare -A pid_of=() port_of=()
            for impl in "${impls[@]}"; do
                start_server "$impl" "$w" "$mw" "$out/$impl.log"
                pid_of[$impl]=$pid
                port_of[$impl]=$port
                check "$ep" "$port" "$out/$impl.answer"
                if ! cmp -s "$out/$impl.answer.head.nodate" "$out/muntin.answer.head.nodate" ||
                    ! cmp -s "$out/$impl.answer.body" "$out/muntin.answer.body"; then
                    echo "error: $ep: $impl answers otherwise than muntin:" >&2
                    diff "$out/muntin.answer.head.nodate" "$out/$impl.answer.head.nodate" >&2 || true
                    exit 1
                fi
            done
            for c in "${conns[@]}"; do
                for impl in "${impls[@]}"; do
                    load "$impl" "$ep" "${port_of[$impl]}" "$c" "${pid_of[$impl]}" \
                        "workers=$w	mw=$mw	$ep"
                done
            done
            for impl in "${impls[@]}"; do
                stop_server "${pid_of[$impl]}"
            done
            pids=()
            unset pid_of port_of
        done
    done
done
