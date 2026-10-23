#!/usr/bin/env bash
# Tests scripts/check_unsafe.sh (M2-004, M3-015, M3-061, M3-082): each case
# copies the script and src/muntin, plants one violation in the copy and
# expects the check to fail with the error of the rule that owns it, so a
# change that lets the check miss a violation fails here. Run by
# scripts/check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
count=0

# fresh: a clean copy of the check and the package.
fresh() {
    rm -rf "$work/scripts" "$work/src"
    mkdir -p "$work/scripts" "$work/src"
    cp scripts/check_unsafe.sh "$work/scripts/"
    cp -R src/muntin "$work/src/muntin"
}

# expect pass|fail NAME [ERROR]: runs the check on the copy; a failure must
# print ERROR.
expect() {
    local want=$1 name=$2 error=${3:-} got
    count=$((count + 1))
    if "$work/scripts/check_unsafe.sh" >"$work/out" 2>&1; then got=pass; else got=fail; fi
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $name: expected $want, got $got" >&2
        sed 's/^/    /' "$work/out" >&2
        failures=$((failures + 1))
    elif [[ "$want" == fail ]] && ! grep -qF -- "$error" "$work/out"; then
        echo "FAIL: $name: failed, but without '$error'" >&2
        sed 's/^/    /' "$work/out" >&2
        failures=$((failures + 1))
    else
        echo "ok: $name ($want)"
    fi
}

# append FILE TEXT, replace FILE OLD NEW: edit the copy's FILE (a path
# under src/muntin); a replacement must apply exactly once.
append() { printf '%b' "$2" >>"$work/src/muntin/$1"; }
replace() {
    python3 -I -c 'import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if s.count(old) != 1:
    sys.exit("the edit does not apply once: " + old)
open(p, "w").write(s.replace(old, new))' "$work/src/muntin/$1" "$2" "$3"
}

refine='\n\ntrait _Other(_FieldBuilt):\n    pass\n'
assert=$'    comptime assert A == T, "rebind requires generic type equality"\n'
only_rb="on the line after 'comptime assert A == T'"
only_fb="only RouteValues and JsonFields may refine _FieldBuilt"

fresh
expect pass "the package as it is"

fresh
replace json.mojo '_view[Int](f)' 'rebind[Int](f)'
expect fail "a reference rebind outside _rebind.mojo" "exactly one 'rebind['"

fresh
append json.mojo '\n\n# fmt: off\ndef _x(f: Int) -> Int:\n    return rebind [Int](f)\n# fmt: on\n'
expect fail "a reference rebind with a space before [" "exactly one 'rebind['"

fresh
append json.mojo '\n\ndef _x[T: Movable](var v: T) -> Int:\n    return rebind_var[Int](v^)\n'
expect fail "a value rebind outside _rebind.mojo" "exactly one 'rebind_var['"

fresh
append json.mojo '\n\n# fmt: off\ndef _x[T: Movable](var v: T) -> Int:\n    return rebind_var [Int](v^)\n# fmt: on\n'
expect fail "a value rebind with a space before [" "exactly one 'rebind_var['"

fresh
replace _rebind.mojo "$assert    return rebind[A](value)" '    return rebind[A](value)'
expect fail "the reference rebind without its assert" "$only_rb"

fresh
replace _rebind.mojo "$assert    return rebind_var[A](value^)" '    return rebind_var[A](value^)'
expect fail "the value rebind without its assert" "$only_rb"

fresh
replace app.mojo 'from ._rebind import _as
' 'from ._rebind import _as, _view
'
expect fail "_view imported by app.mojo" "may import src/muntin/_rebind.mojo"

fresh
append json.mojo '\n\ncomptime _D = downcast[Int, Movable]\n'
expect fail "downcast in json.mojo" "downcast is unchecked"

fresh
append json.mojo '\n\n# fmt: off\ncomptime _D = downcast [Int, Movable]\n# fmt: on\n'
expect fail "downcast with a space before [" "downcast is unchecked"

fresh
append state.mojo '\n\nfrom ._handler_storage import _build_record\n'
expect fail "_build_record imported by state.mojo" "only app.mojo and json.mojo may use _build_record"

fresh
replace _handler_storage.mojo 'from ._field_built import _FieldBuilt
' 'from ._field_built import _FieldBuilt
from .route_value import RouteValues
'
expect fail "the storage module importing RouteValues" "may import only std, .http and _FieldBuilt"

fresh
append json.mojo '\n\ncomptime _M = MaybeUninit[Int]().unsafe_ptr\n'
expect fail "an unsafe operation in json.mojo" "unsafe handler-storage operations outside"

fresh
append json.mojo "$refine"
expect fail "a third refinement of _FieldBuilt in json.mojo" "$only_fb"

fresh
append _field_built.mojo "$refine"
expect fail "a third refinement in _field_built.mojo" "$only_fb"

fresh
append _handler_storage.mojo "$refine"
expect fail "a third refinement in the storage module" "$only_fb"

fresh
append json.mojo '\n\ncomptime _Alias = _FieldBuilt\n\n\ntrait _Other(_Alias):\n    pass\n'
expect fail "a refinement through an alias" "$only_fb"

fresh
append route_value.mojo '\n\ntrait _Other(\n    _FieldBuilt\n):\n    pass\n'
expect fail "a refinement split over lines" "$only_fb"

fresh
append state.mojo '\n\nfrom ._field_built import _FieldBuilt\n'
expect fail "_FieldBuilt imported by state.mojo" "$only_fb"

fresh
append _field_built.mojo '\n\nfrom .route_value import RouteValues\n'
expect fail "an import in _field_built.mojo" "imports nothing"

if ((failures > 0)); then
    echo "error: $failures of $count cases of check_unsafe.sh failed" >&2
    exit 1
fi
echo "ok: $count cases of check_unsafe.sh"
