#!/usr/bin/env bash
# Checks test modules that register their tests by hand (`def _tests() ->
# TestSuite:`; a module whose handlers declare a `Param` cannot discover them
# on Mojo 1.1.0, tests/named_values_api_fail/discover_tests_crash.mojo). Such
# a module follows a fixed format, so the check matches whole lines and never
# parses Mojo: inside `_tests()`, every top-level `test_` function has its own
# line `    suite.test[test_name]()`, and `main` has the line
# `    _tests().run()`. A comment, a string literal or a docstring never
# matches such a line (lines inside `"""` blocks are skipped). Modules
# without `_tests()` are skipped. Exits nonzero naming the first gap.
set -euo pipefail

# The lines of function $2's body in file $1 outside docstrings.
body() {
    awk -v head="^def $2\\\\(" '
        $0 ~ head { inside = 1; next }
        inside && /^[^ \t]/ { inside = 0 }
        !inside { next }
        /"""/ { n = gsub(/"""/, "&"); if (n % 2 == 1) doc = !doc; next }
        !doc { print }
    ' "$1"
}

for f in "$@"; do
    grep -q '^def _tests() -> TestSuite:' "$f" || continue
    listed="$(body "$f" _tests)"
    for t in $(sed -n 's/^def \(test_[A-Za-z0-9_]*\)(.*/\1/p' "$f"); do
        if ! grep -qxF "    suite.test[$t]()" <<<"$listed"; then
            echo "error: $f: $t is not listed in _tests() as its own line: suite.test[$t]()" >&2
            exit 1
        fi
    done
    if ! body "$f" main | grep -qxF "    _tests().run()"; then
        echo "error: $f: main does not run _tests() as its own line: _tests().run()" >&2
        exit 1
    fi
done
