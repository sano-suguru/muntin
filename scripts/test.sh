#!/usr/bin/env bash
# Builds every executable Muntin test file (tests/test_*.mojo), or only the
# files given as arguments, with --Werror in parallel, then runs each binary
# in order. Exits nonzero if any test fails, any file fails to build, or no
# test files are found.
#
# SANITIZE=address builds them with Mojo's AddressSanitizer: a heap
# use-after-free or double free, and on Linux a leak at exit (forced on even
# if ASAN_OPTIONS turns it off), makes the binary exit nonzero, so the test
# fails even if every assertion passed; reports go to stderr (log_path), and
# LSAN_OPTIONS is unset, so no suppression from the environment applies. Before building any test it builds and runs the
# positive controls in tests/sanitizer_controls, each of which must fail
# with a sanitizer report of the kind its "# Expected report: " line names,
# so a toolchain whose sanitizer stops seeing these errors stops the run
# there. The leak control runs on Linux only, the one platform where leak
# detection is verified for this toolchain. This is the runtime
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

# The positive controls, named so that a deleted one fails the run. Leak
# detection is verified only on Linux for this Mojo toolchain, so the leak
# control (and the forced detect_leaks=1) is skipped elsewhere.
controls=()
if [[ "${SANITIZE:-}" == address ]]; then
    controls=(tests/sanitizer_controls/use_after_free.mojo tests/sanitizer_controls/double_free.mojo)
    # Reports go to stderr, where the checks below read them, whatever
    # log_path the environment sets.
    export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}log_path=stderr"
    if [[ "$(uname -s)" == Linux ]]; then
        controls+=(tests/sanitizer_controls/leak.mojo)
        # Leak detection on, and no LeakSanitizer suppressions from the
        # environment (LSAN_OPTIONS).
        export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=1"
        unset LSAN_OPTIONS
    else
        echo "note: tests/sanitizer_controls/leak.mojo skipped: leak detection is not verified on $(uname -s)"
    fi
    for c in "${controls[@]}"; do
        if [[ ! -f "$c" ]]; then
            echo "error: $c not found" >&2
            exit 1
        fi
    done
fi

pixi run --frozen mojo --version
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jobs="$(getconf _NPROCESSORS_ONLN)"

failed=0
# The controls are built and run before any test is built: if the sanitizer
# misses one, the run stops here.
if (( ${#controls[@]} > 0 )); then
    printf 'test\0%s\0' "${controls[@]}" | xargs -0 -n 2 -P "$jobs" ./scripts/build_one.sh "$tmp" || true
    for c in "${controls[@]}"; do
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
        # A sanitizer report starts "==PID==ERROR: <sanitizer>: <kind>".
        if out="$("$tmp/$name.bin" 2>&1)"; then
            printf '%s\n' "$out"
            echo "error: $c exited 0; the sanitizer did not report it" >&2
            failed=1
        elif ! grep -qE "^==[0-9]+==ERROR: $expected" <<<"$out"; then
            printf '%s\n' "$out"
            echo "error: $c failed without a '==PID==ERROR: $expected' report" >&2
            failed=1
        else
            echo "ok: $c -> $expected"
        fi
    done
    if (( failed )); then
        echo "error: a sanitizer positive control failed; no test was built" >&2
        exit 1
    fi
fi

# A failed build is reported below, next to its file.
printf 'test\0%s\0' "${files[@]}" | xargs -0 -n 2 -P "$jobs" ./scripts/build_one.sh "$tmp" || true

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
