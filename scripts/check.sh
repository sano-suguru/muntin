#!/usr/bin/env bash
# Canonical static/build checks for Muntin. Exits nonzero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_MOJO="Mojo 1.1.0"
MOJO=(pixi run --frozen mojo)

step() { printf '\n== %s\n' "$*"; }

# CHECK_SHARD=I/N builds only the fixtures below whose position modulo N is
# I-1, so N runs with I = 1..N build each fixture exactly once. CI sets it;
# the default 1/1 builds all of them. Every other step runs in each shard on
# purpose, so a shard is an ordinary check.sh run; if those steps ever cost
# as much as a shard's fixtures, give the fixtures a job of their own.
shard="${CHECK_SHARD:-1/1}"
if [[ ! "$shard" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] ||
    (( BASH_REMATCH[1] > BASH_REMATCH[2] )); then
    echo "error: CHECK_SHARD must be I/N with 1 <= I <= N, got: $shard" >&2
    exit 1
fi
shard_i="${BASH_REMATCH[1]}"
shard_n="${BASH_REMATCH[2]}"

step "toolchain"
version="$("${MOJO[@]}" --version)"
echo "$version"
if [[ "$version" != "$EXPECTED_MOJO "* ]]; then
    echo "error: expected $EXPECTED_MOJO, found: $version" >&2
    exit 1
fi

step "format"
sources=(src tests main.mojo)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "${sources[@]}" "$tmp/"
"${MOJO[@]}" format --quiet "$tmp/src" "$tmp/tests" "$tmp/main.mojo"
for s in "${sources[@]}"; do
    if ! diff -ru "$s" "$tmp/$s"; then
        echo "error: $s is not formatted; run: pixi run format" >&2
        exit 1
    fi
done
echo "ok"

step "architecture boundary"
./scripts/check_boundaries.sh src/muntin

step "unsafe confinement"
./scripts/check_unsafe.sh

step "build package"
mkdir -p build
"${MOJO[@]}" precompile --Werror src/muntin -o build/muntin.mojoc
echo "ok"

# Library-only spike drivers. Mojo 1.1.0 accepts a circular import between
# two modules on one include path, so each spike's library side is copied with
# its driver into a directory without the application module that defines the
# application types, and built there. All build at once, then each runs in
# order.
lib_dirs=()
lib_titles=()
lib_pids=()
lib_only() { # DIR TITLE FILE...
    local dir="$tmp/$1" title="$2"
    shift 2
    mkdir -p "$dir"
    cp "$@" "$dir/"
    "${MOJO[@]}" build --Werror -I src -I "$dir" "$dir/driver.mojo" -o "$dir/driver" >"$dir/build.log" 2>&1 &
    lib_pids+=($!)
    lib_dirs+=("$dir")
    lib_titles+=("$title")
}

lib_only lib_only "extraction spike library builds without the application module" \
    tests/extraction_spike.mojo tests/extraction_lib_only/driver.mojo

lib_only response_lib_only "response spike library builds without the application module" \
    tests/response_spike.mojo tests/response_lib_only/driver.mojo

lib_only error_lib_only "error spike library builds without the application module" \
    tests/error_spike.mojo tests/error_lib_only/driver.mojo

lib_only error_response_lib_only "error-response spike library builds without the application module" \
    tests/error_response_spike.mojo tests/error_response_lib_only/driver.mojo

lib_only state_lib_only "state spike library builds without the application module" \
    tests/state_spike.mojo tests/scoped_state_spike.mojo tests/state_lib_only/driver.mojo

lib_only state_storage_lib_only "state-storage spike library builds without the application module" \
    tests/state_storage_spike.mojo tests/state_storage_lib_only/driver.mojo

lib_only headers_lib_only "headers spike library builds without the application module" \
    tests/headers_spike.mojo tests/headers_lib_only/driver.mojo

lib_only json_lib_only "JSON spike library builds without the application module" \
    tests/json_spike.mojo tests/json_lib_only/driver.mojo

lib_only middleware_lib_only "middleware spike library builds without the application module" \
    tests/middleware_spike.mojo tests/middleware_lib_only/driver.mojo

for i in "${!lib_pids[@]}"; do
    step "${lib_titles[i]}"
    if ! wait "${lib_pids[i]}"; then
        cat "${lib_dirs[i]}/build.log"
        echo "error: ${lib_dirs[i]}/driver.mojo failed to build" >&2
        exit 1
    fi
    "${lib_dirs[i]}/driver"
    echo "ok"
done

# Every fixture below is built by scripts/build_one.sh, one job per CPU, and
# its report is printed in file order.
fixtures=()

# tests/compile_fail: compile-time route checks; each must not build, failing
# with "constraint failed: <expected diagnostic>".
for t in tests/compile_fail/*.mojo; do fixtures+=(route "$t"); done

# Must-not-build fixtures whose expected text is the compiler's own
# diagnostic. Each file states what it pins; docs/ARCHITECTURE.md's revisit
# index maps each directory to the decision it protects.
must_fail_dirs=(tests/spike_fail tests/storage_fail tests/extraction_fail tests/body_fail tests/response_fail tests/error_fail tests/error_response_fail tests/raw_fail tests/state_fail tests/state_storage_fail tests/state_get_fail tests/state_post_fail tests/state_raw_fail tests/headers_fail tests/headers_api_fail tests/json_fail tests/json_api_fail tests/testclient_headers_api_fail tests/header_access_fail tests/with_headers_api_fail tests/registration_fail tests/registration_api_fail tests/get_headers_api_fail tests/string_route_api_fail tests/methods_api_fail tests/route_values_api_fail tests/optional_values_api_fail tests/middleware_fail tests/middleware_api_fail tests/body_bytes_api_fail tests/from_bytes_api_fail tests/bytes_headers_api_fail tests/bytes_limit_api_fail)
for dir in "${must_fail_dirs[@]}"; do
    for t in "$dir"/*.mojo; do fixtures+=(must_fail "$t"); done
done

# Known gaps the decisions rest on: each must build (--Werror) and is never
# run. One that stops building fires a revisit condition (docs/ARCHITECTURE.md,
# revisit index).
for t in tests/state_known_gaps/*.mojo tests/state_storage_known_gaps/*.mojo tests/headers_known_gaps/*.mojo tests/json_known_gaps/*.mojo tests/registration_known_gaps/*.mojo; do
    fixtures+=(known_gap "$t")
done

# Mojo 1.1.0 toolchain-wide soundness gaps: primitives that break the State
# alias property for std types and Muntin storage alike. Each must build
# (warnings allowed: the deprecated `memmove` warns) and is never run.
for t in tests/toolchain_soundness_gaps/*.mojo; do fixtures+=(toolchain_gap "$t"); done

total=$(( ${#fixtures[@]} / 2 ))
mine=()
for (( k = 0; k < total; k++ )); do
    if (( k % shard_n == shard_i - 1 )); then
        mine+=("${fixtures[2 * k]}" "${fixtures[2 * k + 1]}")
    fi
done
if (( ${#mine[@]} == 0 )); then
    echo "error: shard $shard_i/$shard_n of $total fixtures is empty" >&2
    exit 1
fi
fixtures=("${mine[@]}")

jobs="$(getconf _NPROCESSORS_ONLN)"
step "fixtures: must not build / must build ($(( ${#fixtures[@]} / 2 )) of $total files, shard $shard_i/$shard_n, $jobs jobs)"
mkdir -p "$tmp/fixtures"
status=0
printf '%s\0' "${fixtures[@]}" | xargs -0 -n 2 -P "$jobs" ./scripts/build_one.sh "$tmp/fixtures" || status=1
for (( i = 1; i < ${#fixtures[@]}; i += 2 )); do
    t="${fixtures[i]}"
    cat "$tmp/fixtures/${t//\//_}.log" 2>/dev/null || echo "error: no report for $t"
done
if (( status != 0 )); then
    echo "error: a fixture check failed (see above)" >&2
    exit 1
fi

step "build example"
"${MOJO[@]}" build --Werror -I src main.mojo -o build/muntin
echo "ok"
