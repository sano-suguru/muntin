#!/usr/bin/env bash
# Builds the known gaps that erase a value which borrows a dropped local with
# Mojo's AddressSanitizer, runs each, and requires the sanitizer report its
# "# Expected report: " line names. scripts/check.sh only builds these files,
# which shows that the compiler accepts them; this script shows that running
# them still reads or writes freed memory. It is a measurement, not a CI
# check: run it when the Mojo version changes, and reopen the linked decision
# if a file stops reporting (docs/DEVELOPMENT.md, section 3).
set -euo pipefail
cd "$(dirname "$0")/.."

# Named, so that a deleted file fails the run.
gaps=(
    tests/context_known_gaps/erasure_drops_origin.mojo
    tests/state_known_gaps/state_borrows_dropped_local.mojo
)
export SANITIZE=address
export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}log_path=stderr"

pixi run --frozen mojo --version
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failed=0
for g in "${gaps[@]}"; do
    printf '\n== %s\n' "$g"
    expected="$(sed -n 's/^# Expected report: //p' "$g" 2>/dev/null || true)"
    if [[ -z "$expected" ]]; then
        echo "error: $g is missing or has no expected report" >&2
        failed=1
        continue
    fi
    name="${g//\//_}"
    if ! ./scripts/build_one.sh "$tmp" test "$g"; then
        cat "$tmp/$name.log"
        failed=1
        continue
    fi
    # A sanitizer report starts "==PID==ERROR: <sanitizer>: <kind>".
    if out="$("$tmp/$name.bin" 2>&1)"; then
        printf '%s\n' "$out"
        echo "error: $g exited 0; it no longer touches freed memory" >&2
        failed=1
    elif ! grep -qE "^==[0-9]+==ERROR: $expected" <<<"$out"; then
        printf '%s\n' "$out"
        echo "error: $g failed without a '==PID==ERROR: $expected' report" >&2
        failed=1
    else
        echo "ok: $g -> $expected"
    fi
done
exit "$failed"
