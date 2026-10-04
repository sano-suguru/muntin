#!/usr/bin/env bash
# Builds every executable Muntin test file (tests/test_*.mojo), or only the
# files given as arguments, with --Werror in parallel, then runs each binary
# in order. Exits nonzero if any test fails, any file fails to build, or no
# test files are found.
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

pixi run --frozen mojo --version
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jobs="$(getconf _NPROCESSORS_ONLN)"
# A failed build is reported below, next to its file.
printf 'test\0%s\0' "${files[@]}" | xargs -0 -n 2 -P "$jobs" ./scripts/build_one.sh "$tmp" || true

failed=0
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
