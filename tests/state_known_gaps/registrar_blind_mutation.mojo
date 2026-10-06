# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Application state decision (M3-001)":
# why the scoped registrar (A2) is rejected on Mojo 1.1.0.
#
# A registration through a registrar that was live before an interior reference
# `r` into the app was taken writes to the app through the registrar's stored
# `Pointer`, and Mojo 1.1.0 does not treat that write as a mutation of the app:
# `r` is still accepted afterwards, although the route list may have reallocated
# (running this reads freed memory). The same registration made directly on the
# app is rejected (tests/state_fail/
# scoped_direct_get_invalidates_interior_reference.mojo: `use of invalidated
# interior reference`).
#
# If this file stops building, Mojo now tracks mutation through stored
# mutable references: the A2 revisit condition has fired. Re-measure A2
# (tests/scoped_state_spike.mojo) instead of editing this file to build.

from muntin import Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def plain() -> String:
    return "plain"


def handler(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = ScopedApp()
    app.get["/p"](plain)
    # `with_state` is itself a `mut self` call on the app, so the registrar
    # must exist before the reference is taken; created after it, it
    # invalidates `r` like a direct registration.
    var api = app.with_state(State(Db(1)))
    ref r = app._routes[0]
    for _ in range(100):
        api.get["/x"](handler)
    print(r.path)
