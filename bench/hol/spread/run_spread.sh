#!/usr/bin/env bash
# M3-069's comparison (docs/history/architecture-decisions.md, "Worker
# connection spread decision (M3-068)", its "Next slice (M3-069)"): Muntin's
# `Server` with 4 workers on Flare v0.12.0 as pinned, against each way of
# spreading kept-open connections. Linux only; not run by CI.
#
#   bench/hol/spread/run_spread.sh FLARE_CHECKOUT [SECTION...]
#
# FLARE_CHECKOUT is a clean git checkout of Flare at v0.12.0 (8c6e140). Each
# patched Flare is a copy of it under build/bench_hol/spread/, built in a
# private copy of the pinned `flare` environment (hard links, its own
# `modular.cfg`, the patched `flare` in place of the installed one), since
# that environment resolves `import flare` to its installed source before any
# `-I`; the pinned environment is never written. The variants:
# - pin: Flare v0.12.0 as pinned (a plain registration: every idle worker
#   wakes for a new connection and the first to accept takes it);
# - exclusive: flare_exclusive.patch, Flare's own fix for its issue #36
#   (29550b6, on main, in no tag yet): `EPOLLEXCLUSIVE` takes, nothing else
#   changes; what the next Flare tag gives Muntin's workers;
# - rotate: exclusive plus flare_rotate.patch: the unified shared loop adds
#   its listener with no silent fallback and removes and adds it after each
#   accept batch, with the failure policy its comments state (M3-068's
#   candidate; flare_spread.patch is that record's version of it);
# - reuseport: the pin with muntin_reuseport.patch applied to a copy of the
#   adapter: a `SO_REUSEPORT` listener per worker, worker 0 keeping the
#   `Server`'s own;
# - budget-K: the pin with flare_budget.patch built with
#   `-D FLARE_ACCEPT_BUDGET=K` (K = 1, 4, 16, 64): at most K connections
#   accepted per wake-up.
# NO_BUILD=1 skips the builds and runs the binaries a previous run left.
# SECTION is any of spread, backlog, load, budget, trials, stop, fault (all
# when none is given); compare.py and churn.py in this directory say what
# each run measures. Variants alternate within every section (runs in turn,
# trials interleaved). Spread and backlog: 20 runs per variant; load: 10;
# budget: 10; trials (hold-wait and after-hold) and stop: 1000 per variant.
# The script exits 1, after every section, if a run is no measurement
# (compare.py or churn.py exits nonzero: a lost connection, a failed answer,
# a hold it could not set up) or if fault's rotate server does not behave as
# its policy says. The kernel probes run without Flare: python3 -I
# kernel_probe.py and kernel_probe_more.py in this directory (M3-068).
set -euo pipefail
cd "$(dirname "$0")/../../.."

