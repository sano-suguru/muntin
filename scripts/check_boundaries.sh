#!/usr/bin/env bash
# Fails if Muntin core/public modules import a networking backend (Flare) or
# socket machinery. Usage: check_boundaries.sh [DIR]  (default: src/muntin)
set -euo pipefail
cd "$(dirname "$0")/.."

dir="${1:-src/muntin}"
pattern='^[[:space:]]*(from|import)[[:space:]]+[^#]*(flare|socket)'
if grep -rnEi --include='*.mojo' "$pattern" "$dir"; then
    echo "error: $dir imports a backend/socket module (see docs/ARCHITECTURE.md A2)" >&2
    exit 1
fi
if grep -rni --include='*.mojo' 'flare' "$dir"; then
    echo "error: $dir mentions Flare; core/public modules must not expose it" >&2
    exit 1
fi
echo "ok: no Flare/socket imports in $dir"
