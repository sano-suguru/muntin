#!/usr/bin/env bash
# Confines Muntin's unsafe handler storage to one private module (M2-004).
# Fails if, anywhere in src/muntin except src/muntin/_handler_storage.mojo,
# a line names an unsafe pointer/ownership operation or touches the box's
# fields; if a module imports anything but `_Erased`, `_Shared` or
# `_build_record` from it;
# if the package root exports it; if the module imports anything but the
# standard library, `.http` and the `_FieldBuilt` trait, or a line naming
# `_FieldBuilt` is not on a fixed list (so only `RouteValues` and
# `JsonFields` refine it and `_build_record` can build no other type, M3-062,
# M3-082); or if it names request or body
# data (M2-006) or result/error conversion (M2-013); or if a rebind appears
# anywhere but the two guarded helpers in `_rebind.mojo`, or `downcast`
# anywhere (M3-015, M3-082, below). A confinement guard, not a safety proof:
# the invariant itself is in the module docstring and docs/history/architecture-decisions.md
# "Handler storage decision (M2)". tests/ is not checked (spikes and storage
# tests use these operations on purpose).
set -euo pipefail
cd "$(dirname "$0")/.."

dir=src/muntin
storage=$dir/_handler_storage.mojo
status=0

if [[ ! -f "$storage" ]]; then
    echo "error: $storage is missing" >&2
    exit 1
fi

# Operations the typed box uses (`unsafe_*`, `MutUntrackedOrigin`,
# `MutOpaquePointer`, `OwnedPointer`, `ThinAllocation`, `unsafe_bitcast`),
# any other `Unsafe*` API, and the `_Erased`/`_Header` fields whose pairing
# the module guarantees.
pattern='[Uu]nsafe|Untracked|OpaquePointer|OwnedPointer|Allocation|bitcast|\._(header|invoke|drop|value)\b'
if grep -rnE --include='*.mojo' "$pattern" "$dir" | grep -v "^$storage:"; then
    echo "error: unsafe handler-storage operations outside $storage" >&2
    status=1
fi

# Other modules may import `_Erased`, `_Shared` (M3-004) or `_build_record`
# (M3-061) and nothing else from the storage module, so its helpers
# (`_erase`, `_invoke_box`, `_drop_box`, `_Box`, `_SharedHeader`) stay
# inside it.
if grep -rnE --include='*.mojo' '_handler_storage' "$dir" | grep -v "^$storage:" |
    grep -vE '^[^:]+:[0-9]+:([[:space:]]*#|from \._handler_storage import (_Erased|_Shared|_build_record)$)'; then
    echo "error: only 'from ._handler_storage import _Erased', '... import _Shared' or '... import _build_record' may name the storage module" >&2
    status=1
fi
# `_build_record` builds a value without its initializers: only the record
# slot (app.mojo) and the derived JSON reader (json.mojo) call it (M3-082).
if grep -rnE --include='*.mojo' '_build_record' "$dir" | grep -v "^$storage:" |
    grep -vE "^($dir/app\.mojo|$dir/json\.mojo):"; then
    echo "error: only app.mojo and json.mojo may use _build_record" >&2
    status=1
fi

if grep -nE '_handler_storage|_Erased' "$dir/__init__.mojo"; then
    echo "error: $dir/__init__.mojo exposes the private handler storage" >&2
    status=1
fi

if grep -nE '^[[:space:]]*(from|import)[[:space:]]' "$storage" |
    grep -vE '^[0-9]+:[[:space:]]*from[[:space:]]+(std\.[[:alnum:]_.]+|\.http)[[:space:]]+import[[:space:]]' |
    grep -vE '^[0-9]+:from \._field_built import _FieldBuilt$'; then
    echo "error: $storage may import only std, .http and _FieldBuilt from ._field_built" >&2
    status=1
fi

# `_FieldBuilt` is the consent that `_build_record` may skip `__init__`, so
# it is refined only by `RouteValues` (route_value.mojo) and `JsonFields`
# (json.mojo) (M3-082). Every line in src/muntin that names it, in its own
# module and the storage module too, must be one of the lines below, each
# exactly once: a third refinement, an alias or a refinement split over
# lines, anywhere, adds a line not listed.
fb=$dir/_field_built.mojo
# An array, not a here-document inside `$(...)`: bash 3.2 (macOS) parses
# the quotes and backquotes of such a here-document as shell code.
fb_lines=(
    'src/muntin/_field_built.mojo:"""`_FieldBuilt`: the types the storage module may build field by field'
    'src/muntin/_field_built.mojo:trait _FieldBuilt(Deinitable, Movable):'
    'src/muntin/_handler_storage.mojo:from ._field_built import _FieldBuilt'
    'src/muntin/_handler_storage.mojo:    T: _FieldBuilt,'
    'src/muntin/_handler_storage.mojo:    refinements of `_FieldBuilt`, so no other type can be built this way;'
    'src/muntin/route_value.mojo:from ._field_built import _FieldBuilt'
    'src/muntin/route_value.mojo:trait RouteValues(_FieldBuilt):'
    'src/muntin/json.mojo:from ._field_built import _FieldBuilt'
    'src/muntin/json.mojo:trait JsonFields(_FieldBuilt):'
)
fb_expected="$(printf '%s\n' "${fb_lines[@]}" | LC_ALL=C sort)"
fb_found="$(grep -rE --include='*.mojo' '_FieldBuilt' "$dir" | LC_ALL=C sort || true)"
if [[ "$fb_found" != "$fb_expected" ]]; then
    diff <(printf '%s\n' "$fb_expected") <(printf '%s\n' "$fb_found") || true
    echo "error: only RouteValues and JsonFields may refine _FieldBuilt: the lines naming it differ from the list (< listed, > found)" >&2
    status=1
