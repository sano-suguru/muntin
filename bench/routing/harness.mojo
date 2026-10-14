"""Timing and reporting shared by the routing benchmark programs. Not part of
Muntin; `bench_routing.mojo` says what is measured."""

from std.time import perf_counter_ns


comptime MIN_RUN_NS = 20_000_000
"""Calibration doubles the iterations of one run until it takes this long."""


trait Dispatch:
    """One implementation answering one prepared request."""

    def status(self) raises -> Int:
        """Dispatches the request once and returns the answer's status."""
        ...


def route_path(i: Int) -> String:
    """The path of the `i`-th generated route."""
    return "/api/r" + String(i) + "/items"


def _run[D: Dispatch](d: D, iters: Int, want: Int) raises -> Int:
    """Nanoseconds for `iters` dispatches; raises if any answer is not
    `want`."""
    var bad = 0
    var start = perf_counter_ns()
    for _ in range(iters):
        bad += Int(d.status() != want)
    var elapsed = Int(perf_counter_ns() - start)
    if bad != 0:
        raise Error("unexpected status during timing")
    return elapsed


def measure[
    D: Dispatch
](n: Int, name: String, label: String, d: D, want: Int, runs: Int) raises:
    """Checks one answer, calibrates (which warms up), times `runs` runs and
    prints one line: nanoseconds per request, median and minimum."""
    var got = d.status()
    if got != want:
        raise Error(
            name
            + " "
            + label
            + ": status "
            + String(got)
            + ", expected "
            + String(want)
        )
    var iters = 1
    while _run(d, iters, want) < MIN_RUN_NS:
        iters *= 2
    var per = List[Int]()
    for _ in range(runs):
        per.append(_run(d, iters, want) // iters)
    sort(per)
    print(
        "N="
        + String(n)
        + "\t"
        + name
        + "\t"
        + label
        + "\tmedian_ns="
        + String(per[len(per) // 2])
        + "\tmin_ns="
        + String(per[0])
        + "\titers="
        + String(iters)
    )


struct Case(Copyable):
    """One request shape and the status every implementation must answer."""

    var label: String
    var method: String
    var path: String
    var want: Int

    def __init__(
        out self, label: String, method: String, path: String, want: Int
    ):
        self.label = label
        self.method = method
        self.path = path
        self.want = want


def cases(n: Int) -> List[Case]:
    """`first`, `last`, `404` and `405` for a table of `n` routes."""
    return [
        Case("first", "GET", route_path(0), 200),
        Case("last", "GET", route_path(n - 1), 200),
        Case("404", "GET", "/api/missing/items", 404),
        Case("405", "POST", route_path(n - 1), 405),
    ]


def runs_arg() raises -> Int:
    """The number of timed runs per case: the first argument, default 15."""
    from std.sys import argv

    var args = argv()
    return Int(args[1]) if len(args) > 1 else 15
