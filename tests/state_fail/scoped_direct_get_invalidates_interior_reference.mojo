# Must not compile (A2 evidence): a registration on the app is a `mut self`
# call, so Mojo 1.1.0 invalidates an interior reference into the app taken
# before it. The same write made through a live registrar's stored
# `Pointer` compiles (tests/state_known_gaps/registrar_blind_mutation.mojo,
# built and never run; it reads freed memory after the route
# list reallocates): the checker does not see writes inside the registrar's
# methods as mutations of the app. That blind mutation path is why A2 is
# rejected on Mojo 1.1.0 (docs/ARCHITECTURE.md, "Application state decision
# (M3-001)").
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference

from muntin import Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


def plain() -> String:
    return "plain"


def main():
    var app = ScopedApp()
    app.get["/p"](plain)
    ref r = app._routes[0]
    for _ in range(100):
        app.get["/q"](plain)
    print(r.path)
