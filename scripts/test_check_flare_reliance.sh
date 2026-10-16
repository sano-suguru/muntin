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
printf '\nfrom flare .net._libc_event import _pipe\n' >>"$adapter"
expect fail "a private import with a space in its module path"

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
printf '\n\ndef _more(server: HttpServer):\n    print(t"port {server._stopping}")\n' >>"$internals"
expect fail "a private member in a template string's expression"

fresh
printf '\n\ndef _more(server: HttpServer):\n    print(f"""port\n{server._stopping}""")\n' >>"$internals"
expect fail "a private member in a triple-quoted f-string's expression"

fresh
printf '\n\ndef _more():\n    print(t"{{server._stopping}} {1 + 1}")\n' >>"$internals"
expect pass "doubled braces in a template string, which are text"

fresh
printf '\n\ndef _more(d: Dict[String, Int]):\n    print(t"{d[\x27k\x27]}")\n' >>"$internals"
expect fail "a template string expression holding a quote, which the script refuses"

fresh
printf '\n\ndef _more(server: HttpServer):\n    print(t"""{server._stopping\n}""")\n' >>"$internals"
expect fail "a template string expression spanning lines, which the script refuses"

fresh
printf '\n\ndef _more(server: HttpServer) -> Int:\n    return Int(server. _stopping)\n' >>"$internals"
expect fail "a private member after a dot and a space"

fresh
printf '\n\ndef _more(server: HttpServer):\n    print(server.`_stopping`)\n' >>"$internals"
expect fail "a private member written as a backquoted name"

fresh
printf '\n\ndef _more(server: HttpServer):\n    var `marker#` = 1; print(server._stopping)\n' >>"$internals"
expect fail "a private member after a backquoted name holding #"

fresh
printf '\n\ndef _more():\n    var `plain` = 1\n    var `two words` = 2\n' >>"$internals"
expect pass "backquoted names with no private member"

fresh
printf '\n\ndef _more():\n    var `open = 1\n' >>"$internals"
expect fail "a backquoted name left open"

fresh
printf '\n\ndef _more() -> Int:\n    var _counter = 1\n    var _typed: Int = 2\n    _counter = 3\n    return _counter + _typed\n' >>"$internals"
expect pass "_-prefixed variables, which are not Flare keywords"

fresh
printf '\n\ndef _more():\n    _ = ServerConfig[_mode=1]()\n' >>"$internals"
expect fail "a private keyword in a parameter list"

fresh
printf 'from flare.net._libc_event import _pipe\n' >"$work/flare/test_bridge.mojo"
printf '\nfrom test_bridge import _pipe\n' >>"$adapter"
expect fail "a module importing a test module"

fresh
printf '\nfrom .test_server import serve_once\n' >>"$adapter"
expect fail "a module importing a test module by a relative path"

fresh
printf 'from flare.runtime._thread import current_thread_id\n' >"$work/flare/extra.🔥"
expect fail "a private import in a .🔥 module"

fresh
printf '\n\ndef _more(server: HttpServer) -> Int:\n    return Int(server._stopping)\n' >>"$adapter"
expect pass "out of scope: a private member read outside flare_internals.mojo, left to review"

fresh
printf '\n\ndef _more():\n    if True: from flare.net._libc_event import _pipe\n' >>"$adapter"
expect fail "a private import after a one-line if"

fresh
printf '\n\ndef _more():\n    with x: import flare.net._libc_event\n' >>"$adapter"
expect fail "a plain private import after a one-line with"

fresh
printf '\n\ndef _more(): from flare.http import HttpFrontend\n' >>"$internals"
expect fail "a new import in a one-line def in flare_internals.mojo"

fresh
printf '\n\ndef _more(server: HttpServer) -> Int:\n    return Int(server.__stopping)\n' >>"$internals"
expect fail "a private member with two leading underscores"

fresh
printf '\n\ndef _more(fd: Int):\n    _ = RawSocket(c_int(fd), AF_INET, SOCK_STREAM, __wrap2=True)\n' >>"$internals"
expect fail "a private keyword with two leading underscores"

fresh
printf '\n\ndef _more(server: HttpServer):\n    print(t"\\{server._stopping}")\n' >>"$internals"
expect fail "a private member after a backslash in a template string"

fresh
printf '\n\ndef _more(fd: Int, d: List[Int]):\n    print(t"fd {fd:#x} {d[1:2]} {fd!r:>8}")\n' >>"$internals"
expect pass "format specs and a slice in template string expressions"

fresh
printf '\n\ndef _more(fd: Int, w: Int):\n    print(t"{fd:{w}}")\n' >>"$internals"
expect fail "a nested expression in a format spec, which the script refuses"

fresh
printf '\nfrom muntin.testing import test_client\n' >>"$adapter"
expect pass "a name starting with test_ from a module that is not a test module"

fresh
printf '\n\ndef _more(fd: Int):\n    _ = RawSocket(c_int(fd), AF_INET, SOCK_STREAM, _other=True)\n' >>"$adapter"
expect pass "out of scope: a private keyword outside flare_internals.mojo, left to review"

fresh
mkdir -p "$work/bin"
printf '#!/bin/sh\ncommand -p find "$@"\necho "find: a directory it could not read" >&2\nexit 1\n' >"$work/bin/find"
chmod +x "$work/bin/find"
PATH="$work/bin:$PATH" expect fail "a find that fails, as on a directory it cannot read"
rm -rf "$work/bin"

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