fi
if grep -nE '^[[:space:]]*(from|import)[[:space:]]' "$fb"; then
    echo "error: $fb imports nothing" >&2
    status=1
fi

# Request data reaches handler storage only as the adapters' raw argument
# strings and the body bytes it passes through unread (M3-040): body
# conversion and request handling stay in app.mojo (M2-006).
if grep -nE 'FromBody|from_body|Request|\.body\b' "$storage"; then
    echo "error: $storage handles request or body data; keep it in the adapters" >&2
    status=1
fi

# Results and handler errors become a `Response` in the adapters too: the
# storage module never converts them (M2-013).
if grep -nE 'ToResponse|to_response|ToErrorResponse|to_error_response' "$storage"; then
    echo "error: $storage converts results or errors; keep it in the adapters" >&2
    status=1
fi

# The rebinds (M3-015, M3-082): `rebind_var` and `rebind` also accept a
# different type with the same layout, so a generic value or reference is
# rebound only through the two helpers in `_rebind.mojo`, each right after
# its type-equality assert. Exactly one `rebind_var[` and one `rebind[` in
# src/muntin, comments and docstrings included, both in `_rebind.mojo` on
# the line after `comptime assert A == T`; only `_rebind.mojo` imports from
# `std.builtin.rebind`, as exactly `from std.builtin.rebind import
# rebind_var`, and it imports nothing else; only app.mojo (`_as`) and
# json.mojo (`_as`, `_view`) import it. `downcast`, which Mojo 1.1.0 does
# not check, appears nowhere (M3-061). A space before the `[` (which the
# formatter removes, except in `# fmt: off` code) is matched too.
# scripts/test_check_unsafe.sh plants each violation.
rb=$dir/_rebind.mojo
one_after_assert() {
    local pattern=$1 label=$2 hits file rest line
    hits="$(grep -rnE --include='*.mojo' "$pattern" "$dir" || true)"
    if [[ "$(grep -c . <<<"$hits")" -ne 1 ]]; then
        printf '%s\n' "$hits"
        echo "error: src/muntin must contain exactly one '$label' (in $rb)" >&2
        status=1
        return
    fi
    file="${hits%%:*}"
    rest="${hits#*:}"
    line="${rest%%:*}"
    if [[ "$file" != "$rb" ]] ||
        ! sed -n "$((line - 1))p" "$file" | grep -qE '^[[:space:]]*comptime assert A == T\b'; then
        printf '%s\n' "$hits"
        echo "error: the one '$label' must be in $rb, on the line after 'comptime assert A == T'" >&2
        status=1
    fi
}
one_after_assert 'rebind_var[[:space:]]*\[' 'rebind_var['
one_after_assert '(^|[^[:alnum:]_])rebind[[:space:]]*\[' 'rebind['
if grep -rnE --include='*.mojo' 'rebind_var|builtin\.rebind' "$dir" | grep -v "^$rb:"; then
    echo "error: only $rb may import or name rebind_var" >&2
    status=1
fi
if grep -nE '^[[:space:]]*(from|import)[[:space:]]' "$rb" |
    grep -vE '^[0-9]+:from std\.builtin\.rebind import rebind_var$'; then
    echo "error: $rb imports only 'from std.builtin.rebind import rebind_var'" >&2
    status=1
fi
if grep -rnE --include='*.mojo' '_rebind\b' "$dir" | grep -v "^$rb:" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -vE "^$dir/app\.mojo:[0-9]+:from \._rebind import _as$" |
    grep -vE "^$dir/json\.mojo:[0-9]+:from \._rebind import _as, _view$"; then
    echo "error: only app.mojo (_as) and json.mojo (_as, _view) may import $rb" >&2
    status=1
fi
if grep -rnE --include='*.mojo' 'downcast[[:space:]]*\[' "$dir"; then
    echo "error: downcast is unchecked on Mojo 1.1.0; refine with conforms_to" >&2
    status=1
fi

if ((status == 0)); then
    echo "ok: unsafe handler storage confined to $storage; two guarded rebinds in $rb"
fi
exit "$status"
