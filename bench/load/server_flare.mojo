"""Serves bench/overhead/flare_app.mojo with Flare's `HttpServer`, plus
`GET /slow/:ms`, for `scripts/bench_load.sh`. Not part of Muntin and not run
by CI.

    server_flare PORT WORKERS MIDDLEWARE

`GET /slow/:ms` sleeps `ms` milliseconds on the serving thread and answers
`slow`, as server_muntin.mojo's; `GET /headers` answers what
server_muntin.mojo's does, from Flare's own `HeaderMap`. Every `HttpServer` setting is its default;
Flare installs no signal handler, so SIGTERM ends the process at once. One
worker serves through `HttpServer.serve(handler)`; more through
`serve(handler, num_workers=n, pin_cores=False)` (one SO_REUSEPORT listener
per worker, Flare's default). MIDDLEWARE is 0 or 1. Prints `ready PORT`
once bound.
"""

from std.sys import argv
from std.time import sleep

from flare.http import Handler, HeaderMap, HttpServer, Request, Response, Router
from flare.net import SocketAddr

from flare_app import Tracing, router


def slow(req: Request) raises -> Response:
    sleep(Float64(Int(req.param("ms"))) / 1000.0)
    return Response(status=200, body=List(String("slow").as_bytes()))


def _lookup(headers: HeaderMap, name: String, mut out: String):
    var values = headers.get_all(name)
    out += String(name, "=", len(values), "\n")
    for v in values:
        out += name + ": " + v + "\n"


def fields(req: Request) raises -> Response:
    var out = String()
    for i in range(req.headers.len()):  # in order: Flare has no accessor for it
        var name = req.headers._keys[i]
        var lower = name.lower()
        if lower != "host" and lower != "cookie":
            out += name + ": " + req.headers._values[i] + "\n"
    for name in ["COOKIE", "Accept-Language", "HOST", "X-Absent"]:
        _lookup(req.headers, String(name), out)
    return Response(status=200, body=List(out.as_bytes()))


def _serve[
    H: Handler & Copyable
](mut srv: HttpServer, var h: H, workers: Int) raises:
    if workers == 1:
        srv.serve(h^)
    else:
        srv.serve(h^, num_workers=workers, pin_cores=False)


def main() raises:
    var args = argv()
    var workers = Int(args[2])
    var r = router()
    r.get("/slow/:ms", slow)
    r.get("/headers", fields)
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(Int(args[1]))))
    print("ready", Int(srv.local_addr().port), flush=True)
    if Int(args[3]) != 0:
        _serve(srv, Tracing(r^), workers)
    else:
        _serve(srv, r^, workers)
