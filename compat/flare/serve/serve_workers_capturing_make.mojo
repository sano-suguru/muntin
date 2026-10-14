# Must not compile (M3-049): `Server.serve[make]` takes `make` as a `thin`
# function, which captures nothing. A compile-time closure (`@__parameter`)
# that captures a local is `capturing`, so it is refused, and no value it
# reaches can be shared by every worker's `App`. If this builds, revisit
# docs/history/architecture-decisions.md "Multi-worker serving decision
# (M3-049)" before relaxing it.
# Expected diagnostic (checked by scripts/check_flare.sh): has 'def() raises thin -> App' type, but value has type 'def() raises capturing thin -> App'
from muntin import App, State
from muntin_flare import Server


struct Counter(Movable):
    var hits: Int

    def __init__(out self):
        self.hits = 0


def count(state: State[Counter]) -> String:
    return String(state[].hits)


def main() raises:
    var shared = State(Counter())

    @__parameter
    def make() raises -> App:
        var app = App()
        app.get["/count"](count, shared)
        return app^

    var server = Server.bind("127.0.0.1", 0)
    server.serve[make](workers=2)
