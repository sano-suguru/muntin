#!/usr/bin/env bash
# Confines Muntin's unsafe handler storage to one private module (M2-004).
# Fails if, anywhere in src/muntin except src/muntin/_handler_storage.mojo,
# a line names an unsafe pointer/ownership operation or touches the box's
# fields; if a module imports anything but `_Erased` from it; if the package
# root exports it; or if the module imports anything but the standard
# library and `.http`. A confinement guard, not a
# safety proof: the invariant itself is in the module docstring and
# docs/ARCHITECTURE.md "Handler storage decision (M2)". tests/ is not checked
# (spikes and storage tests use these operations on purpose).
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

# Other modules may import `_Erased` and nothing else from the storage module,
# so its helpers (`_erase`, `_invoke_box`, `_drop_box`, `_Box`) stay inside it.
if grep -rnE --include='*.mojo' '_handler_storage' "$dir" | grep -v "^$storage:" |
    grep -vE '^[^:]+:[0-9]+:([[:space:]]*#|from \._handler_storage import _Erased$)'; then
    echo "error: only 'from ._handler_storage import _Erased' may name the storage module" >&2
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

if ((status == 0)); then
    echo "ok: unsafe handler storage confined to $storage"
fi
exit "$status"
