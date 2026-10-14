"""Routing cost by route count: Muntin against Flare's runtime `Router`.

Not part of Muntin and not run by CI. `scripts/bench_routing.sh` writes the
route table for one route count `N` as the module `routes` (`N` `GET` routes
`/api/r{i}/items`, each answering `ok`), builds this program and
`bench_comptime_router.mojo` against it in the `flare` environment and runs
them. Each line printed is one implementation and one case, in nanoseconds
per request: the median and the minimum over the timed runs.

Cases (`harness.cases`): `first` (`GET` of the first route), `last` (`GET`
of the last route), `404` (`GET` of a path no route has) and `405` (`POST`
to the last route's path). Each request is built once, before timing; a
timed iteration is one dispatch and the response it returns, dropped. Every
answer's status is checked, so a case that does not take the intended path
stops the program.

Implementations here:
- `muntin`: `App.handle(Request)`, Muntin's routing and dispatch alone.
- `muntin+adapter`: `MuntinHandler.serve` on a Flare `Request`: the
  adapter's conversions around `App.handle`, what a request served by
  `Server` pays besides the network.
- `flare-router`: Flare's runtime `Router.serve`.
"""

from flare.http import Router
from flare.http import Request as FlareRequest
from muntin import App, Request
from muntin_flare import MuntinHandler

from harness import Dispatch, cases, measure, route_path, runs_arg
from routes import N, flare_ok, register


struct MuntinCore(Dispatch):
    var app: App
    var request: Request

    def __init__(out self, method: String, path: String):
        self.app = App()
        register(self.app)
        self.request = Request(method, path)

    def status(self) raises -> Int:
        return self.app.handle(self.request).status


struct MuntinAdapter(Dispatch):
    var handler: MuntinHandler
    var request: FlareRequest

    def __init__(out self, method: String, path: String):
        var app = App()
        register(app)
        self.handler = MuntinHandler(app^)
        self.request = FlareRequest(method, path)

    def status(self) raises -> Int:
        return self.handler.serve(self.request).status


struct FlareRouter(Dispatch):
    var router: Router
    var request: FlareRequest

    def __init__(out self, method: String, path: String) raises:
        self.router = Router()
        for i in range(N):
            self.router.get(route_path(i), flare_ok)
        self.request = FlareRequest(method, path)

    def status(self) raises -> Int:
        return self.router.serve(self.request).status


def main() raises:
    var runs = runs_arg()
    for c in cases(N):
        measure(
            N, "muntin", c.label, MuntinCore(c.method, c.path), c.want, runs
        )
        measure(
            N,
            "muntin+adapter",
            c.label,
            MuntinAdapter(c.method, c.path),
            c.want,
            runs,
        )
        measure(
            N,
            "flare-router",
            c.label,
            FlareRouter(c.method, c.path),
            c.want,
            runs,
        )
