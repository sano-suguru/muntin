#!/usr/bin/env bash
# Reproduces the M3-082 prototype's evidence from the repository root of
# this commit. Needs pixi with the locked default environment (Mojo 1.1.0)
# on Linux (leak detection under SANITIZE=address). Runs every step, then
# exits 1 if any step failed, naming each failed step.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.pixi/bin:$PATH"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
failed=()
# step NAME COMMAND...: runs COMMAND, prints the tail of its output and
# records NAME as failed when COMMAND exits non-zero.
step() {
    local name=$1 code
    shift
    printf '\n== %s\n' "$name"
    "$@" >"$log" 2>&1
    code=$?
    # Totals from the whole log: check.sh prints "ok: tests/..." per fixture,
    # test.sh one "Summary" line per test file.
    grep -E '^ok: tests/|^ *Summary ' "$log" | awk '
        /^ok: tests\// { fixtures++ }
        /Summary \[/ { files++; for (i = 1; i <= NF; i++) {
            if ($(i + 1) == "passed") passed += $i
            if ($(i + 1) == "failed") bad += $i } }
        END { if (fixtures) print "totals: " fixtures " fixtures ok"
              if (files) print "totals: " files " test files, " passed " passed, " bad + 0 " failed" }'
    if ((code == 0)); then
        tail -n 4 "$log"
        echo "PASS: $name"
    else
        tail -n 25 "$log"
        echo "FAIL (exit $code): $name"
        failed+=("$name")
    fi
}
step "check.sh, unchanged (with the new check_unsafe.sh and the derived_* fixtures)" ./scripts/check.sh
step "test.sh (with tests/test_spike_derived_json.mojo)" ./scripts/test.sh
step "SANITIZE=address test.sh" env SANITIZE=address ./scripts/test.sh
step "check_unsafe.sh catches each planted boundary violation" ./prototype-m3-082/check_unsafe_mutations.sh
step "each probe behaves as its Expect lines say" ./prototype-m3-082/check_probes.sh
echo
if ((${#failed[@]})); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "ok: all 5 steps passed"
