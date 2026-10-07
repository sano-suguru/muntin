#!/usr/bin/env bash
# Flare checks: builds and runs compat/flare, the Flare adapter's contract
# tests and its real localhost round trips (adapters/flare) against the Flare
# release pinned in pixi.toml's `flare` environment, and checks that the
# default environment (which builds src/muntin) cannot see Flare. Exits nonzero
# on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_MOJO="Mojo 1.1.0"
FLARE=(pixi run --frozen -e flare mojo)
DEFAULT=(pixi run --frozen mojo)
fixture=compat/flare/flare_smoke.mojo
adapter=adapters/flare
adapter_tests=$adapter/test_muntin_flare.mojo
serve_probe=$adapter/serve_probe.mojo
roundtrip=$adapter/test_localhost_roundtrip.mojo

step() { printf '\n== %s\n' "$*"; }

step "toolchain (flare environment)"
version="$("${FLARE[@]}" --version)"
echo "$version"
if [[ "$version" != "$EXPECTED_MOJO "* ]]; then
    echo "error: expected $EXPECTED_MOJO, found: $version" >&2
    exit 1
fi
FLARE_COMMIT="59bda50f46853f7351eef12f1737f7fb2287de71" # tag v0.11.0
listing="$(pixi list --frozen -e flare '^flare$')"
echo "$listing"
if ! grep -q "tag=v0.11.0#$FLARE_COMMIT" <<<"$listing"; then
    echo "error: flare env is not at v0.11.0 ($FLARE_COMMIT)" >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "format adapter"
cp -R "$adapter" "$tmp/adapter"
"${FLARE[@]}" format --quiet "$tmp/adapter"
if ! diff -ru "$adapter" "$tmp/adapter"; then
    echo "error: $adapter is not formatted; run: pixi run -e flare mojo format $adapter" >&2
    exit 1
fi
echo "ok"

# Every Flare binary is built here at once; the steps below run them in order.
mkdir -p build
pids=()
outs=()
build_bg() { # OUT ARGS...: mojo build --Werror ARGS -o build/OUT, in the background
    local out="$1"
    shift
    "${FLARE[@]}" build --Werror "$@" -o "build/$out" >"$tmp/build_$out.log" 2>&1 &
    pids+=($!)
    outs+=("$out")
}
step "build fixture, adapter tests and probes (in parallel)"
build_bg flare_smoke "$fixture"
build_bg test_muntin_flare -I src -I "$adapter" "$adapter_tests"
build_bg serve_probe -I src -I "$adapter" "$serve_probe"
build_bg test_localhost_roundtrip -I src -I "$adapter" "$roundtrip"
build_bg flare_header_probe -I src -I "$adapter" compat/flare/headers/flare_header_probe.mojo
build_bg inbound_rebuild -I src -I tests -I "$adapter" compat/flare/headers/inbound_rebuild.mojo
build_bg json_loopback_probe -I src -I tests -I "$adapter" compat/flare/json/json_loopback_probe.mojo
build_bg head_probe -I src -I "$adapter" compat/flare/head/head_probe.mojo
built=0
for i in "${!pids[@]}"; do
    if wait "${pids[i]}"; then
        echo "ok: build/${outs[i]}"
    else
        cat "$tmp/build_${outs[i]}.log"
        echo "error: build of build/${outs[i]} failed" >&2
        built=1
    fi
done
if ((built != 0)); then
    exit 1
fi

step "run fixture"
out="$(./build/flare_smoke)"
echo "$out"
if [[ "$out" != "200 hello" ]]; then
    echo "error: expected '200 hello' from $fixture" >&2
    exit 1
fi

step "run adapter tests"
if ! out="$(./build/test_muntin_flare 2>&1)"; then
    printf '%s\n' "$out"
    echo "error: adapter contract tests failed" >&2
    exit 1
fi
printf '%s\n' "$out"
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
    echo "error: $adapter_tests ran no tests" >&2
    exit 1
fi

step "serve probe (compile-only: HttpServer.serve accepts MuntinHandler)"
./build/serve_probe

step "run localhost round trip (GET /hello, typed GET routes, body-only and route-value-then-body POSTs over loopback: Flare -> MuntinHandler -> App.handle)"
# Output goes to a file, not a pipe: a leftover child holding the pipe would
# make the shell wait for it and hide it from the pgrep check below.
status=0
# NO_PROXY keeps Flare's client from routing loopback through an HTTP_PROXY.
NO_PROXY=127.0.0.1 ./build/test_localhost_roundtrip >"$tmp/roundtrip.log" 2>&1 || status=$?
cat "$tmp/roundtrip.log"
# The test forks a server child; it must be reaped, not left serving.
leftover='^\./build/test_localhost_roundtrip$'
if pgrep -f "$leftover"; then
    pkill -KILL -f "$leftover" || true
    echo "error: $roundtrip left a server process behind" >&2
    exit 1
