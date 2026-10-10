#!/usr/bin/env bash
# Confines Muntin's unsafe handler storage to one private module (M2-004).
# Fails if, anywhere in src/muntin except src/muntin/_handler_storage.mojo,
# a line names an unsafe pointer/ownership operation or touches the box's
# fields; if a module imports anything but `_Erased` or `_Shared` from it;
# if the package root exports it; if the module imports anything but the
# standard library and `.http`; or if it names request or body data (M2-006) or result/error
# conversion (M2-013); or if `rebind_var` appears anywhere but the one guarded
# rebind in app.mojo (M3-015, below). A confinement guard, not a safety proof:
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

# Other modules may import `_Erased` or `_Shared` (M3-004) and nothing else
# from the storage module, so its helpers (`_erase`, `_invoke_box`,
# `_drop_box`, `_Box`, `_SharedHeader`) stay inside it.
if grep -rnE --include='*.mojo' '_handler_storage' "$dir" | grep -v "^$storage:" |
    grep -vE '^[^:]+:[0-9]+:([[:space:]]*#|from \._handler_storage import (_Erased|_Shared)$)'; then
    echo "error: only 'from ._handler_storage import _Erased' or '... import _Shared' may name the storage module" >&2
    status=1
fi

if grep -nE '_handler_storage|_Erased' "$dir/__init__.mojo"; then
    echo "error: $dir/__init__.mojo exposes the private handler storage" >&2
    status=1
fi

if grep -nE '^[[:space:]]*(from|import)[[:space:]]' "$storage" |
    grep -vE '^[0-9]+:[[:space:]]*from[[:space:]]+(std\.[[:alnum:]_.]+|\.http)[[:space:]]+import[[:space:]]'; then
    echo "error: $storage may import only std and .http" >&2
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

# The one rebind (M3-015): `rebind_var` also accepts a different type with
# the same layout, so generic slots and results are rebound only through
# app.mojo's helper, right after its type-equality assert. Exactly one
# `rebind_var[` in src/muntin, storage module, comments and docstrings
# included; it follows `comptime assert A == T`; and only app.mojo imports
# from `std.builtin.rebind`, as exactly `from std.builtin.rebind import
# rebind_var`, and names `rebind_var` at all.
app=$dir/app.mojo
rebinds="$(grep -rnF --include='*.mojo' 'rebind_var[' "$dir" || true)"
if [[ "$(grep -c . <<<"$rebinds")" -ne 1 ]]; then
    printf '%s\n' "$rebinds"
    echo "error: src/muntin must contain exactly one 'rebind_var[' (the helper in $app)" >&2
    status=1
else
    file="${rebinds%%:*}"
    rest="${rebinds#*:}"
    line="${rest%%:*}"
    if [[ "$file" != "$app" ]] ||
        ! sed -n "$((line - 1))p" "$file" | grep -qE '^[[:space:]]*comptime assert A == T\b'; then
        printf '%s\n' "$rebinds"
        echo "error: the one 'rebind_var[' must be in $app, on the line after 'comptime assert A == T'" >&2
        status=1
    fi
fi
if grep -rnE --include='*.mojo' 'rebind_var|builtin\.rebind' "$dir" | grep -v "^$app:"; then
    echo "error: only $app may import or name rebind_var" >&2
    status=1
fi
if grep -nE 'builtin\.rebind' "$app" | grep -vE '^[0-9]+:from std\.builtin\.rebind import rebind_var$'; then
    echo "error: $app imports from std.builtin.rebind only as 'from std.builtin.rebind import rebind_var'" >&2
    status=1
fi

if ((status == 0)); then
    echo "ok: unsafe handler storage confined to $storage; one guarded rebind in $app"
fi
exit "$status"
