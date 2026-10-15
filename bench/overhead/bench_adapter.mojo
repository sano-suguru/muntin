"""What one request costs in process, without the network: Muntin against
Flare alone, on the benchmark application (`muntin_app.mojo`,
`flare_app.mojo`). Not part of Muntin and not run by CI;
`scripts/bench_overhead.sh` builds and runs it.

Each request is built once, before timing, as a Flare `Request`; the Muntin
`Request` is the adapter's conversion of it (`to_muntin_request`). A timed
iteration is one call and the response it returns, dropped. Before timing,
every implementation's answer to the case is checked: its status and its
body. Timed answers are checked by status (`bench/routing/harness.mojo`).

Implementations:
- `muntin`: `App.handle(Request)`, Muntin's routing, handler and conversions
  alone.
- `muntin+adapter`: `MuntinHandler.serve` on the Flare `Request`: the
  adapter's conversions around `App.handle` (request target, headers and a
  copy of the body in; status, headers and a copy of the body out), what a
  request served by `Server` pays besides the network.
- `flare`: Flare's `Router.serve` (`Tracing[Router]` with the middleware).
- `headers`: `to_muntin_headers` alone, the adapter's request header
  conversion; `plaintext` cases without the middleware.

Cases, each with and without the middleware (`mw=1`, `mw=0`):
- `plaintext`, with `h` request header fields named `X-Bench-000` up to
  `X-Bench-127` (all the same length, which `to_muntin_headers` compares
  case-insensitively, pair by pair, for each later field);
- `json-get` and `json-post` (`{"name":"Ada","age":36}`, its one field
  `Content-Type: application/json`);
- `echo`, a `b`-byte body.

Each line printed is one case and one implementation, in nanoseconds per
request: the median and the minimum over the timed runs.
"""

from flare.http import Handler, Router
from flare.http import Request as FlareRequest
from muntin import App, Request
from muntin_flare import MuntinHandler, to_muntin_headers, to_muntin_request

from harness import Dispatch, runs_arg, time_per_request
from flare_app import Tracing, router
from muntin_app import build


comptime HEADER_COUNTS: List[Int] = [0, 8, 16, 32, 128]
comptime BODY_SIZES: List[Int] = [0, 1024, 65536, 1048576]
comptime JSON_IN = '{"name":"Ada","age":36}'


struct MuntinCore(Dispatch):
    var app: App
    var request: Request

    def __init__(out self, middleware: Bool, request: FlareRequest) raises:
        self.app = build(middleware)
        self.request = to_muntin_request(request)

    def status(self) raises -> Int:
        return self.app.handle(self.request).status

    def body(self) raises -> String:
        return self.app.handle(self.request).text()


struct MuntinAdapter(Dispatch):
    var handler: MuntinHandler
    var request: FlareRequest

    def __init__(out self, middleware: Bool, var request: FlareRequest):
        self.handler = MuntinHandler(build(middleware))
        self.request = request^

    def status(self) raises -> Int:
        return self.handler.serve(self.request).status

    def body(self) raises -> String:
        return self.handler.serve(self.request).text()


struct FlareDirect[H: Handler](Dispatch):
    var handler: Self.H
    var request: FlareRequest

    def __init__(out self, var handler: Self.H, var request: FlareRequest):
        self.handler = handler^
        self.request = request^

    def status(self) raises -> Int:
        return self.handler.serve(self.request).status

    def body(self) raises -> String:
        return self.handler.serve(self.request).lower().text()


struct HeaderConversion(Dispatch):
    var request: FlareRequest

    def __init__(out self, var request: FlareRequest):
        self.request = request^

    def status(self) raises -> Int:
        _ = to_muntin_headers(self.request)
        return 200

    def body(self) raises -> String:
        return String(len(to_muntin_headers(self.request)))


struct Case(Copyable):
    var label: String
    var method: String
    var path: String
    var headers: Int
    var body: Int
    var expect: String

    def __init__(
        out self,
        label: String,
        method: String,
        path: String,
        headers: Int,
        body: Int,
        expect: String,
    ):
        self.label = label
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.expect = expect

    def request(self) raises -> FlareRequest:
        var req = FlareRequest(self.method, self.path)
        for i in range(self.headers):
            var n = String(i)
            while n.byte_length() < 3:
                n = "0" + n
            req.headers.append("X-Bench-" + n, "value-" + n)
        if self.label == "json-post":
            req.headers.append("Content-Type", "application/json")
            req.body = List(String(JSON_IN).as_bytes())
        elif self.body > 0:
            var bytes = List[UInt8](capacity=self.body)
            for i in range(self.body):
                bytes.append(UInt8(ord("a") + i % 26))
            req.body = bytes^
        return req^


def cases() -> List[Case]:
    var out = List[Case]()
    for h in materialize[HEADER_COUNTS]():
        out.append(
            Case("plaintext", "GET", "/plaintext", h, 0, "Hello, World!")
        )
    out.append(
        Case("json-get", "GET", "/json", 0, 0, '{"message":"Hello, World!"}')
    )
    out.append(
        Case(
            "json-post",
            "POST",
            "/json",
            0,
            0,
            '{"id":1,"name":"Ada","age":36}',
        )
    )
    for b in materialize[BODY_SIZES]():
        out.append(Case("echo", "POST", "/echo", 0, b, ""))
    return out^


def measure[
    D: Dispatch
](c: Case, middleware: Bool, impl: String, d: D, runs: Int) raises:
    var name = (
        c.label
        + "\th="
        + String(c.headers)
        + "\tb="
        + String(c.body)
        + "\tmw="
        + String(Int(middleware))
        + "\t"
        + impl
    )
    var got = d.status()
    if got != 200:
        raise Error(name + ": status " + String(got) + ", expected 200")
    var expect = c.expect
    if c.label == "echo":
        expect = String(unsafe_from_utf8=c.request().body)
    elif impl == "headers":
        expect = String(c.headers)
    if d.body() != expect:
        raise Error(name + ": unexpected body")
    print(name + "\t" + time_per_request(d, runs, 200).columns())


def main() raises:
    var runs = runs_arg()
    for mw in [False, True]:
        for c in cases():
            measure(c, mw, "muntin", MuntinCore(mw, c.request()), runs)
            measure(
                c, mw, "muntin+adapter", MuntinAdapter(mw, c.request()), runs
            )
            if mw:
                measure(
                    c,
                    mw,
                    "flare",
                    FlareDirect(Tracing(router()), c.request()),
                    runs,
                )
            else:
                measure(
                    c, mw, "flare", FlareDirect(router(), c.request()), runs
                )
            if c.label == "plaintext" and not mw:
                measure(c, mw, "headers", HeaderConversion(c.request()), runs)
