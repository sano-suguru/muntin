"""What one request costs in process, without the network: Muntin against
Flare alone, on the benchmark application (`muntin_app.mojo`,
`flare_app.mojo`). Not part of Muntin; `scripts/bench_overhead.sh` builds
and runs it, and CI builds it and runs `bench_adapter count` once
(`scripts/check_flare.sh`), as a smoke test.

Each request is built once, before timing, as a Flare `Request`; the Muntin
`Request` is the adapter's conversion of it (`to_muntin_request`). A timed
iteration is one call and the response it returns, dropped. Before timing,
every implementation's answer to the case is checked: its status and its
body. Timed answers are checked by status (`bench/routing/harness.mojo`).

Implementations:
- `muntin`: `App.handle(Request)`, Muntin's routing, handler and conversions
  alone. The request is reused, so this is the borrowing `handle`, which
  copies it for the middleware (`mw=1`). Since M3-064 `TestClient` and the
  Flare adapter hand their request over and do not pay that copy; a caller
  that lends a named request still does.
- `muntin+adapter`: `MuntinHandler.serve` on the Flare `Request`: the
  adapter's conversions around `App.handle` (request target, headers and a
  copy of the body in; status and headers out, the body moved), what a
  request served by `Server` pays besides the network. Its field limit
  (M3-066) is raised to `MAX_FIELDS`, so the 128-field case is converted, as
  by a `Server` bound with `max_header_fields` that high, not answered 431.
- `flare`: Flare's `Router.serve` (`Tracing[Router]` with the middleware).
- `headers`: `to_muntin_headers` alone, the adapter's request header
  conversion; `plaintext` cases without the middleware.
- `copy`: one copy of the request body (`List[UInt8].copy()`), what each
  body copy costs; `echo` cases without the middleware.

Cases, each with and without the middleware (`mw=1`, `mw=0`):
Every request carries `Host: bench` first (M3-073), then:
- `plaintext`, with `h` request header fields named `X-Bench-000` up to
  `X-Bench-127`, each name distinct, so `to_muntin_headers` calls Flare's
  `get_all` once per field and each call scans every field (before #110,
  names of one length were also compared pair by pair in the adapter);
- `json-get` and `json-post` (`{"name":"Ada","age":36}`, its one field
  `Content-Type: application/json`);
- `echo`, a `b`-byte body.

Each line printed is one case and one implementation, in nanoseconds per
request: the median and the minimum over the timed runs.

    bench_adapter count

counts allocations instead of timing, under `count_alloc.c` (LD_PRELOAD;
it raises without it), which defines each counter: for each case and
implementation, after one request that warms it up, what each of `COUNTED`
more requests allocates, reallocates and frees, the response's drop
included (`COUNTERS`). A value is printed as `min..max` when the requests
differ. The new blocks of 64 KiB or more (`large_allocs`) stand for a large
body's copies, because each `.copy()` of a body allocates its length; before
the cases, a calibration (`calibrate`) checks that `large_allocs` and
`large_alloc_bytes` follow 0 to 3 copies of a 1 MiB body exactly, and raises
otherwise. Which code makes each copy is not checked here.
"""

from std.ffi import external_call
from std.sys import argv

from flare.http import Handler, Router
from flare.http import Request as FlareRequest
from muntin import App, Request
from muntin_flare import MuntinHandler, to_muntin_headers, to_muntin_request

from harness import Dispatch, runs_arg, time_per_request
from flare_app import Tracing, router
from muntin_app import build


comptime HEADER_COUNTS: List[Int] = [0, 8, 16, 32, 128]
comptime MAX_FIELDS = 129
"""`MuntinHandler`'s field limit: the largest case's fields and `Host`."""
comptime BODY_SIZES: List[Int] = [0, 1024, 65536, 1048576]
comptime JSON_IN = '{"name":"Ada","age":36}'
comptime COUNTED = 8
comptime COUNTERS: List[String] = [
    "allocs",
    "alloc_bytes",
    "frees",
    "reallocs",
    "realloc_moves",
    "large_allocs",
    "large_alloc_bytes",
    "large_reallocs",
]
"""`count_alloc.c`'s `muntin_count`, in order."""


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
        self.handler = MuntinHandler(
            build(middleware), max_header_fields=MAX_FIELDS
        )
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


struct BodyCopy(Dispatch):
    """`copies` copies of the body, each dropped at once."""

    var bytes: List[UInt8]
    var copies: Int

    def __init__(out self, request: FlareRequest, copies: Int = 1):
        self.bytes = request.body.copy()
        self.copies = copies

    def status(self) raises -> Int:
        var copied = 0
        for _ in range(self.copies):
            copied += len(self.bytes.copy())
        return 200 if copied == self.copies * len(self.bytes) else 500

    def body(self) raises -> String:
        return String(unsafe_from_utf8=self.bytes.copy())


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
        # The adapter answers an HTTP/1.1 request without one 400 (M3-073).
        req.headers.append("Host", "bench")
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


