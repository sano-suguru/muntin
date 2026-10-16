#!/usr/bin/env bash
# Keeps the Flare adapter's reliance on Flare's non-public code from growing
# unnoticed (M3-070; the rule is docs/ARCHITECTURE.md, "Flare policy").
# Over every adapter module but its tests (`test_*.mojo`), in any directory
# under the adapter, it fails if:
# - a module other than flare_internals.mojo imports a `_`-prefixed Flare
#   module or name;
# - flare_internals.mojo's Flare imports, or the `_`-prefixed members
#   (`._name`) and keywords (`_name=`) its code uses, differ from the lists
#   below, either way, so adding a reliance or leaving a stale entry shows in
#   the diff;
# - the modules pass 2,500 lines together;
# - a module cannot be read (a string or bracket left open), which fails
#   closed rather than skip code.
# Statements are read after strings and comments are removed, so a name in
# a docstring, comment or string is not code, and an import after `;`, on a
# `\` continuation or in a parenthesized list is. A ratchet on names, not a
# check of behavior: a non-public Flare member read outside
# flare_internals.mojo (`x._field`) looks like Muntin's own `self._field`, and
# a behavior the code relies on has no name to list. The adapter's tests may
# import Flare internals; flare_internals.mojo's docstring lists the ones
# they use. scripts/test_check_flare_reliance.sh tests this script.
set -euo pipefail
if [[ $# -gt 0 ]]; then
    dir="$(cd "$1" && pwd)"
fi
cd "$(dirname "$0")/.."

dir=${dir:-adapters/flare}
internals=$dir/flare_internals.mojo
status=0

# Every Flare import flare_internals.mojo makes, as `module name`.
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

# Every `_`-prefixed member or keyword flare_internals.mojo's code uses.
allowed_members='._listener
._tls_ctx_addr
_wrap='

# The adapter's size (M3-070): past this, a decision weighs the growth first.
max_lines=2500

fail() {
    echo "error: $*" >&2
    status=1
}

if [[ ! -f "$internals" ]]; then
    echo "error: $internals is missing" >&2
    exit 1
fi

# The statements of a Mojo file, one per line, as `line<TAB>statement`:
# strings (any quote, triple or not) become `""`, comments are dropped, a
# bracketed or `\`-continued statement is joined, and `;` splits statements.
# Prints `UNREADABLE<TAB>reason` for a string or bracket left open.
statements() {
    awk '
    BEGIN { state = 0; depth = 0; stmt = ""; start = 0 }
    function flush(    n, parts, i, s) {
        n = split(stmt, parts, ";")
        for (i = 1; i <= n; i++) {
            s = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            if (s != "") print start "\t" s
        }
        stmt = ""
    }
    {
        line = $0
        out = ""
        i = 1
        len = length(line)
        while (i <= len) {
            c = substr(line, i, 1)
            if (state == 0) {
                three = substr(line, i, 3)
                if (three == "\"\"\"" || three == "'"'''"'") {
                    quote = three; state = 2; out = out "\"\""; i += 3; continue
                }
                if (c == "\"" || c == "'"'"'") {
                    quote = c; state = 1; out = out "\"\""; i++; continue
                }
                if (c == "#") break
                if (c == "(" || c == "[" || c == "{") depth++
                if (c == ")" || c == "]" || c == "}") depth--
                out = out c
                i++
            } else {
                if (c == "\\") { i += 2; continue }
                if (state == 1 && c == quote) { state = 0; i++; continue }
                if (state == 2 && substr(line, i, 3) == quote) { state = 0; i += 3; continue }
                i++
            }
        }
        if (state == 1) { print "UNREADABLE\tstring left open on line " NR; exit }
        if (stmt == "") start = NR
        if (out ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", out); stmt = stmt out " "; next }
        stmt = stmt out " "
        if (state == 0 && depth == 0) flush()
    }
    END {
        if (state == 2) print "UNREADABLE\ttriple-quoted string left open"
        else if (depth != 0) print "UNREADABLE\tbracket left open"
        else if (stmt != "") flush()
    }' "$1"
}

# Each name a statement imports from a `flare` module (not `flare_internals`),
# as `module name`, aliases dropped; a plain `import flare.x` is `flare.x *`.
flare_imports() {
    awk -F '\t' '
    function emit(module, names,    n, parts, i, name) {
        gsub(/[()]/, " ", names)
        n = split(names, parts, ",")
        for (i = 1; i <= n; i++) {
            name = parts[i]
            sub(/[ \t]+as[ \t].*/, "", name)
            gsub(/[ \t]/, "", name)
            if (name != "") print module " " name
        }
    }
    $2 ~ /^from[ \t]+flare(\.|[ \t])/ {
        rest = $2
        sub(/^from[ \t]+/, "", rest)
        module = rest
        sub(/[ \t].*/, "", module)
        sub(/^[^ \t]+[ \t]+import[ \t]*/, "", rest)
        emit(module, rest)
        next
    }
    $2 ~ /^import[ \t]/ {
        rest = $2
        sub(/^import[ \t]+/, "", rest)
        n = split(rest, parts, ",")
        for (i = 1; i <= n; i++) {
            path = parts[i]
            sub(/[ \t]+as[ \t].*/, "", path)
            gsub(/[ \t]/, "", path)
            if (path ~ /^flare(\.|$)/) print path " *"
        }
    }'
}

# The `_`-prefixed members (`._name`) and keywords (`_name =`, written
# `_name=`) a file's statements use, imports aside.
members() {
    awk -F '\t' '$2 !~ /^(from|import)[ \t]/ { print $2 }' |
        grep -oE '\._[A-Za-z][A-Za-z0-9_]*|(^|[^A-Za-z0-9_.])_[A-Za-z][A-Za-z0-9_]*[[:space:]]*=([^=]|$)' |
        sed -E 's/^[^._]*//; s/[[:space:]]*=.*$/=/' | LC_ALL=C sort -u || true
}

modules="$(find "$dir" -name '*.mojo' ! -name 'test_*.mojo' | LC_ALL=C sort)"
lines=0
for f in $modules; do
    lines=$((lines + $(wc -l <"$f")))
    parsed="$(statements "$f")"
    if grep -q '^UNREADABLE' <<<"$parsed"; then
        fail "$f: $(grep '^UNREADABLE' <<<"$parsed" | cut -f2); this script cannot read it, so it fails closed"
        continue
    fi
    if [[ "$f" == "$internals" ]]; then
        found="$(flare_imports <<<"$parsed" | LC_ALL=C sort -u)"
        if [[ "$found" != "$(LC_ALL=C sort -u <<<"$allowed_imports")" ]]; then
            diff <(LC_ALL=C sort -u <<<"$allowed_imports") <(printf '%s\n' "$found") | grep '^[<>]' || true
            fail "$internals's Flare imports differ from the list in $0 (> new, < stale); a new reliance follows docs/ARCHITECTURE.md, \"Flare policy\", and the list follows the code"
        fi
        found="$(members <<<"$parsed")"
        if [[ "$found" != "$(LC_ALL=C sort -u <<<"$allowed_members")" ]]; then
            diff <(LC_ALL=C sort -u <<<"$allowed_members") <(printf '%s\n' "$found") | grep '^[<>]' || true
            fail "$internals's non-public Flare members differ from the list in $0 (> new, < stale); a new reliance follows docs/ARCHITECTURE.md, \"Flare policy\", and the list follows the code"
        fi
    elif flare_imports <<<"$parsed" | grep -E '(\._|^[^ ]+ _)'; then
        fail "$f imports a non-public Flare module or name; only $internals may (docs/ARCHITECTURE.md, \"Flare policy\")"
    fi
done

if ((lines > max_lines)); then
    fail "the adapter's modules (tests aside) have $lines lines together, over $max_lines; growth past it waits for a decision (docs/ARCHITECTURE.md, \"Flare policy\")"
fi

if ((status == 0)); then
    echo "ok: non-public Flare imports confined to $internals and equal to its list; $lines adapter lines (at most $max_lines)"
fi
exit "$status"