fi
if ((status != 0)); then
    echo "error: localhost round trip failed" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/roundtrip.log"; then
    echo "error: $roundtrip ran no tests" >&2
    exit 1
fi
echo "ok: no server process left behind"

# M3-002 headers evidence (docs/history/architecture-decisions.md "Headers decision (M3-002)"):
# a self-checking probe of what pinned Flare preserves in request and
# response headers over loopback, and candidate D's fixture (a Flare
# HeaderMap cannot be a field of Muntin's Copyable Request).
step "Flare header probe (M3-002)"
probe_status=0
./build/flare_header_probe >"$tmp/header_probe.log" 2>&1 || probe_status=$?
cat "$tmp/header_probe.log"
leftover_probe='^\./build/flare_header_probe$'
if pgrep -f "$leftover_probe"; then
    pkill -KILL -f "$leftover_probe" || true
    echo "error: the header probe left a server process behind" >&2
    exit 1
fi
if ((probe_status != 0)); then
    echo "error: Flare header behavior differs from the recorded M3-002 evidence" >&2
    exit 1
fi

step "inbound header mapping rule against Flare (M3-002)"
if ! out="$(./build/inbound_rebuild 2>&1)"; then
    printf '%s\n' "$out"
    echo "error: the inbound header mapping rule failed" >&2
    exit 1
fi
printf '%s\n' "$out"
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
    echo "error: compat/flare/headers/inbound_rebuild.mojo ran no tests" >&2
    exit 1
fi

step "candidate D: Flare HeaderMap in a Copyable Request (must not build)"
fixture_d=compat/flare/headers/headermap_in_request.mojo
expected_d="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check_flare.sh): //p' "$fixture_d")"
if "${FLARE[@]}" build -I src "$fixture_d" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
    echo "error: $fixture_d built" >&2
    exit 1
fi
if ! grep -qF "$expected_d" "$tmp/log"; then
    cat "$tmp/log" >&2
    echo "error: $fixture_d failed without '$expected_d'" >&2
    exit 1
fi
echo "ok: $fixture_d"

# M3-008 JSON evidence (docs/history/architecture-decisions.md "JSON codec decision (M3-008)"):
# the request and response fields and body bytes the JSON contract relies on,
# over loopback through the adapter, with the decision spike's Json[T].
step "Flare JSON loopback probe (M3-008)"
json_status=0
NO_PROXY=127.0.0.1 ./build/json_loopback_probe >"$tmp/json_probe.log" 2>&1 || json_status=$?
cat "$tmp/json_probe.log"
leftover_json='^\./build/json_loopback_probe$'
if pgrep -f "$leftover_json"; then
    pkill -KILL -f "$leftover_json" || true
    echo "error: the JSON probe left a server process behind" >&2
    exit 1
fi
if ((json_status != 0)); then
    echo "error: Flare JSON behavior differs from the recorded M3-008 evidence" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/json_probe.log"; then
    echo "error: compat/flare/json/json_loopback_probe.mojo ran no tests" >&2
    exit 1
fi

# M3-026 HEAD evidence (docs/history/architecture-decisions.md "HEAD decision (M3-026)"):
# what pinned Flare and the adapter send for a HEAD response over HTTP/1.1
# and h2c, by where the content is dropped.
step "Flare HEAD probe (M3-026)"
head_status=0
./build/head_probe >"$tmp/head_probe.log" 2>&1 || head_status=$?
cat "$tmp/head_probe.log"
leftover_head='^\./build/head_probe$'
if pgrep -f "$leftover_head"; then
    pkill -KILL -f "$leftover_head" || true
    echo "error: the HEAD probe left a server process behind" >&2
    exit 1
fi
if ((head_status != 0)); then
    echo "error: Flare HEAD behavior differs from the recorded M3-026 evidence" >&2
    exit 1
fi

step "default environment excludes Flare"
for src in "$fixture" "$adapter_tests" "$serve_probe" "$roundtrip" compat/flare/headers/flare_header_probe.mojo compat/flare/headers/inbound_rebuild.mojo compat/flare/json/json_loopback_probe.mojo compat/flare/head/head_probe.mojo; do
    if "${DEFAULT[@]}" build -I src -I "$adapter" "$src" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
        echo "error: $src built in the default environment; Flare leaked into it" >&2
        exit 1
    fi
    if ! grep -q "unable to locate module 'flare'" "$tmp/log"; then
        cat "$tmp/log" >&2
        echo "error: default-environment build of $src failed for a reason other than missing Flare" >&2
        exit 1
    fi
done
echo "ok: module 'flare' is not available in the default environment"