checkout="${1:?usage: run_spread.sh FLARE_CHECKOUT [SECTION...]}"
shift
sections=("$@")
((${#sections[@]})) || sections=(spread backlog load budget trials stop fault)
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
python3 --version
uname -r
echo "# $(nproc) CPUs"

env_with() { # NAME PATCH...: a private environment whose flare has PATCHes applied
    local name="$1" env="$PWD/$dir/env-$1"
    shift
    rm -rf "$dir/flare-$name" "$env"
    cp -r "$checkout" "$dir/flare-$name"
    for p in "$@"; do git -C "$dir/flare-$name" apply "$PWD/$here/$p"; done
    cp -al "$pinned" "$env"
    rm -rf "$env/lib/mojo/flare"
    cp -r "$dir/flare-$name/flare" "$env/lib/mojo/flare"
    local cfg="$env/share/max/modular.cfg"
    sed "s#$pinned#$env#g" "$cfg" >"$cfg.new"
    rm "$cfg"
    mv "$cfg.new" "$cfg"
}
build_in() { # ENV OUT [MOJO ARGS...]: builds hol_muntin with ENV's mojo
    local env="$PWD/$dir/env-$1" out="$2"
    shift 2
    MODULAR_HOME="$env/share/max" CONDA_PREFIX="$env" "$env/bin/mojo" build "$@" \
        -I src -I adapters/flare bench/hol/hol_muntin.mojo -o "$dir/hol_$out"
}

if [[ ${NO_BUILD-} == 1 ]]; then
    echo "# NO_BUILD=1: the binaries of the previous run"
else
"${FLARE[@]}" build -I src -I adapters/flare bench/hol/hol_muntin.mojo -o "$dir/hol_pin"
env_with exclusive flare_exclusive.patch
build_in exclusive exclusive
env_with rotate flare_exclusive.patch flare_rotate.patch
build_in rotate rotate
env_with budget flare_budget.patch
for k in 1 4 16 64; do build_in budget "budget-$k" -D "FLARE_ACCEPT_BUDGET=$k"; done
rm -rf "$dir/adapter-reuseport"
cp -r adapters/flare "$dir/adapter-reuseport"
patch -s -d "$dir/adapter-reuseport" -p3 <"$here/muntin_reuseport.patch"
"${FLARE[@]}" build -I src -I "$dir/adapter-reuseport" bench/hol/hol_muntin.mojo -o "$dir/hol_reuseport"
cc -shared -fPIC -O2 -o "$dir/fail_listener_add.so" "$here/fail_listener_add.c" -ldl
fi

main=(pin exclusive rotate reuseport)
failed=()
servers=()
pids=()
start() { # NAME IDLE_MS [GRACE_MS]: starts hol_NAME with 4 workers; appends
    #  NAME=PORT,FIFO,PID to servers and its pid to pids
    local name="$1" idle="$2" grace="${3-}" out="$dir/port-$1.txt" fifo="$dir/signal-$1.fifo"
    rm -f "$fifo"
    mkfifo "$fifo"
    : >"$out"
    HOL_SIGNAL="$fifo" "$dir/hol_$name" 4 "$idle" $grace >"$out" 2>&1 &
    local pid=$!
    for _ in $(seq 50); do [[ -s $out ]] && break; sleep 0.1; done
    local port
    port="$(awk '$1 == "port" { print $2 }' "$out")"
    [[ -n $port ]] || { echo "error: hol_$name did not report its port" >&2; cat "$out" >&2; exit 1; }
    servers+=("$name=$port,$fifo,$pid")
    pids+=("$pid")
}
stop_all() {
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    servers=()
    pids=()
}
trap stop_all EXIT
one() { # MODE NAME [ARGS...]: one compare.py run against a fresh hol_NAME
    local mode="$1" name="$2"
    shift 2
    start "$name" 60000
    sleep 0.3
    printf '%s ' "$name"
    python3 -I "$here/compare.py" "$mode" "${servers[0]}" "$@" || failed+=("$mode: $name: no measurement")
    stop_all
}

for section in "${sections[@]}"; do
    echo "## $section"
    case $section in
    spread)
        for ((run = 1; run <= 20; run++)); do
            for name in "${main[@]}"; do
                start "$name" 60000
                sleep 0.3
                port="${servers[0]#*=}"
                printf '%s ' "$name"
                python3 -I bench/hol/hol_client.py "${port%%,*}" spread 1000 x ||
                    failed+=("spread: $name run $run lost connections")
                stop_all
            done
        done
        ;;
    backlog)
        for ((run = 1; run <= 20; run++)); do
            for name in "${main[@]}" budget-1 budget-4 budget-16; do one backlog "$name"; done
        done
        ;;
    load)
        for ((run = 1; run <= 10; run++)); do
            for kind in keepalive steady; do
                for name in "${main[@]}"; do one "$kind" "$name"; done
            done
            for name in "${main[@]}"; do
                start "$name" 60000
                sleep 0.3
                local_pid="${pids[0]}"
                port="${servers[0]#*=}"
                printf '%s churn ' "$name"
                python3 -I "$here/churn.py" "${port%%,*}" "$local_pid" 5 8 || failed+=("churn: $name run $run had failed attempts")
                stop_all
            done
        done
        ;;
    budget)
        for ((run = 1; run <= 10; run++)); do
            for name in pin budget-1 budget-4 budget-16 budget-64 rotate; do one arrivals "$name"; done
        done
        ;;
    trials)
        for name in "${main[@]}"; do start "$name" 60000; done
        sleep 0.5
        python3 -I "$here/compare.py" trials 1000 "${servers[@]}" || failed+=("trials: no measurement")
        stop_all
        ;;
    stop)
        args=()
        for name in "${main[@]}"; do args+=("$name=$PWD/$dir/hol_$name"); done
        python3 -I "$here/compare.py" stop 1000 "${args[@]}" || failed+=("stop: no measurement")
        ;;
    fault)
        # fail_listener_add.so counts the listener adds that succeed: the
        # first 4 are the workers' own. Each case runs the pin and rotate:
        # - transient (ENOMEM, then ENOSPC): the next 3 attempts fail, then
        #   they succeed again; both must answer all 40 requests and keep
        #   serving;
        # - transient-late: as transient ENOMEM, the first failure returning
        #   only after 1500 ms, as when a slow handler ran earlier in the
        #   batch: rotate's 1000 ms count from the failure, so it must
        #   still recover;
        # - lasting: every attempt after 6 successes fails with ENOMEM:
        #   rotate must end, after its 1000 ms of retries, with serve's
        #   "reactor returned before a stop signal"; the pin never adds
        #   again and must keep serving;
        # - lost: the same with EBADF, which rotate does not retry: it must
        #   end the same way, without the 1000 ms wait;
        # - old kernel: every add asking for EPOLLEXCLUSIVE fails with
        #   EINVAL, as before Linux 4.5: both must keep serving, and rotate
        #   must say so once per worker.
        # Rotate must also say each failure's errno itself (`flare:` lines;
        # the shim's own lines do not count): retried and recovered for a
        # transient one, the worker stopping for a lasting or lost one.
        for kind in transient-enomem transient-enospc transient-late lasting lost old-kernel; do
            for name in pin rotate; do
                out="$dir/port-$name.txt"
                case $kind in
                transient-enomem) preload=(FAIL_LISTENER_ADD_AFTER=4 FAIL_LISTENER_ADD_COUNT=3) ;;
                transient-enospc) preload=(FAIL_LISTENER_ADD_AFTER=4 FAIL_LISTENER_ADD_COUNT=3 FAIL_LISTENER_ADD_ERRNO=28) ;;
                transient-late) preload=(FAIL_LISTENER_ADD_AFTER=4 FAIL_LISTENER_ADD_COUNT=3 FAIL_LISTENER_ADD_DELAY_MS=1500) ;;
                lasting) preload=(FAIL_LISTENER_ADD_AFTER=6) ;;
                lost) preload=(FAIL_LISTENER_ADD_AFTER=6 FAIL_LISTENER_ADD_ERRNO=9) ;;
                old-kernel) preload=(FAIL_LISTENER_ADD_EXCLUSIVE=1 FAIL_LISTENER_ADD_ERRNO=22) ;;
                esac
                env LD_PRELOAD="$PWD/$dir/fail_listener_add.so" "${preload[@]}" \
                    "$dir/hol_$name" 4 60000 >"$out" 2>&1 &
                pid=$!
                pids=("$pid")
                for _ in $(seq 50); do [[ -s $out ]] && break; sleep 0.1; done
                port="$(awk '$1 == "port" { print $2 }' "$out")"
                printf '%s %s: ' "$name" "$kind"
                answered=0
                python3 -I "$here/compare.py" sequential "$port" 40 || answered=$?
                sleep 1.2
                injected="$(grep -c '^fail_listener_add: ' "$out" || true)"
                refused="$(grep -c '^flare: EPOLLEXCLUSIVE refused' "$out" || true)"
                echo "  failures injected: $injected; fallbacks reported: $refused"
                grep '^flare: ' "$out" | sort | uniq -c | sed 's/^/  /' || true
                case $kind in
                transient-enospc) said=('errno 28); this worker retries' 'listener was added again') ;;
                transient-*) said=('errno 12); this worker retries' 'listener was added again') ;;
                lasting) said=('errno 12) after .* ms of retries; this worker stops') ;;
                lost) said=('errno 9); this worker stops') ;;
                *) said=() ;;
                esac
                if [[ $name == rotate ]]; then
                    for line in "${said[@]}"; do
                        grep -q "^flare: .*$line" "$out" ||
                            failed+=("fault: rotate $kind: did not say \"$line\"")
                    done
                fi
                [[ $injected -gt 0 ]] || [[ $name == pin && $kind != old-kernel ]] ||
                    failed+=("fault: $name $kind: no failure injected")
                [[ $name != rotate || $kind != old-kernel || $refused == 4 ]] ||
                    failed+=("fault: rotate old-kernel: $refused fallbacks reported, not 4")
                if kill -0 "$pid" 2>/dev/null; then
                    printf '  server still running; then: '
                    python3 -I "$here/compare.py" sequential "$port" 12 ||
                        failed+=("fault: $name $kind: a running server did not answer")
                    stop_all
                    [[ $name == pin || $kind == transient-* || $kind == old-kernel ]] ||
                        failed+=("fault: rotate outlived a $kind failure")
                    [[ $answered == 0 ]] || failed+=("fault: $name $kind: a request failed before")
                else
                    status=0
                    wait "$pid" || status=$?
                    pids=()
                    why="$(grep 'serve:' "$out" | head -n 1)"
                    echo "  server exited $status: $why"
                    [[ $name == rotate && ($kind == lasting || $kind == lost) && $status != 0 &&
                        $why == *"reactor returned before a stop signal"* ]] ||
                        failed+=("fault: $name $kind: ended otherwise than its policy says")
                fi
            done
        done
        # A stop and churn on other threads while one re-add in 3 fails:
        # every churn attempt before the stop is answered, and serve
        # returns 0 for SIGTERM.
        for name in pin rotate; do
            out="$dir/port-$name.txt"
            env LD_PRELOAD="$PWD/$dir/fail_listener_add.so" FAIL_LISTENER_ADD_AFTER=4 \
                FAIL_LISTENER_ADD_EVERY=3 "$dir/hol_$name" 4 60000 200 >"$out" 2>&1 &
            pid=$!
            pids=("$pid")
            for _ in $(seq 50); do [[ -s $out ]] && break; sleep 0.1; done
            port="$(awk '$1 == "port" { print $2 }' "$out")"
            printf '%s stop during churn: ' "$name"
            python3 -I "$here/compare.py" churnstop "$port" "$pid" || failed+=("fault: $name stop during churn")
            status=0
            wait "$pid" || status=$?
            pids=()
            echo "  server exited $status; failures injected: $(grep -c '^fail_listener_add: ' "$out" || true)"
            [[ $status == 0 ]] || failed+=("fault: $name did not return 0 for SIGTERM during churn")
        done
        ;;
    *)
        echo "error: unknown section $section" >&2
        exit 1
        ;;
    esac
done

if ((${#failed[@]})); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "# every check passed"