def _counters() raises -> Pointer[Int64, MutAnyOrigin]:
    var name = String("muntin_count")
    var address = external_call["dlsym", Int](
        Int(0), name.as_c_string_span().ptr()
    )
    if address == 0:
        raise Error("count: run under LD_PRELOAD=count_alloc.so")
    return Pointer[Int64, MutAnyOrigin](unsafe_from_address=address)


def _ranges[
    D: Dispatch
](d: D, mut low: List[Int64], mut high: List[Int64]) raises:
    """Sets `low` and `high` to the lowest and highest value of each counter
    per request, over `COUNTED` requests after one warm-up request."""
    var counters = _counters()
    var k = len(materialize[COUNTERS]())
    _ = d.status()
    low = List[Int64](length=k, fill=Int64.MAX)
    high = List[Int64](length=k, fill=Int64.MIN)
    for _ in range(COUNTED):
        var before = List[Int64](capacity=k)
        for i in range(k):
            before.append(counters[unsafe_offset=i])
        if d.status() != 200:
            raise Error("unexpected status while counting")
        for i in range(k):
            var n = counters[unsafe_offset=i] - before[i]
            low[i] = min(low[i], n)
            high[i] = max(high[i], n)


def count[D: Dispatch](d: D) raises -> String:
    """`COUNTERS` per request after one warm-up request, as columns."""
    var names = materialize[COUNTERS]()
    var k = len(names)
    var low = List[Int64]()
    var high = List[Int64]()
    _ranges(d, low, high)
    var out = String()
    for i in range(k):
        if i > 0:
            out += "\t"
        out += names[i] + "=" + String(low[i])
        if high[i] != low[i]:
            out += ".." + String(high[i])
    return out^


def calibrate() raises:
    """Raises unless `large_allocs` and `large_alloc_bytes` count exactly
    0, 1, 2 and 3 copies of a 1 MiB body, every request alike."""
    var names = materialize[COUNTERS]()
    var large = -1
    var large_bytes = -1
    for i in range(len(names)):
        if names[i] == "large_allocs":
            large = i
        elif names[i] == "large_alloc_bytes":
            large_bytes = i
    var request = Case("echo", "POST", "/echo", 0, 1048576, "").request()
    for copies in range(4):
        var low = List[Int64]()
        var high = List[Int64]()
        _ranges(BodyCopy(request, copies), low, high)
        var want = Int64(copies)
        if (
            low[large] != want
            or high[large] != want
            or low[large_bytes] != want * 1048576
            or high[large_bytes] != want * 1048576
        ):
            raise Error(
                "count: large_allocs does not follow "
                + String(copies)
                + " body copies"
            )
        print(
            "calibration\tcopies="
            + String(copies)
            + "\tlarge_allocs="
            + String(want)
        )


def measure[
    D: Dispatch
](
    c: Case, middleware: Bool, impl: String, d: D, runs: Int, counting: Bool
) raises:
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
        expect = String(c.headers + 1)  # the `X-Bench` fields and `Host`
    if d.body() != expect:
        raise Error(name + ": unexpected body")
    if counting:
        print(name + "\t" + count(d))
    else:
        print(name + "\t" + time_per_request(d, runs, 200).columns())


def main() raises:
    var args = argv()
    var counting = len(args) > 1 and args[1] == "count"
    var runs = 1 if counting else runs_arg()
    if counting:
        calibrate()
    for mw in [False, True]:
        for c in cases():
            var r = c.request()
            measure(c, mw, "muntin", MuntinCore(mw, r), runs, counting)
            measure(
                c,
                mw,
                "muntin+adapter",
                MuntinAdapter(mw, c.request()),
                runs,
                counting,
            )
            if mw:
                measure(
                    c,
                    mw,
                    "flare",
                    FlareDirect(Tracing(router()), c.request()),
                    runs,
                    counting,
                )
            else:
                measure(
                    c,
                    mw,
                    "flare",
                    FlareDirect(router(), c.request()),
                    runs,
                    counting,
                )
            if c.label == "plaintext" and not mw:
                measure(
                    c,
                    mw,
                    "headers",
                    HeaderConversion(c.request()),
                    runs,
                    counting,
                )
            if c.label == "echo" and not mw:
                measure(c, mw, "copy", BodyCopy(r), runs, counting)
