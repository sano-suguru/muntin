#!/usr/bin/env bash
# Keeps the Flare adapter's reliance on Flare's non-public code from growing
# unnoticed (M3-070; the rule is docs/ARCHITECTURE.md, "Flare policy").
# Over every adapter module (`.mojo` or `.🔥`, in any directory under the
# adapter) but its tests (`test_*`), it fails if:
# - a module other than flare_internals.mojo imports a `_`-prefixed Flare
#   module or name;
# - flare_internals.mojo's Flare imports, or the `_`-prefixed members
#   (`._name`) and keyword arguments (`_name=`) its code uses, differ from the
#   lists below, either way, so adding a reliance or leaving a stale entry
#   shows in the diff;
# - a module imports a test module, which this script does not read;
# - the modules pass 2,500 lines together;
# - a module holds what this script does not read (see `statements`), which
#   fails closed rather than skip code.
# Statements are read after strings and comments are removed, so a name in
# a docstring, comment or string is not code, and an import after `;`, on a
# `\` continuation, in a parenthesized list or after `if x:` on one line,
# a template string's expression and a backquoted name are. A ratchet on
# names, not a check of behavior or a Mojo parser: a non-public Flare member
# or keyword outside flare_internals.mojo (`x._field`, `f(_k=1)`) looks like
# Muntin's own (`self._field`), and a behavior the code relies on has no name
# to list; the tests pin what it reads, what it refuses and what it leaves to
# review. The adapter's tests may import Flare internals; flare_internals.mojo's
# docstring lists the ones they use. scripts/test_check_flare_reliance.sh
# tests this script.
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
# A template string's (a `t` or `f` prefix) `{expression}` stays as code, in
# parentheses; a backquoted name (`` `name` ``) becomes the name, or
# `BACKQUOTED` when it is not a plain one. Prints `UNREADABLE<TAB>reason` for
# what it does not read: a string, bracket, backquote or template expression
# left open, or a template expression holding a quote, backslash, `#` or
# backquote.
statements() {
    awk '
    BEGIN { state = 0; depth = 0; stmt = ""; start = 0; interp = 0; failed = 0 }
    function flush(    n, parts, i, s) {
        n = split(stmt, parts, ";")
        for (i = 1; i <= n; i++) {
            s = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            if (s != "") print start "\t" s
        }
        stmt = ""
    }
    function unreadable(why) {
        print "UNREADABLE\t" why " on line " NR
        failed = 1
        exit
    }
    {
        line = $0
        out = ""
        i = 1
        len = length(line)
        while (i <= len) {
            c = substr(line, i, 1)
            if (state == 0) {
                if (c == "`") {
                    j = index(substr(line, i + 1), "`")
                    if (j == 0) unreadable("a backquoted name left open")
                    name = substr(line, i + 1, j - 1)
                    if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) name = "BACKQUOTED"
                    out = out name
                    i += j + 1
                    continue
                }
                if (c == "\"" || c == "'"'"'") {
                    interp = 0
                    if (match(out, /[A-Za-z0-9_]+$/)) {
                        prefix = substr(out, RSTART)
                        if (length(prefix) <= 2 && prefix ~ /^[rRtTfFbBuU]+$/ && prefix ~ /[tTfF]/) interp = 1
                    }
                    three = substr(line, i, 3)
                    if (three == "\"\"\"" || three == "'"'''"'") {
                        quote = three; state = 2; out = out "\"\""; i += 3; continue
                    }
                    quote = c; state = 1; out = out "\"\""; i++; continue
                }
                if (c == "#") break
                if (c == "(" || c == "[" || c == "{") depth++
                if (c == ")" || c == "]" || c == "}") depth--
                out = out c
                i++
            } else {
                if (c == "\\") {
                    # In a template string a backslash does not escape a brace.
                    if (interp && substr(line, i + 1, 1) ~ /[{}]/) i++
                    else i += 2
                    continue
                }
                if (interp && (c == "{" || c == "}")) {
                    if (substr(line, i + 1, 1) == c) { i += 2; continue }
                    if (c == "}") { i++; continue }
                    # The expression runs to a `:` (its format spec, text)
                    # or the `}` at its own level.
                    d = 0
                    spec = 0
                    for (j = i + 1; j <= len; j++) {
                        ch = substr(line, j, 1)
                        if (spec) {
                            if (ch == "{") unreadable("a template string format spec holding a brace")
                            if (ch == "}") break
                            continue
                        }
                        if (ch == "\"" || ch == "'"'"'" || ch == "\\" || ch == "#" || ch == "`")
                            unreadable("a template string expression holding a quote, backslash, # or backquote")
                        if (ch == "(" || ch == "[" || ch == "{") d++
                        else if (ch == "}" && d == 0) break
                        else if (ch == ")" || ch == "]" || ch == "}") d--
                        else if (ch == ":" && d == 0 && substr(line, j + 1, 1) != "=") { spec = 1; e = j }
                    }
                    if (j > len) unreadable("a template string expression left open")
                    if (!spec) e = j
                    out = out " (" substr(line, i + 1, e - i - 1) ") "
                    i = j + 1
                    continue
                }
                if (state == 1 && c == quote) { state = 0; i++; continue }
                if (state == 2 && substr(line, i, 3) == quote) { state = 0; i += 3; continue }
                i++
            }
        }
        if (state == 1) unreadable("a string left open")
        if (stmt == "") start = NR
        if (out ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", out); stmt = stmt out " "; next }
        stmt = stmt out " "
        if (state == 0 && depth == 0) flush()
    }
    END {
        if (failed) exit
        if (state == 2) print "UNREADABLE\ttriple-quoted string left open"
        else if (depth != 0) print "UNREADABLE\tbracket left open"
        else if (stmt != "") flush()
    }' "$1"
}

# Each name a statement imports, as `module name`, aliases and spaces in the
# path dropped; a plain `import a.b` is `a.b *`. An import anywhere in a
# statement counts, as after `if x:` or `try:` on one line.
imports() {
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
    {
        s = " " $2
        while (match(s, /[^A-Za-z0-9_.](from|import)[ \t(]/)) {
            s = substr(s, RSTART + 1)
            if (s ~ /^from/) {
                s = substr(s, 5)
                # Without `import` it is not an import (`raise e from x`).
                if (!match(s, /[ \t]import([ \t(]|$)/)) continue
                module = substr(s, 1, RSTART - 1)
                gsub(/[ \t]/, "", module)
                s = substr(s, RSTART + 7)
                emit(module, s)
                continue
            }
            s = substr(s, 7)
            n = split(s, parts, ",")
            for (i = 1; i <= n; i++) {
                path = parts[i]
                sub(/[ \t]+as[ \t].*/, "", path)
                gsub(/[ \t]/, "", path)
                if (path != "") print path " *"
            }
        }
    }'
}

# The Flare ones (`flare` or `flare.x`, not `flare_internals`).
flare_imports() {
    imports | awk '$1 ~ /^flare(\.|$)/'
}

# The `_`-prefixed members (`._name`) and keyword arguments (`_name =` right
# after `(`, `[` or `,` inside brackets, written `_name=`) a file's statements
# use, imports aside. A `_`-prefixed variable (`var _x = 1`) is not one.
members() {
    awk -F '\t' '
    $2 ~ /^(from|import)[ \t]/ { next }
    {
        s = $2
        rest = s
        while (match(rest, /\.[ \t]*_[A-Za-z0-9_]*/)) {
            name = substr(rest, RSTART, RLENGTH)
            gsub(/[ \t]/, "", name)
            print name
            rest = substr(rest, RSTART + RLENGTH)
        }
        depth = 0
        prev = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "_" && depth > 0 && (prev == "(" || prev == "[" || prev == ",") &&
                match(substr(s, i), /^_[A-Za-z0-9_]*[ \t]*=/) &&
                substr(s, i + RLENGTH, 1) != "=") {
                name = substr(s, i, RLENGTH)
                sub(/[ \t]*=$/, "", name)
                print name "="
            }
            if (c == "(" || c == "[" || c == "{") depth++
            if (c == ")" || c == "]" || c == "}") depth--
            if (c != " " && c != "\t") prev = c
        }
    }' | LC_ALL=C sort -u
}

lines=0
while IFS= read -r f; do
    lines=$((lines + $(wc -l <"$f")))
    parsed="$(statements "$f")"
    if grep -q '^UNREADABLE' <<<"$parsed"; then
        fail "$f: $(grep '^UNREADABLE' <<<"$parsed" | cut -f2); this script cannot read it, so it fails closed"
        continue
    fi
    if imports <<<"$parsed" | awk '{ n = split($1, seg, "."); for (i = 1; i <= n; i++) if (seg[i] ~ /^test_/) bad = 1
            if ($1 ~ /^\.+$/ && $2 ~ /^test_/) bad = 1 } END { exit !bad }'; then
        fail "$f imports a test module (\`test_*\`), which this script does not read; a module the adapter uses is not named \`test_*\`"
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
done < <(find "$dir" \( -name '*.mojo' -o -name '*.🔥' \) ! -name 'test_*' | LC_ALL=C sort)

if ((lines > max_lines)); then
    fail "the adapter's modules (tests aside) have $lines lines together, over $max_lines; growth past it waits for a decision (docs/ARCHITECTURE.md, \"Flare policy\")"
fi

if ((status == 0)); then
    echo "ok: non-public Flare imports confined to $internals and equal to its list; $lines adapter lines (at most $max_lines)"
fi
exit "$status"
