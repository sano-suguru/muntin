#!/usr/bin/env bash
# Plants one boundary violation at a time in a copy of scripts/ and
# src/muntin and requires scripts/check_unsafe.sh to fail on each, with the
# error of the rule that owns it; the unmutated copy must pass. Exits 1 if
# any is not caught. Run from the prototype's root.
set -uo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R scripts src "$work/"
cd "$work"
if ! ./scripts/check_unsafe.sh >out 2>&1; then
    cat out
    echo "FAIL: the unmutated tree does not pass"
    exit 1
fi
echo "ok: the unmutated tree passes"
failed=0
total=0
# mutate NAME FILE EXPECTED-ERROR PYTHON: PYTHON edits FILE (argv[1]); the
# check must then exit non-zero and print EXPECTED-ERROR.
mutate() {
    local name=$1 file=$2 expected=$3 script=$4
    total=$((total + 1))
    cp "$file" "$file.bak"
    if ! python3 -I -c "$script" "$file" || cmp -s "$file" "$file.bak"; then
        echo "FAIL: the mutation did not apply: $name"
        failed=1
    elif ./scripts/check_unsafe.sh >out 2>&1; then
        echo "FAIL: not caught: $name"
        failed=1
    elif ! grep -qF -- "$expected" out; then
        cat out
        echo "FAIL: caught, but not by the rule expected ($expected): $name"
        failed=1
    else
        echo "ok: caught: $name"
    fi
    mv "$file.bak" "$file"
}
append() { printf 'import sys;p=sys.argv[1];open(p,"a").write(%s)' "$1"; }
replace() { printf 'import sys;p=sys.argv[1];s=open(p).read();open(p,"w").write(s.replace(%s,%s,1))' "$1" "$2"; }
J=src/muntin/json.mojo
R=src/muntin/_rebind.mojo
S=src/muntin/_handler_storage.mojo
F=src/muntin/_field_built.mojo
V=src/muntin/route_value.mojo
REFINE='"\n\ntrait _Other(_FieldBuilt):\n    pass\n"'
mutate "a reference rebind outside _rebind.mojo" $J "exactly one 'rebind['" \
    "$(replace '"_view[Int](f)"' '"rebind[Int](f)"')"
mutate "a value rebind outside _rebind.mojo" $J "exactly one 'rebind_var['" \
    "$(append '"\n\ndef _x[T: Movable](var v: T) -> Int:\n    return rebind_var[Int](v^)\n"')"
mutate "the reference rebind without its assert" $R "on the line after 'comptime assert A == T'" \
    "$(replace '"    comptime assert A == T, \"rebind requires generic type equality\"\n    return rebind[A](value)"' '"    return rebind[A](value)"')"
mutate "the value rebind without its assert" $R "on the line after 'comptime assert A == T'" \
    "$(replace '"    comptime assert A == T, \"rebind requires generic type equality\"\n    return rebind_var[A](value^)"' '"    return rebind_var[A](value^)"')"
mutate "_view imported by app.mojo" src/muntin/app.mojo "may import $R" \
    "$(replace '"from ._rebind import _as\n"' '"from ._rebind import _as, _view\n"')"
mutate "downcast in json.mojo" $J "downcast is unchecked" \
    "$(append '"\n\ncomptime _D = downcast[Int, Movable]\n"')"
mutate "_build_record imported by state.mojo" src/muntin/state.mojo "only app.mojo and json.mojo may use _build_record" \
    "$(append '"\n\nfrom ._handler_storage import _build_record\n"')"
mutate "the storage module importing RouteValues" $S "may import only std, .http and _FieldBuilt" \
    "$(replace '"from ._field_built import _FieldBuilt\n"' '"from ._field_built import _FieldBuilt\nfrom .route_value import RouteValues\n"')"
mutate "an unsafe operation in json.mojo" $J "unsafe handler-storage operations outside" \
    "$(append '"\n\ncomptime _M = MaybeUninit[Int]().unsafe_ptr\n"')"
mutate "a third refinement of _FieldBuilt in json.mojo" $J "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append "$REFINE")"
mutate "a third refinement in _field_built.mojo" $F "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append "$REFINE")"
mutate "a third refinement in the storage module" $S "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append "$REFINE")"
mutate "a refinement through an alias" $J "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append '"\n\ncomptime _Alias = _FieldBuilt\n\n\ntrait _Other(_Alias):\n    pass\n"')"
mutate "a refinement split over lines" $V "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append '"\n\ntrait _Other(\n    _FieldBuilt\n):\n    pass\n"')"
mutate "_FieldBuilt imported by state.mojo" src/muntin/state.mojo "only RouteValues and JsonFields may refine _FieldBuilt" \
    "$(append '"\n\nfrom ._field_built import _FieldBuilt\n"')"
mutate "an import in _field_built.mojo" $F "imports nothing" \
    "$(append '"\n\nfrom .route_value import RouteValues\n"')"
if ((failed)); then
    echo "FAIL: not every planted violation was caught"
    exit 1
fi
echo "ok: $total of $total planted violations caught"
