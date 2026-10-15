"""The head-of-line blocking measurement's server, written against Flare
alone (no Muntin code).

Not part of Muntin and not run by CI. `scripts/bench_hol.sh` builds it in the
`flare` environment and runs it as `hol_flare WORKERS IDLE_MS`: it binds
Flare's `HttpServer` on an ephemeral loopback port with
`ServerConfig.idle_timeout_ms=IDLE_MS`, prints `port <n>` and serves with
`serve(handler)` when `WORKERS` is 1 and with Flare's own multi-worker
`serve(handler, num_workers=WORKERS, pin_cores=False)` otherwise (one
`SO_REUSEPORT` listener per worker, Flare's default; with
`FLARE_REUSEPORT_WORKERS=0` in its environment, one listener shared by every
worker, which Flare reads itself). The routes are bench/hol/hol_muntin.mojo's.
"""

from std.ffi import external_call
from std.os import getenv
from std.sys import argv
from std.time import sleep

from flare.http import Handler, HttpServer, Request, Response, ServerConfig
from flare.net import SocketAddr


def signal(byte: String) raises:
    """Writes `byte` to the file named by `HOL_SIGNAL`, if set."""
    var path = getenv("HOL_SIGNAL")
    if path != "":
        with open(path, "w") as f:
            f.write(byte)


@fieldwise_init
struct Hol(Copyable, Handler):
    def serve(self, request: Request) raises -> Response:
        var parts = request.url.split("/")
        if len(parts) == 3 and parts[1] == "slow":
            signal("s")
            sleep(Float64(Int(parts[2])) / 1000.0)
            signal("e")
            return Response(status=200, body=List("slow".as_bytes()))
        if request.url == "/health":
            return Response(status=200, body=List("ok".as_bytes()))
        if request.url == "/worker":
            var id = String(external_call["pthread_self", UInt64]())
            return Response(status=200, body=List(id.as_bytes()))
        return Response(status=404, body=List("not found".as_bytes()))


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: hol_flare WORKERS IDLE_MS")
    var workers = Int(args[1])
    var config = ServerConfig()
    config.idle_timeout_ms = Int(args[2])
    var server = HttpServer.bind(SocketAddr.localhost(0), config^)
    print("port", Int(server.local_addr().port), flush=True)
    if workers == 1:
        server.serve(Hol())
    else:
        server.serve(Hol(), num_workers=workers, pin_cores=False)
