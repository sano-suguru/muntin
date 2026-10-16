#!/usr/bin/env bash
# Keeps the Flare adapter's reliance on Flare's non-public code from growing
# unnoticed (M3-070; the rule is docs/ARCHITECTURE.md, "Flare policy").
# Fails if a Flare import in the adapter outside flare_internals.mojo names a
# `_`-prefixed module or name, or if flare_internals.mojo imports from Flare,
# or reads a `_`-prefixed member or keyword, beyond the lists below, or if
# the two modules pass 2,500 lines together. A change that adds a name
# updates the list here, so the reliance shows in the diff.
# A ratchet on names, not a check of behavior: a non-public Flare member read
# outside flare_internals.mojo (`x._field`) looks like Muntin's own
# `self._field`, and a behavior the code relies on has no name to list.
# The adapter's tests may import Flare internals; flare_internals.mojo's
# docstring lists the ones they use.
set -euo pipefail
if [[ $# -gt 0 ]]; then
    dir="$(cd "$1" && pwd)"
fi
cd "$(dirname "$0")/.."

dir=${dir:-adapters/flare}
internals=$dir/flare_internals.mojo
status=0

# Every Flare import flare_internals.mojo may make, as `module name`.
allowed_imports='flare.http Handler
flare.http HttpServer
flare.http ServerConfig
flare.http._unified_reactor_impl run_unified_reactor_loop_shared
flare.net._libc_event _pipe
flare.net.socket AF_INET
flare.net.socket INVALID_FD
flare.net.socket SOCK_STREAM
flare.net.socket RawSocket
flare.runtime._thread ThreadHandle
flare.runtime._thread _OpaquePtr
flare.runtime.scheduler_stats store_stop_flag'

# Every `_`-prefixed member (`._name`) or keyword (`_name=`) of a Flare value
# that flare_internals.mojo's code may use.
allowed_members='._listener
._tls_ctx_addr
_wrap='

if [[ ! -f "$internals" ]]; then
    echo "error: $internals is missing" >&2
    exit 1
fi

# The code of a Mojo file: docstrings (triple-quoted) and comments removed.
code() {
    awk '{
        line = $0
        n = gsub(/"""/, "\"\"\"", line)
        if (!in_doc && n == 0) { sub(/#.*/, "", line); print line }
        if (n % 2 == 1) in_doc = !in_doc
    }' "$1"
}

# Each name imported from a `flare` module (not `flare_internals`), one
# `module name` per line, aliases dropped; parenthesized lists included. A
# plain `import flare.x` is `flare.x *`.
flare_imports() {
    code "$1" | awk '
        function emit(module, names,    n, parts, i, name) {
            n = split(names, parts, ",")
            for (i = 1; i <= n; i++) {
                name = parts[i]
                sub(/ as .*/, "", name)
                gsub(/[[:space:]()]/, "", name)
                if (name != "") print module " " name
            }
        }
        open {
            buffer = buffer "," $0
            if ($0 ~ /\)/) { emit(module, buffer); open = 0 }
            next
        }
        /^[[:space:]]*import[[:space:]]+flare\./ {
            rest = $0
            sub(/^[[:space:]]*import[[:space:]]+/, "", rest)
            n = split(rest, parts, ",")
            for (i = 1; i <= n; i++) {
                path = parts[i]
                sub(/ as .*/, "", path)
                gsub(/[[:space:]]/, "", path)
                if (path != "") print path " *"
            }
            next
        }
        /^[[:space:]]*from[[:space:]]+flare(\.|[[:space:]])/ {
            module = $2
            rest = $0
            sub(/.*[[:space:]]import[[:space:]]+/, "", rest)
            if (rest ~ /^\(/ && rest !~ /\)/) { open = 1; buffer = rest; next }
            emit(module, rest)
        }'
}

for f in "$dir"/*.mojo; do
    case "$(basename "$f")" in
        flare_internals.mojo | test_*.mojo) continue ;;
    esac
    if flare_imports "$f" | grep -E '(\._|^[^ ]+ _)' | sed "s|^|$f: |"; then
        echo "error: $f imports a non-public Flare module or name; only $internals may (docs/ARCHITECTURE.md, \"Flare policy\")" >&2
        status=1
    fi
done

extra_imports="$(flare_imports "$internals" | grep -vxF "$allowed_imports" || true)"
if [[ -n "$extra_imports" ]]; then
    printf '%s\n' "$extra_imports"
    echo "error: $internals imports from Flare beyond the list in $0; a new reliance follows docs/ARCHITECTURE.md, \"Flare policy\", and adds itself to the list" >&2
    status=1
fi

extra_members="$(code "$internals" | grep -vE '^[[:space:]]*(from|import)[[:space:]]' | grep -oE '\._[A-Za-z][A-Za-z0-9_]*|\b_[A-Za-z][A-Za-z0-9_]*=' |
    sort -u | grep -vxF "$allowed_members" || true)"
if [[ -n "$extra_members" ]]; then
    printf '%s\n' "$extra_members"
    echo "error: $internals reads a non-public Flare member beyond the list in $0; a new reliance follows docs/ARCHITECTURE.md, \"Flare policy\", and adds itself to the list" >&2
    status=1
fi

# The adapter's size (M3-070): past this, a decision weighs the growth first.
max_lines=2500
lines=$(cat "$dir/muntin_flare.mojo" "$internals" | wc -l | tr -d ' ')
if ((lines > max_lines)); then
    echo "error: muntin_flare.mojo and flare_internals.mojo have $lines lines together, over $max_lines; growth past it waits for a decision (docs/ARCHITECTURE.md, \"Flare policy\")" >&2
    status=1
fi

if ((status == 0)); then
    echo "ok: non-public Flare imports confined to $internals, within its listed reliance"
fi
exit "$status"
