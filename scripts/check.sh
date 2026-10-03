#!/usr/bin/env bash
# Canonical static/build checks for Muntin. Exits nonzero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_MOJO="Mojo 1.1.0"
MOJO=(pixi run --frozen mojo)

step() { printf '\n== %s\n' "$*"; }

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

step "build tests"
for t in tests/test_*.mojo; do
    "${MOJO[@]}" build --Werror -I src -I tests "$t" -o "$tmp/$(basename "$t" .mojo)"
done
echo "ok"

# The library side of the argument-extraction spike must not depend on the
# application module that defines its body types. Mojo 1.1.0 accepts a
# circular import between two modules on one include path, so build a driver
# that instantiates it from a directory without the application module.
step "extraction spike library builds without the application module"
mkdir -p "$tmp/lib_only"
cp tests/extraction_spike.mojo tests/extraction_lib_only/driver.mojo "$tmp/lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/lib_only" "$tmp/lib_only/driver.mojo" -o "$tmp/lib_only/driver"
"$tmp/lib_only/driver"
echo "ok"

# Same check for the typed-response spike (M2-007): its library side must
# convert return types defined only by the application.
step "response spike library builds without the application module"
mkdir -p "$tmp/response_lib_only"
cp tests/response_spike.mojo tests/response_lib_only/driver.mojo "$tmp/response_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/response_lib_only" "$tmp/response_lib_only/driver.mojo" -o "$tmp/response_lib_only/driver"
"$tmp/response_lib_only/driver"
echo "ok"

# Same check for the application-error spike (M2-010): its library side
# must catch error types defined only by the application.
step "error spike library builds without the application module"
mkdir -p "$tmp/error_lib_only"
cp tests/error_spike.mojo tests/error_lib_only/driver.mojo "$tmp/error_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/error_lib_only" "$tmp/error_lib_only/driver.mojo" -o "$tmp/error_lib_only/driver"
"$tmp/error_lib_only/driver"
echo "ok"

# Same check for the error-response spike (M2-012): its library side must
# detect an error-trait conformance declared only by the application.
step "error-response spike library builds without the application module"
mkdir -p "$tmp/error_response_lib_only"
cp tests/error_response_spike.mojo tests/error_response_lib_only/driver.mojo "$tmp/error_response_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/error_response_lib_only" "$tmp/error_response_lib_only/driver.mojo" -o "$tmp/error_response_lib_only/driver"
"$tmp/error_response_lib_only/driver"
echo "ok"

# Same check for the application-state spike (M3-001): its library side
# must store and inject state types defined only by the application.
step "state spike library builds without the application module"
mkdir -p "$tmp/state_lib_only"
cp tests/state_spike.mojo tests/scoped_state_spike.mojo tests/state_lib_only/driver.mojo "$tmp/state_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/state_lib_only" "$tmp/state_lib_only/driver.mojo" -o "$tmp/state_lib_only/driver"
"$tmp/state_lib_only/driver"
echo "ok"

# Same check for the state-storage spike (M3-004): its sealed box must
# share state types defined only by the application.
step "state-storage spike library builds without the application module"
mkdir -p "$tmp/state_storage_lib_only"
cp tests/state_storage_spike.mojo tests/state_storage_lib_only/driver.mojo "$tmp/state_storage_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/state_storage_lib_only" "$tmp/state_storage_lib_only/driver.mojo" -o "$tmp/state_storage_lib_only/driver"
"$tmp/state_storage_lib_only/driver"
echo "ok"

# Same check for the headers spike (M3-002): its raw transport must carry
# headers to handlers defined only by the application.
step "headers spike library builds without the application module"
mkdir -p "$tmp/headers_lib_only"
cp tests/headers_spike.mojo tests/headers_lib_only/driver.mojo "$tmp/headers_lib_only/"
"${MOJO[@]}" build --Werror -I src -I "$tmp/headers_lib_only" "$tmp/headers_lib_only/driver.mojo" -o "$tmp/headers_lib_only/driver"
"$tmp/headers_lib_only/driver"
echo "ok"

