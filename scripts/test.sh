#!/usr/bin/env bash
# Builds every executable Muntin test file (tests/test_*.mojo), or only the
# files given as arguments, with --Werror in parallel, then runs each binary
# in order. Exits nonzero if any test fails, any file fails to build, or no
# test files are found.
#
# SANITIZE=address builds them with Mojo's AddressSanitizer: a heap
# use-after-free or double free, and on Linux a leak at exit (forced on even
# if ASAN_OPTIONS turns it off), makes the binary exit nonzero, so the test
# fails even if every assertion passed. It first builds and runs the
# positive controls in tests/sanitizer_controls, each of which must fail
# with the report its "# Expected report: " line names, so a toolchain
# whose sanitizer stops seeing these errors fails the run instead of
# passing it. The leak control runs on Linux only. This is the runtime
# evidence for the unsafe storage in src/muntin/_handler_storage.mojo
# (docs/DEVELOPMENT.md, section 3).
set -euo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
if (( $# > 0 )); then
    files=("$@")
else
    files=(tests/test_*.mojo)
fi
if (( ${#files[@]} == 0 )); then
    echo "error: no tests/test_*.mojo files found" >&2
    exit 1
fi
for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "error: $f not found" >&2
        exit 1
    fi
done

controls=()
if [[ "${SANITIZE:-}" == address ]]; then
    for c in tests/sanitizer_controls/*.mojo; do
        if [[ "$(uname -s)" != Linux ]] && grep -q '^# Expected report: LeakSanitizer' "$c"; then
            echo "note: $c skipped: no leak detection on $(uname -s)"
            continue
        fi
        controls+=("$c")
    done
    if (( ${#controls[@]} == 0 )); then
        echo "error: no tests/sanitizer_controls/*.mojo files found" >&2
        exit 1
    fi
    if [[ "$(uname -s)" == Linux ]]; then
        export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=1"
    fi
fi

pixi run --frozen mojo --version
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jobs="$(getconf _NPROCESSORS_ONLN)"
# A failed build is reported below, next to its file.
printf 'test\0%s\0' ${controls[@]+"${controls[@]}"} "${files[@]}" | xargs -0 -n 2 -P "$jobs" ./scripts/build_one.sh "$tmp" || true

failed=0
for c in ${controls[@]+"${controls[@]}"}; do
    printf '\n== %s (must fail)\n' "$c"
    name="${c//\//_}"
    expected="$(sed -n 's/^# Expected report: //p' "$c")"
    if [[ -z "$expected" ]]; then
        echo "error: $c has no expected report" >&2
        failed=1
        continue
    fi
    if [[ ! -x "$tmp/$name.bin" ]]; then
        cat "$tmp/$name.log" 2>/dev/null || echo "error: $c was not built"
        failed=1
        continue
    fi
    if out="$("$tmp/$name.bin" 2>&1)"; then
        printf '%s\n' "$out"
        echo "error: $c exited 0; the sanitizer did not report it" >&2
        failed=1
    elif ! grep -qF "$expected" <<<"$out"; then
        printf '%s\n' "$out"
        echo "error: $c failed without '$expected'" >&2
        failed=1
    else
        echo "ok: $c -> $expected"
    fi
done
for f in "${files[@]}"; do
    printf '\n== %s\n' "$f"
    name="${f//\//_}"
    if [[ ! -x "$tmp/$name.bin" ]]; then
        cat "$tmp/$name.log" 2>/dev/null || echo "error: $f was not built"
        failed=1
        continue
    fi
    if ! out="$("$tmp/$name.bin" 2>&1)"; then
        failed=1
    fi
    printf '%s\n' "$out"
    # Guard against files that build but never run the suite.
    if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
        echo "error: $f ran no tests (main must run TestSuite)" >&2
        failed=1
    fi
done
exit "$failed"
