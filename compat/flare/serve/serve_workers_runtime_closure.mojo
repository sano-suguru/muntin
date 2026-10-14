# Must not compile (M3-049): `Server.serve[make]` builds one `App` per worker
# with `make`, a compile-time parameter of `thin` function type. A closure
# that captures a value at run time is not a compile-time value, so it cannot
# be `make`, and no value it holds can reach every worker's `App`. If this
# builds, revisit docs/history/architecture-decisions.md "Multi-worker
# serving decision (M3-049)" before relaxing it.
# Expected diagnostic (checked by scripts/check_flare.sh): cannot use a dynamic value in a parameter list
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

    def make() raises {var shared^} -> App:
        var app = App()
        app.get["/count"](count, shared)
        return app^

    var server = Server.bind("127.0.0.1", 0)
    server.serve[make](workers=2)
