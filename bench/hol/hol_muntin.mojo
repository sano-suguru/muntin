"""The head-of-line blocking measurement's server, written with Muntin.

Not part of Muntin and not run by CI. `scripts/bench_hol.sh` builds it in the
`flare` environment and runs it as `hol_muntin WORKERS IDLE_MS [GRACE_MS]`: it
binds `Server` on an ephemeral loopback port with `idle_timeout_ms=IDLE_MS`
(and `shutdown_grace_ms=GRACE_MS` when given, as M3-069's stop trials do),
prints `port <n>` and serves with `serve(app)` when `WORKERS` is 1 and with
`serve[make_app](workers=WORKERS)` otherwise. bench/hol/hol_flare.mojo is the
same server written against Flare alone.

Routes:
- `GET /slow/{ms}`: sleeps `ms` milliseconds on the serving thread, then
  answers `slow`. It writes `s` to the file named by `HOL_SIGNAL` (the
  client's FIFO) when it starts and `e` when it returns, so the client can
  tell which probes were sent while it ran. It stands for a handler waiting on a database or another
  service with a blocking call, the case the measurement is about.
- `GET /health`: answers `ok` at once.
- `GET /worker`: answers the serving thread's `pthread_self()`, so a client
  can tell which worker serves each of its connections.
- `GET /timed/{ms}`: `/slow/{ms}`, signals included, answering
  `<pthread_self()> <start> <end>`: `CLOCK_MONOTONIC` nanoseconds read as the
  handler starts and as it returns.
- `GET /stamp`: answers `<pthread_self()> <now>`, `now` as above. With
  `/timed`, a client tells from the server's own thread and clock whether a
  request was served by the worker running a slow handler, and before or
  after it (M3-069's trials).
"""

from std.ffi import external_call
from std.memory import stack_allocation
from std.os import getenv
from std.sys import CompilationTarget, argv
from std.time import sleep

from muntin import App
from muntin_flare import Server


def signal(byte: String) raises:
    """Writes `byte` to the file named by `HOL_SIGNAL`, if set."""
    var path = getenv("HOL_SIGNAL")
    if path != "":
        with open(path, "w") as f:
            f.write(byte)


def slow(ms: Int) raises -> String:
    signal("s")
    sleep(Float64(ms) / 1000.0)
    signal("e")
    return "slow"


def monotonic_ns() -> Int:
    """`CLOCK_MONOTONIC` in nanoseconds: the clock Python's
    `time.monotonic_ns()` reads, so a client on the same machine can compare
    its own times with the server's."""
    comptime clock = 6 if CompilationTarget.is_macos() else 1
    var ts = stack_allocation[2, Int64]()
    _ = external_call["clock_gettime", Int32](Int32(clock), ts)
    return Int(ts[unsafe_offset=0]) * 1_000_000_000 + Int(ts[unsafe_offset=1])


def timed(ms: Int) raises -> String:
    var start = monotonic_ns()
    signal("s")
    sleep(Float64(ms) / 1000.0)
    var end = monotonic_ns()
    signal("e")
    return worker() + " " + String(start) + " " + String(end)


def stamp() -> String:
    return worker() + " " + String(monotonic_ns())


def health() -> String:
    return "ok"


def worker() -> String:
    return String(external_call["pthread_self", UInt64]())


def make_app() -> App:
    var app = App()
    app.get["/slow/{ms}"](slow)
    app.get["/health"](health)
    app.get["/worker"](worker)
    app.get["/timed/{ms}"](timed)
    app.get["/stamp"](stamp)
    return app^


def main() raises:
    var args = argv()
    if len(args) != 3 and len(args) != 4:
        raise Error("usage: hol_muntin WORKERS IDLE_MS [GRACE_MS]")
    var workers = Int(args[1])
    var server = Server.bind(
        "127.0.0.1", 0, idle_timeout_ms=Int(args[2])
    ) if len(args) == 3 else Server.bind(
        "127.0.0.1",
        0,
        idle_timeout_ms=Int(args[2]),
        shutdown_grace_ms=Int(args[3]),
    )
    print("port", server.port(), flush=True)
    if workers == 1:
        var app = make_app()
        server.serve(app)
    else:
        server.serve[make_app](workers=workers)
