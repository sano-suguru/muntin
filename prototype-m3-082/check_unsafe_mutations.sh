#!/usr/bin/env bash
# Plants one boundary violation at a time in a copy of src/muntin and
# requires scripts/check_unsafe.sh to fail on each (and pass unmutated).
# Run from the prototype's root.
set -uo pipefail
root=$(pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R scripts src "$work/"
cd "$work"
run() { ./scripts/check_unsafe.sh >/dev/null 2>&1; }
if ! run; then echo "FAIL: unmutated tree does not pass"; exit 1; fi
echo "ok: unmutated tree passes"
mutate() {
    local name=$1 file=$2 script=$3
    cp "$file" "$file.bak"
    python3 -I -c "$script" "$file"
    if run; then echo "FAIL: not caught: $name"; failed=1; else echo "ok: caught: $name"; fi
    mv "$file.bak" "$file"
}
failed=0
J=src/muntin/json.mojo
mutate "a reference rebind outside _rebind.mojo" $J 'import sys;p=sys.argv[1];s=open(p).read();s=s.replace("_view[Int](f)","rebind[Int](f)",1);open(p,"w").write(s)'
mutate "a value rebind outside _rebind.mojo" $J 'import sys;p=sys.argv[1];s=open(p).read();s+="\n\ndef _x[T: Movable](var v: T) -> Int:\n    return rebind_var[Int](v^)\n";open(p,"w").write(s)'
mutate "a third refinement of _FieldBuilt" $J 'import sys;p=sys.argv[1];s=open(p).read();s+="\n\ntrait _Other(_FieldBuilt):\n    pass\n";open(p,"w").write(s)'
mutate "downcast in json.mojo" $J 'import sys;p=sys.argv[1];s=open(p).read();s+="\n\ncomptime _D = downcast[Int, Movable]\n";open(p,"w").write(s)'
mutate "_build_record called from state.mojo" src/muntin/state.mojo 'import sys;p=sys.argv[1];s=open(p).read();s+="\n\nfrom ._handler_storage import _build_record\n";open(p,"w").write(s)'
mutate "the rebind without its assert" src/muntin/_rebind.mojo 'import sys;p=sys.argv[1];s=open(p).read();s=s.replace("    comptime assert A == T, \"rebind requires generic type equality\"\n    return rebind[A](value)","    return rebind[A](value)");open(p,"w").write(s)'
mutate "storage importing RouteValues" src/muntin/_handler_storage.mojo 'import sys;p=sys.argv[1];s=open(p).read();s=s.replace("from ._field_built import _FieldBuilt\n","from ._field_built import _FieldBuilt\nfrom .route_value import RouteValues\n");open(p,"w").write(s)'
mutate "_view imported by app.mojo" src/muntin/app.mojo 'import sys;p=sys.argv[1];s=open(p).read();s=s.replace("from ._rebind import _as\n","from ._rebind import _as, _view\n");open(p,"w").write(s)'
mutate "an unsafe operation in json.mojo" $J 'import sys;p=sys.argv[1];s=open(p).read();s+="\n\ncomptime _M = MaybeUninit[Int]().unsafe_ptr\n";open(p,"w").write(s)'
exit $failed