step "compile-time route checks (tests/compile_fail must not build)"
for t in tests/compile_fail/*.mojo; do
    expected="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check.sh): //p' "$t")"
    if [[ -z "$expected" ]]; then
        echo "error: $t has no expected diagnostic" >&2
        exit 1
    fi
    if "${MOJO[@]}" build -I src "$t" -o "$tmp/compile_fail" >"$tmp/log" 2>&1; then
        echo "error: $t compiled; Muntin no longer rejects it" >&2
        exit 1
    fi
    if ! grep -qF "constraint failed: $expected" "$tmp/log"; then
        cat "$tmp/log" >&2
        echo "error: $t failed without 'constraint failed: $expected'" >&2
        exit 1
    fi
    echo "ok: $t -> $expected"
done

# Fixtures whose expected text is the compiler's own diagnostic.
# tests/spike_fail: evidence for docs/ARCHITECTURE.md "Handler storage decision
# (M2)"; one that starts compiling after a toolchain change means the decision
# must be revisited. tests/storage_fail: production handler storage (M2-004)
# rejects a mismatched adapter and copies, App.get still accepts only the
# supported handler shapes, and result types must be String-compatible or
# conform to the non-raising ToResponse (M2-008); an error-only type is not a
# result and ToErrorResponse is non-raising (M2-013); raw handlers return
# Response and explicit raw function values have Mojo 1.1.0 limits (M2-015).
# tests/extraction_fail: evidence for
# docs/ARCHITECTURE.md "Argument extraction decision" (M2-005).
# tests/body_fail: App.post accepts only the body-only (M2-006), the
# route-value-then-body (M2-009) and the raw (M2-015) shapes, and App.get takes
# no body handler. tests/response_fail: evidence for
# docs/ARCHITECTURE.md "Typed response decision (M2-007)". tests/error_fail:
# evidence for docs/ARCHITECTURE.md "Application-error decision (M2-010)".
# tests/error_response_fail: evidence for docs/ARCHITECTURE.md
# "Error-response decision (M2-012)". tests/raw_fail: evidence for
# docs/ARCHITECTURE.md "Raw Request decision (M2-014)". tests/state_fail:
# evidence for docs/ARCHITECTURE.md "Application state decision (M3-001)".
# tests/state_storage_fail: evidence for docs/ARCHITECTURE.md "State storage
# decision (M3-004)". tests/headers_fail: evidence for docs/ARCHITECTURE.md
# "Headers decision (M3-002)". tests/headers_api_fail: the same invariants
# on production muntin.Headers and Request (M3-005). tests/state_get_fail: production App.get takes a
# stateful handler only with its State, first, borrowed and read-only; a
# reference from state[] cannot outlive its handle; a second handle cannot
# replace or mutate the shared value (M3-003). tests/state_post_fail: the
# same for production App.post, whose stateful shapes take the body last
# (M3-006). tests/state_raw_fail: the stateful raw shape on both methods
# takes its State, first, borrowed and read-only, then only the Request, and
# returns Response (M3-007); the reference-lifetime and second-handle cases
# are the shared State's, pinned in tests/state_get_fail.
for dir in tests/spike_fail tests/storage_fail tests/extraction_fail tests/body_fail tests/response_fail tests/error_fail tests/error_response_fail tests/raw_fail tests/state_fail tests/state_storage_fail tests/state_get_fail tests/state_post_fail tests/state_raw_fail tests/headers_fail tests/headers_api_fail; do
    step "$dir (must not build)"
    for t in "$dir"/*.mojo; do
        expected="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check.sh): //p' "$t")"
        if [[ -z "$expected" ]]; then
            echo "error: $t has no expected diagnostic" >&2
            exit 1
        fi
        if "${MOJO[@]}" build -I src -I tests "$t" -o "$tmp/must_fail" >"$tmp/log" 2>&1; then
            echo "error: $t compiled; it is expected to fail" >&2
            exit 1
        fi
        if ! grep -qF "$expected" "$tmp/log"; then
            cat "$tmp/log" >&2
            echo "error: $t failed without '$expected'" >&2
            exit 1
        fi
        echo "ok: $t"
    done
done

# Known gaps the decisions rest on (M3-001, M3-004, M3-002): each file must build
# and is never run. A file that stops building means the toolchain changed
# what the decision measured; docs/ARCHITECTURE.md lists the revisit
# condition.
step "tests/state_known_gaps, tests/state_storage_known_gaps, tests/headers_known_gaps (must build, not run)"
for t in tests/state_known_gaps/*.mojo tests/state_storage_known_gaps/*.mojo tests/headers_known_gaps/*.mojo; do
    if ! "${MOJO[@]}" build --Werror -I src -I tests "$t" -o "$tmp/known_gap" >"$tmp/log" 2>&1; then
        cat "$tmp/log" >&2
        echo "error: $t no longer builds; a revisit condition in docs/ARCHITECTURE.md has fired" >&2
        exit 1
    fi
    echo "ok: $t"
done

# Mojo 1.1.0 toolchain-wide soundness gaps (M3-004): primitives that break
# the State alias property for std types and existing Muntin storage too.
# Each must build and is never run. Warnings are allowed: the deprecated
# `memmove` warns. A file that stops building means the toolchain improved;
# docs/ARCHITECTURE.md "State storage decision (M3-004)" says what to
# reevaluate.
step "tests/toolchain_soundness_gaps (must build, not run)"
for t in tests/toolchain_soundness_gaps/*.mojo; do
    if ! "${MOJO[@]}" build -I src -I tests "$t" -o "$tmp/toolchain_gap" >"$tmp/log" 2>&1; then
        cat "$tmp/log" >&2
        echo "error: $t no longer builds; the toolchain improved, see docs/ARCHITECTURE.md" >&2
        exit 1
    fi
    echo "ok: $t"
done

step "build example"
"${MOJO[@]}" build --Werror -I src main.mojo -o build/muntin
echo "ok"
