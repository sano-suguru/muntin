#!/usr/bin/env bash
# Reproduces the M3-082 prototype's evidence from the repository root of
# this commit. Needs pixi with the locked default environment (Mojo 1.1.0).
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.pixi/bin:$PATH"
step() { printf '\n== %s\n' "$*"; }
step "check.sh, unchanged (includes the new check_unsafe.sh and the derived_* fixtures)"
./scripts/check.sh 2>&1 | tail -n 3
step "test.sh (includes tests/test_spike_derived_json.mojo)"
./scripts/test.sh 2>&1 | grep -E '^== |Summary|error' | tail -n 6
step "SANITIZE=address test.sh (leak detection on Linux)"
SANITIZE=address ./scripts/test.sh 2>&1 | grep -E 'sanitizer_controls|Summary|ERROR|error' | tail -n 6
step "check_unsafe.sh catches each planted boundary violation"
./prototype-m3-082/check_unsafe_mutations.sh
step "probes (expected outcome in each file's first comment)"
for p in prototype-m3-082/probes/*.mojo; do
    printf -- '-- %s: ' "$p"
    if pixi run --frozen mojo build -I src "$p" -o /tmp/m3082_probe >/tmp/m3082_probe.log 2>&1; then
        echo "builds"; /tmp/m3082_probe 2>&1 | head -n 3
    else
        echo "does not build: $(grep -m1 -E 'constraint failed|error:' /tmp/m3082_probe.log | grep -v 'function instantiation' | cut -c1-160)"
    fi
done
