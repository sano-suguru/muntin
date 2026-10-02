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
# rejects a mismatched adapter and copies, and App.get still accepts only the
# supported handler shapes. tests/extraction_fail: evidence for
# docs/ARCHITECTURE.md "Argument extraction decision" (M2-005).
# tests/body_fail: App.post accepts only the body-only shape and App.get takes
# no body handler (M2-006). tests/response_fail: evidence for
# docs/ARCHITECTURE.md "Typed response decision (M2-007)".
for dir in tests/spike_fail tests/storage_fail tests/extraction_fail tests/body_fail tests/response_fail; do
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

step "build example"
"${MOJO[@]}" build --Werror -I src main.mojo -o build/muntin
echo "ok"
