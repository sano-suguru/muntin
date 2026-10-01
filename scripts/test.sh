#!/usr/bin/env bash
# Runs every executable Muntin test file (tests/test_*.mojo). Exits nonzero if
# any test fails, any file fails to build, or no test files are found.
set -euo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
files=(tests/test_*.mojo)
if (( ${#files[@]} == 0 )); then
    echo "error: no tests/test_*.mojo files found" >&2
    exit 1
fi

pixi run --frozen mojo --version
failed=0
for f in "${files[@]}"; do
    printf '\n== %s\n' "$f"
    if ! out="$(pixi run --frozen mojo run -I src -I tests "$f" 2>&1)"; then
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
