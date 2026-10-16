#!/usr/bin/env bash
# Tests scripts/check_flare_reliance.sh (M3-070): each case copies the
# adapter, changes the copy and expects the check to pass or fail, so a
# change that lets the check miss a reliance, or refuse code it should
# accept, fails here. Run by scripts/check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

check=$PWD/scripts/check_flare_reliance.sh
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
count=0

# expect pass|fail NAME: runs the check on $work/flare after the case's edit.
expect() {
    local want=$1 name=$2 got
    count=$((count + 1))
    if "$check" "$work/flare" >"$work/out" 2>&1; then got=pass; else got=fail; fi
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $name: expected $want, got $got" >&2
        sed 's/^/    /' "$work/out" >&2
        failures=$((failures + 1))
    else
        echo "ok: $name ($want)"
    fi
}

# fresh: a clean copy of the adapter.
fresh() {
    rm -rf "$work/flare"
    cp -R adapters/flare "$work/flare"
}

adapter=$work/flare/muntin_flare.mojo
internals=$work/flare/flare_internals.mojo

fresh
expect pass "the adapter as it is"

fresh
printf '\nfrom flare.http import HttpServer as _Again\n' >>"$adapter"
expect pass "a public import, aliased with a leading underscore"

fresh
printf '\nfrom flare.net._libc_event import _pipe\n' >>"$adapter"
expect fail "a private import outside flare_internals.mojo"

fresh
printf '\nimport flare.net._libc_event\n' >>"$adapter"
expect fail "a plain import of a private module"

fresh
printf '\nfrom flare.http import (\n    HttpServer,\n    _private_name,\n)\n' >>"$adapter"
expect fail "a private name in a parenthesized list"

fresh
printf '\n# """\nfrom flare.net._libc_event import _pipe\n# """\n' >>"$adapter"
expect fail "a private import between comments holding triple quotes"

fresh
printf '\nfrom std.math import sqrt; from flare.net._libc_event import _pipe\n' >>"$adapter"
expect fail "a private import after a semicolon"

fresh
printf '\nfrom flare.net._libc_event \\\n    import _pipe\n' >>"$adapter"
expect fail "a private import on a backslash continuation"

fresh
printf '\ncomptime _TEXT = "from flare.net._libc_event import _pipe"\n' >>"$adapter"
expect pass "a private import spelled inside a string"

fresh
mkdir -p "$work/flare/more"
printf 'from flare.runtime._thread import current_thread_id\n' >"$work/flare/more/extra.mojo"
expect fail "a private import in a module in a subdirectory"

fresh
printf 'from flare.runtime._thread import current_thread_id\n' >"$work/flare/test_extra.mojo"
expect pass "a private import in a test module"

fresh
printf '\nfrom flare.http import HttpFrontend\n' >>"$internals"
expect fail "a new import in flare_internals.mojo"

fresh
printf '\n\ndef _more(server: HttpServer) -> Int:\n    return Int(server._stopping)\n' >>"$internals"
expect fail "a new private member in flare_internals.mojo"

fresh
printf '\n\ndef _more(fd: Int):\n    _ = RawSocket(c_int(fd), AF_INET, SOCK_STREAM, _other = True)\n' >>"$internals"
expect fail "a new private keyword with spaces around ="

fresh
printf '\n\ndef _more(server: HttpServer) -> Int:\n    """Not code: `server._stopping`, `from flare.x._y import _z`."""\n    return Int(server._listener.as_raw_fd())  # server._other\n' >>"$internals"
expect pass "listed members only, private names in a docstring and a comment"

fresh
sed -e 's/, _wrap=True//' "$internals" >"$work/edited" && mv "$work/edited" "$internals"
expect fail "a listed member no longer used (stale list)"

fresh
printf '\n"""a string left open\n' >>"$adapter"
expect fail "a module the script cannot read"

fresh
awk 'BEGIN { for (i = 0; i < 2500; i++) print "# padding" }' >>"$adapter"
expect fail "the modules past 2,500 lines"

if ((failures > 0)); then
    echo "error: $failures of $count cases of check_flare_reliance.sh failed" >&2
    exit 1
fi
echo "ok: $count cases of check_flare_reliance.sh"
