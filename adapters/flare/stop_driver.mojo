"""A serving program for `adapters/flare/test_server.mojo`'s exec-based stop
tests (M3-045): built by scripts/check_flare.sh as `build/stop_driver` and
run with `execv`, so it has the Mojo runtime's worker threads and signal
handlers that a forked test child lacks, and it ends by returning from
`main`, as an application does.

`stop_driver <grace_ms>` binds `127.0.0.1:0` with that `shutdown_grace_ms`,
prints the port on its own line, then serves `/hello` and
`/held/{started}/{release}` (the test's `held`: it reports through one
inherited pipe that it started and waits on another).
"""

from std.io.file_descriptor import FileDescriptor
from std.sys import argv

from muntin import App
from muntin_flare import Server


def hello() -> String:
    return "hello"


def held(started: Int, release: Int) raises -> String:
    var out = FileDescriptor(started)
    out.write_bytes("s".as_bytes())
    var byte = List[UInt8](length=1, fill=0)
    var source = FileDescriptor(release)
    if source.read_bytes(byte) != 1:
        raise Error("held: not released")
    return "released after the stop"


def main() raises:
    var grace = atol(argv()[1])
    var app = App()
    app.get["/hello"](hello)
    app.get["/held/{started}/{release}"](held)
    var server = Server.bind("127.0.0.1", 0, shutdown_grace_ms=grace)
    print(server.port(), flush=True)
    server.serve(app)
