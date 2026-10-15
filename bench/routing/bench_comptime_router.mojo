"""Routing cost by route count for Flare's `ComptimeRouter[ROUTES]`, the
counterpart of `bench_routing.mojo` (which says what is measured), built on
its own because its build time grows steeply with the route count. Not part
of Muntin and not run by CI."""

from flare.http import ComptimeRouter
from flare.http import Request as FlareRequest

from harness import Dispatch, cases, measure, runs_arg
from routes import FLARE_ROUTES, N


struct FlareComptime(Dispatch):
    var router: ComptimeRouter[FLARE_ROUTES]
    var request: FlareRequest

    def __init__(out self, method: String, path: String):
        self.router = ComptimeRouter[FLARE_ROUTES]()
        self.request = FlareRequest(method, path)

    def status(self) raises -> Int:
        return self.router.serve(self.request).status

    def body(self) raises -> String:
        return self.router.serve(self.request).text()


def main() raises:
    var runs = runs_arg()
    for c in cases(N):
        measure(
            N,
            "flare-comptime",
            c,
            FlareComptime(c.method, c.path),
            runs,
        )
