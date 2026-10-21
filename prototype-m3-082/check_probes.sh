#!/usr/bin/env bash
# Builds each probe in prototype-m3-082/probes and compares the outcome with
# its "# Expect:" line ("build fails", or "exit N" after building and
# running) and, when present, its "# Expect-output:" line: a Python regular
# expression (re.S) searched in the build log for "build fails", else in the
# program's output. Exits 1 if any probe differs. Run from the prototype's
# root; needs pixi with the locked default environment (Mojo 1.1.0).
set -uo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
total=0
for probe in prototype-m3-082/probes/*.mojo; do
    total=$((total + 1))
    name=$(basename "$probe" .mojo)
    expect=$(sed -n 's/^# Expect: //p' "$probe")
    pattern=$(sed -n 's/^# Expect-output: //p' "$probe")
    if [[ "$expect" != "build fails" && ! "$expect" =~ ^exit\ [0-9]+$ ]]; then
        echo "FAIL: $name has no valid '# Expect:' line"
        failed=1
        continue
    fi
    if pixi run --frozen mojo build -I src "$probe" -o "$work/$name" >"$work/$name.log" 2>&1; then
        "$work/$name" >"$work/$name.out" 2>&1
        got="exit $?"
        evidence="$work/$name.out"
    else
        got="build fails"
        evidence="$work/$name.log"
    fi
    if [[ "$got" != "$expect" ]]; then
        tail -n 5 "$evidence"
        echo "FAIL: $name: expected '$expect', got '$got'"
        failed=1
    elif [[ -n "$pattern" ]] &&
        ! python3 -I -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], open(sys.argv[2]).read(), re.S) else 1)' \
            "$pattern" "$evidence"; then
        tail -n 5 "$evidence"
        echo "FAIL: $name: '$got' as expected, but the output does not match /$pattern/"
        failed=1
    else
        echo "ok: $name: $got${pattern:+, output matches}"
    fi
done
if ((failed)); then
    echo "FAIL: not every probe behaves as its Expect lines say"
    exit 1
fi
echo "ok: $total of $total probes behave as expected"
