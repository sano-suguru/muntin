#!/usr/bin/env bash
# Flare compatibility check (M1-001). Builds and runs compat/flare against
# the Flare release pinned in pixi.toml's `flare` environment, and checks
# that the default environment (which builds src/muntin) cannot see Flare.
# Exits nonzero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_MOJO="Mojo 1.1.0"
FLARE=(pixi run --frozen -e flare mojo)
DEFAULT=(pixi run --frozen mojo)
fixture=compat/flare/flare_smoke.mojo

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

step "default environment excludes Flare"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if "${DEFAULT[@]}" build "$fixture" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
    echo "error: $fixture built in the default environment; Flare leaked into it" >&2
    exit 1
fi
if ! grep -q "unable to locate module 'flare'" "$tmp/log"; then
    cat "$tmp/log" >&2
    echo "error: default-environment build failed for a reason other than missing Flare" >&2
    exit 1
fi
echo "ok: module 'flare' is not available in the default environment"
