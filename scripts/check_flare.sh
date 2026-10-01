#!/usr/bin/env bash
# Flare checks (M1-001 to M1-003). Builds and runs compat/flare, the Flare
# adapter's contract tests and its real localhost round trip (adapters/flare)
# against the Flare release pinned in pixi.toml's `flare` environment, and
# checks that the default environment (which builds src/muntin) cannot see
# Flare. Exits nonzero on any failure.
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

step "build fixture"
mkdir -p build
"${FLARE[@]}" build --Werror "$fixture" -o build/flare_smoke
echo "ok"

step "run fixture"
out="$(./build/flare_smoke)"
echo "$out"
if [[ "$out" != "200 hello" ]]; then
    echo "error: expected '200 hello' from $fixture" >&2
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

step "build adapter tests"
"${FLARE[@]}" build --Werror -I src -I "$adapter" "$adapter_tests" -o build/test_muntin_flare
echo "ok"

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
"${FLARE[@]}" build --Werror -I src -I "$adapter" "$serve_probe" -o build/serve_probe
./build/serve_probe

step "build localhost round trip"
"${FLARE[@]}" build --Werror -I src -I "$adapter" "$roundtrip" -o build/test_localhost_roundtrip
echo "ok"

step "run localhost round trip (GET /hello over loopback: Flare -> MuntinHandler -> App.handle)"
# Output goes to a file, not a pipe: a leftover child holding the pipe would
# make the shell wait for it and hide it from the pgrep check below.
status=0
./build/test_localhost_roundtrip >"$tmp/roundtrip.log" 2>&1 || status=$?
cat "$tmp/roundtrip.log"
# The test forks a server child; it must be reaped, not left serving.
if pgrep -f build/test_localhost_roundtrip; then
    pkill -KILL -f build/test_localhost_roundtrip || true
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

step "default environment excludes Flare"
for src in "$fixture" "$adapter_tests" "$serve_probe" "$roundtrip"; do
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
