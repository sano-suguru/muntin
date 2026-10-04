#!/usr/bin/env bash
# Builds one Mojo file the way check.sh or test.sh expects, so the callers
# can run many at once (xargs -P). Usage: build_one.sh OUTDIR KIND FILE.
# Writes everything it reports to OUTDIR/<FILE with / as _>.log, for the
# caller to print in order, and exits nonzero on failure.
#
#   test        tests/test_*.mojo: must build with --Werror; the binary is
#               left at OUTDIR/<name>.bin for test.sh to run.
#   route       tests/compile_fail: must not build; the log must contain
#               "constraint failed: <expected diagnostic>".
#   must_fail   other must-not-build fixtures: must not build; the log must
#               contain the expected diagnostic.
#   known_gap   must build with --Werror (never run).
#   toolchain_gap  must build, warnings allowed (never run).
set -euo pipefail
cd "$(dirname "$0")/.."

outdir="$1"
kind="$2"
t="$3"
name="${t//\//_}"
log="$outdir/$name.log"
bin="$outdir/$name.bin"
build_log="$outdir/$name.build"
MOJO=(pixi run --frozen mojo)

exec >"$log" 2>&1

expected_diagnostic() {
    expected="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check.sh): //p' "$t")"
    if [[ -z "$expected" ]]; then
        echo "error: $t has no expected diagnostic"
        exit 1
    fi
}

case "$kind" in
test)
    if ! "${MOJO[@]}" build --Werror -I src -I tests "$t" -o "$bin"; then
        echo "error: $t failed to build"
        exit 1
    fi
    ;;
route)
    expected_diagnostic
    if "${MOJO[@]}" build -I src "$t" -o "$bin" >"$build_log" 2>&1; then
        echo "error: $t compiled; Muntin no longer rejects it"
        exit 1
    fi
    if ! grep -qF "constraint failed: $expected" "$build_log"; then
        cat "$build_log"
        echo "error: $t failed without 'constraint failed: $expected'"
        exit 1
    fi
    echo "ok: $t -> $expected"
    ;;
must_fail)
    expected_diagnostic
    if "${MOJO[@]}" build -I src -I tests "$t" -o "$bin" >"$build_log" 2>&1; then
        echo "error: $t compiled; it is expected to fail"
        exit 1
    fi
    if ! grep -qF "$expected" "$build_log"; then
        cat "$build_log"
        echo "error: $t failed without '$expected'"
        exit 1
    fi
    echo "ok: $t"
    ;;
known_gap)
    if ! "${MOJO[@]}" build --Werror -I src -I tests "$t" -o "$bin" >"$build_log" 2>&1; then
        cat "$build_log"
        echo "error: $t no longer builds; a revisit condition in docs/ARCHITECTURE.md has fired"
        exit 1
    fi
    echo "ok: $t"
    ;;
toolchain_gap)
    if ! "${MOJO[@]}" build -I src -I tests "$t" -o "$bin" >"$build_log" 2>&1; then
        cat "$build_log"
        echo "error: $t no longer builds; the toolchain improved, see docs/ARCHITECTURE.md"
        exit 1
    fi
    echo "ok: $t"
    ;;
*)
    echo "error: unknown kind '$kind'"
    exit 2
    ;;
esac
