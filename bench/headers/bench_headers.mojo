"""Request header conversion cost: the Flare adapter's `to_muntin_headers`
by header shape, in process. Not part of Muntin and not run by CI;
`scripts/bench_headers.sh` builds and runs it.

Each case builds one Flare request before timing; a timed iteration is one
conversion and the `Headers` it returns, dropped. Before timing, the
conversion is checked to return every field. Each case is measured twice:
`adapter`, the adapter's `to_muntin_headers`, and `pieces`, the rebuild
M3-066 rejected (`pieces_rebuild.mojo`, a prototype), with the same
calibration rule and their timed runs
alternating, so both see the same machine state. Each line printed is one
case and one conversion: nanoseconds per conversion, the median and the
minimum over the timed runs.

Cases: `browser12` (a browser's `GET`: 12 fields, 11 names), `distinctN`
(N fields, each its own name, all names 7 bytes long), `sameN` (N fields
named `x-a`), and the two largest shapes Flare v0.12.0 admits over HTTP/1.1,
whose `max_header_size` (8192) counts each header line without its CRLF:
`same4000-empty` (4000 fields `a:`) and `distinct2600-2byte` (2600 fields,
each a two-byte name and an empty value). Over h2c Flare's header list
limit (16384, 32 bytes counted per field) admits about 470 fields.
"""

from std.sys import argv
from std.time import perf_counter_ns

from flare.http import Request as FlareRequest
from muntin_flare import to_muntin_headers
from pieces_rebuild import rebuild_fields


comptime MIN_RUN_NS = 20_000_000
"""Calibration doubles the iterations of one run until it takes this long."""

comptime TOKEN_BYTES = "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
"""Every byte a name may hold, letters in one case: 51, so 2601 two-byte
names that differ ASCII case-insensitively."""


def browser() raises -> FlareRequest:
    var r = FlareRequest("GET", "/")
    r.headers.append("Host", "example.com")
    r.headers.append(
        "User-Agent",
        (
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like"
            " Gecko) Chrome/141.0.0.0 Safari/537.36"
        ),
    )
    r.headers.append(
        "Accept",
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    )
    r.headers.append("Accept-Language", "ja,en-US;q=0.9,en;q=0.8")
    r.headers.append("Accept-Encoding", "gzip, deflate, br, zstd")
    r.headers.append("Connection", "keep-alive")
    r.headers.append("Cookie", "session=abc123; theme=dark")
    r.headers.append("Cookie", "lang=ja")
    r.headers.append("Upgrade-Insecure-Requests", "1")
    r.headers.append("Sec-Fetch-Dest", "document")
    r.headers.append("Sec-Fetch-Mode", "navigate")
    r.headers.append("Sec-Fetch-Site", "none")
    return r^


def _pad4(i: Int) -> String:
    var s = String(i)
    while s.byte_length() < 4:
        s = "0" + s
    return s^


def distinct(n: Int) raises -> FlareRequest:
    var r = FlareRequest("GET", "/")
    for i in range(n):
        r.headers.append("x-h" + _pad4(i), "v")
    return r^


def same(n: Int, value: Bool) raises -> FlareRequest:
    var r = FlareRequest("GET", "/")
    for i in range(n):
        if value:
            r.headers.append("x-a", "v" + _pad4(i))
        else:
            r.headers.append("a", "")
    return r^


def distinct_two_byte(n: Int) raises -> FlareRequest:
    var t = StringSlice(TOKEN_BYTES)
    var k = t.byte_length()
    if n > k * k:
        raise Error("at most " + String(k * k) + " two-byte names")
    var r = FlareRequest("GET", "/")
    for i in range(n):
        var name = String(t[byte = i // k : i // k + 1])
        name += t[byte = i % k : i % k + 1]
        r.headers.append(name, "")
    return r^


def _convert(r: FlareRequest, pieces: Bool) raises -> Int:
    """How many fields one conversion returns."""
    if pieces:
        var h = rebuild_fields(r.headers)
        if not h:
            raise Error("write_to's pieces changed")
        return len(h.value())
    return len(to_muntin_headers(r))


def _run(r: FlareRequest, iters: Int, pieces: Bool) raises -> Int:
    """Nanoseconds for `iters` conversions."""
    var fields = 0
    var start = perf_counter_ns()
    for _ in range(iters):
        fields += _convert(r, pieces)
    var elapsed = Int(perf_counter_ns() - start)
    if fields != iters * r.headers.len():
        raise Error("a conversion lost fields")
    return elapsed


def _calibrate(r: FlareRequest, pieces: Bool) raises -> Int:
    var iters = 1
    while _run(r, iters, pieces) < MIN_RUN_NS:
        iters *= 2
    return iters


def _report(
    label: String, kind: String, fields: Int, mut times: List[Int], iters: Int
):
    sort(times)
    var m = len(times) // 2
    var median = (
        times[m] if len(times) % 2 == 1 else (times[m - 1] + times[m]) // 2
    )
    print(
        label,
        "\t",
        kind,
        "\tfields=",
        fields,
        "\tmedian_ns=",
        median,
        "\tmin_ns=",
        times[0],
        "\titers=",
        iters,
        sep="",
    )


def measure(label: String, r: FlareRequest, runs: Int) raises:
    for pieces in [False, True]:
        if _convert(r, pieces) != r.headers.len():
            raise Error(label + ": a field is missing")
    var adapter_iters = _calibrate(r, False)
    var pieces_iters = _calibrate(r, True)
    var adapter = List[Int]()
    var pieces = List[Int]()
    for i in range(runs):
        # Alternate which goes first, so neither always runs warm.
        if i % 2 == 0:
            adapter.append(_run(r, adapter_iters, False) // adapter_iters)
            pieces.append(_run(r, pieces_iters, True) // pieces_iters)
        else:
            pieces.append(_run(r, pieces_iters, True) // pieces_iters)
            adapter.append(_run(r, adapter_iters, False) // adapter_iters)
    _report(label, "adapter", r.headers.len(), adapter, adapter_iters)
    _report(label, "pieces", r.headers.len(), pieces, pieces_iters)


def main() raises:
    var runs = 11
    if len(argv()) > 1:
        runs = Int(argv()[1])
    if runs < 1:
        raise Error("runs must be at least 1: " + String(runs))
    measure("browser12", browser(), runs)
    for n in [10, 100, 1000]:
        measure("distinct" + String(n), distinct(n), runs)
        measure("same" + String(n), same(n, True), runs)
    measure("same4000-empty", same(4000, False), runs)
    measure("distinct2600-2byte", distinct_two_byte(2600), runs)
