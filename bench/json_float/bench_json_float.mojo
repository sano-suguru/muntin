"""What reading JSON floats costs through a `Json[T]` route: M3-078's
revisit condition. Not part of Muntin; `scripts/bench_json_float.py` builds
it against the working tree's `src` and a base revision's, and runs both.

For each kind of literal it builds a JSON array of that literal just under
1 MiB and sends it REQUESTS times (the first argument) through `App.handle`
to two routes: `/floats`, whose `from_json` reads every element with
`float()`, and `/count`, which only counts them (parsing alone). A timed
request is building the `Request` with a copy of the body and the call. It
prints one tab-separated line per kind and route: kind, route, the status of
the last answer, then p50, p95 and p99 in milliseconds.
"""
from std.sys import argv
from std.time import perf_counter_ns

from muntin import App, FromJson, Headers, Json, JsonValue, Request


struct Floats(FromJson):
    var n: Int
    var sum: Float64

    def __init__(out self, n: Int, sum: Float64):
        self.n = n
        self.sum = sum

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var s = Float64(0)
        for i in range(len(value)):
            s += value[i].float()
        return Floats(len(value), s)


struct Counted(FromJson):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Counted(len(value))


def read_floats(body: Json[Floats]) -> String:
    return String(body.value.n, " ", body.value.sum)


def count_only(body: Json[Counted]) -> String:
    return String(body.value.n)


def array_of(item: String) -> String:
    var out = String("[")
    var first = True
    while out.byte_length() + item.byte_length() + 2 < 1_048_576:
        if not first:
            out += ","
        out += item
        first = False
    out += "]"
    return out^


def percentile(var xs: List[Int], p: Int) -> Float64:
    sort(xs)
    return Float64(xs[(len(xs) - 1) * p // 100]) / 1e6


def run(app: App, kind: String, target: String, body: String, n: Int) raises:
    var times = List[Int]()
    var status = 0
    for _ in range(n):
        var h = Headers()
        h.add("Content-Type", "application/json")
        var t0 = perf_counter_ns()
        var r = app.handle(Request("POST", target, body, h^))
        var t1 = perf_counter_ns()
        status = r.status
        times.append(Int(t1 - t0))
    print(
        kind,
        target,
        status,
        percentile(times.copy(), 50),
        percentile(times.copy(), 95),
        percentile(times.copy(), 99),
        sep="\t",
    )


def main() raises:
    var app = App()
    app.post["/floats"](read_floats)
    app.post["/count"](count_only)
    var n = Int(argv()[1])
    # The slowest kinds for M3-078's slow path are the 17-digit literals
    # near both ends of the range; `atof` raises on the 900-digit one.
    var kinds: List[String] = [
        "1.5",
        "0.30000000000000004",
        "-2.7546748226290886e+20",
        "2.2250738585072011e-308",
        "4.9406564584124654e-324",
        "1.7976931348623157e308",
        String("1.") + "7" * 900 + "e308",
    ]
    var names: List[String] = [
        "1.5",
        "0.30000000000000004",
        "-2.7546748226290886e+20",
        "2.2250738585072011e-308",
        "4.9406564584124654e-324",
        "1.7976931348623157e308",
        "900 digits",
    ]
    for i in range(len(kinds)):
        var body = array_of(kinds[i])
        run(app, names[i], "/count", body, n)
        run(app, names[i], "/floats", body, n)
