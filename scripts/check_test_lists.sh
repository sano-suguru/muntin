#!/usr/bin/env bash
# Checks test modules that register their tests by hand (`def _tests() ->
# TestSuite:`; a module whose handlers declare a `Param` cannot discover them
# on Mojo 1.1.0, tests/named_values_api_fail/discover_tests_crash.mojo): every
# top-level `test_` function is listed as `suite.test[name]()` in the body of
# `_tests()`, outside comments and docstrings, and `main` calls `_tests()`
# outside a comment. Modules without `_tests()` are skipped. Exits nonzero
# naming the first gap.
set -euo pipefail

for f in "$@"; do
    grep -q '^def _tests() -> TestSuite:' "$f" || continue
    # The body of `_tests()` without docstrings or comments, with whitespace
    # removed, since the formatter may wrap a long entry.
    listed="$(awk '
        /^def _tests\(\) -> TestSuite:/ { inside = 1; next }
        inside && /^[^ \t]/ { inside = 0 }
        !inside { next }
        /"""/ { n = gsub(/"""/, "&"); if (n % 2 == 1) doc = !doc; next }
        doc { next }
        { sub(/#.*/, ""); print }
    ' "$f" | tr -d ' \t\n')"
    for t in $(sed -n 's/^def \(test_[A-Za-z0-9_]*\)(.*/\1/p' "$f"); do
        if [[ "$listed" != *"suite.test[$t]()"* ]]; then
            echo "error: $f: $t is not listed in _tests()" >&2
            exit 1
        fi
    done
    if ! awk '
        /^def main\(/ { inside = 1; next }
        inside && /^[^ \t]/ { inside = 0 }
        inside { sub(/#.*/, ""); if (index($0, "_tests()")) found = 1 }
        END { exit !found }
    ' "$f"; then
        echo "error: $f: main does not call _tests()" >&2
        exit 1
    fi
done
