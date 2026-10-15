#!/usr/bin/env bash
# M3-068's measurements (docs/history/architecture-decisions.md, "Worker
# connection spread decision (M3-068)"): Muntin's `Server` with 4 workers on
# Flare v0.12.0 as pinned, against the same Flare with flare_spread.patch
# applied. Linux only; not run by CI.
#
#   bench/hol/spread/run_spread.sh FLARE_CHECKOUT [RUNS]
#
# FLARE_CHECKOUT is a clean git checkout of Flare at v0.12.0 (8c6e140). The
# patch is applied to a copy of it under build/bench_hol/spread/. The pinned
# `flare` environment resolves `import flare` to its installed source before
# any `-I`, so the patched build uses a private copy of that environment
# (hard links, its own `modular.cfg`, the patched `flare` in place of the
# installed one) under build/bench_hol/spread/env; the pinned environment is
# never written. RUNS (default 5) is the number of runs per case. Prints, for
# `muntin` (the pin) and `patched`:
# - spread: bench/hol/hol_client.py's `spread` mode, idle timeout 60000 ms;
# - hold: every hol_client.py mode but `spread`, idle timeouts 500 and
#   60000 ms, one handler held 1000 ms;
# - fault: fail_listener_add.c preloaded, failing every listener
#   EPOLL_CTL_ADD after the sixth, then 12 requests one after another;
# - churn: churn.py, 8 threads, 5 s.
# Spread and hold are measurements and judge nothing. The script exits 1,
# after every section, if the patched server outlives the fault (it must end
# with `serve`'s "reactor returned before a stop signal") or if any churn
# attempt fails (churn.py checks each answer in full).
# The kernel probes run without Flare: python3 -I kernel_probe.py and
# kernel_probe_more.py in this directory.
set -euo pipefail
cd "$(dirname "$0")/../../.."

checkout="${1:?usage: run_spread.sh FLARE_CHECKOUT [RUNS]}"
runs="${2-5}"
[[ $runs =~ ^[1-9][0-9]{0,3}$ ]] || { echo "error: RUNS must be 1 to 9999" >&2; exit 1; }
[[ "$(git -C "$checkout" rev-parse --short=7 HEAD)" == 8c6e140 ]] ||
    { echo "error: $checkout is not Flare at 8c6e140" >&2; exit 1; }
[[ -z "$(git -C "$checkout" status --porcelain)" ]] ||
    { echo "error: $checkout has local changes" >&2; exit 1; }
pinned="$PWD/.pixi/envs/flare"
diff -rq "$checkout/flare" "$pinned/lib/mojo/flare" >/dev/null ||
    { echo "error: the pinned environment's flare differs from $checkout/flare" >&2; exit 1; }

FLARE=(pixi run --frozen -e flare mojo)
here=bench/hol/spread
dir=build/bench_hol/spread
mkdir -p "$dir"
"${FLARE[@]}" --version
uname -r
echo "# $(nproc) CPUs"

rm -rf "$dir/flare"
cp -r "$checkout" "$dir/flare"
git -C "$dir/flare" apply "$PWD/$here/flare_spread.patch"

"${FLARE[@]}" build -I src -I adapters/flare bench/hol/hol_muntin.mojo -o "$dir/hol_muntin"
env="$PWD/$dir/env"
rm -rf "$env"
cp -al "$pinned" "$env"
rm -rf "$env/lib/mojo/flare"
cp -r "$dir/flare/flare" "$env/lib/mojo/flare"
cfg="$env/share/max/modular.cfg"
sed "s#$pinned#$env#g" "$cfg" >"$cfg.new"
rm "$cfg"
mv "$cfg.new" "$cfg"
MODULAR_HOME="$env/share/max" CONDA_PREFIX="$env" "$env/bin/mojo" build \
    -I src -I adapters/flare bench/hol/hol_muntin.mojo -o "$dir/hol_patched"
cc -shared -fPIC -O2 -o "$dir/fail_listener_add.so" "$here/fail_listener_add.c" -ldl

fifo="$dir/signal.fifo"
pid=
failed=()
start() { # NAME IDLE_MS [ENV...]: starts the server and sets pid and port
    local out="$dir/port.txt" prog="$dir/hol_$1" idle="$2"
    shift 2
    rm -f "$fifo"
    mkfifo "$fifo"
    : >"$out"
    env "$@" HOL_SIGNAL="$fifo" "$prog" 4 "$idle" >"$out" 2>&1 &
    pid=$!
    for _ in $(seq 50); do [[ -s $out ]] && break; sleep 0.1; done
    port="$(awk '$1 == "port" { print $2 }' "$out")"
    [[ -n $port ]] || { echo "error: $prog did not report its port" >&2; cat "$out" >&2; exit 1; }
    sleep 0.3
}
stop() { if [[ -n $pid ]]; then kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=; fi; }
trap stop EXIT

echo "## spread"
for server in muntin patched; do
    for ((run = 1; run <= runs; run++)); do
        start "$server" 60000
        printf '%s idle_ms=60000 ' "$server"
        python3 -I bench/hol/hol_client.py "$port" spread 1000 "$fifo"
        stop
    done
done

echo "## hold"
for server in muntin patched; do
    for idle in 500 60000; do
        for mode in h1-new h1-pool h1-pool-fixed h2c-same h2c-other; do
            for ((run = 1; run <= runs; run++)); do
                start "$server" "$idle"
                printf '%s idle_ms=%s %s ' "$server" "$idle" "$mode"
                python3 -I bench/hol/hol_client.py "$port" "$mode" 1000 "$fifo"
                stop
            done
        done
    done
done

echo "## fault"
for server in muntin patched; do
    start "$server" 60000 LD_PRELOAD="$PWD/$dir/fail_listener_add.so" FAIL_LISTENER_ADD_AFTER=6
    printf '%s: ' "$server"
    python3 -I - "$port" <<'EOF'
import socket, sys
port, res = int(sys.argv[1]), []
for _ in range(12):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        data = b""
        while chunk := s.recv(4096):
            data += chunk
        s.close()
        res.append("ok" if data.startswith(b"HTTP/1.1 200") else "bad")
    except OSError as e:
        res.append(type(e).__name__)
print(" ".join(res))
EOF
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
        echo "  server still running"
        stop
        [[ $server == muntin ]] || failed+=("fault: the patched server outlived the failed registration")
    else
        status=0
        wait "$pid" || status=$?
        pid=
        why="$(grep 'serve:' "$dir/port.txt" | head -n 1)"
        echo "  server exited $status: $why"
        [[ $server == muntin || ($status != 0 && $why == *"reactor returned before a stop signal"*) ]] ||
            failed+=("fault: the patched server ended otherwise than by the failed registration")
    fi
done

echo "## churn"
for ((run = 1; run <= runs; run++)); do
    for server in muntin patched; do
        start "$server" 60000
        printf '%s ' "$server"
        python3 -I "$here/churn.py" "$port" "$pid" 5 8 || failed+=("churn: $server run $run had failed attempts")
        stop
    done
done

if ((${#failed[@]})); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "# every check passed"
