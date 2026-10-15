# Must build, and is never run (scripts/check.sh builds it only; run, the
# request reads freed memory). Found by "Request context storage decision
# (M3-065)" in docs/history/architecture-decisions.md, and a gap in production
# `State` today: a route erases its `State[S]`, and `App`'s type does not carry
# the origins in `S`, so a state that borrows a local registers, the checker
# ends the local at its last use, and a later request reads it
# (AddressSanitizer: heap-use-after-free, pull request #118). It takes a handler
# instantiated with the local's origin, in safe code that names no `_` member.
#
# If this file stops building, registration refuses or tracks a state that
# borrows a local: the gap is closed; drop it from docs/ARCHITECTURE.md.

from std.memory import OwnedPointer

from muntin import App, State
from muntin.testing import TestClient


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](view: State[View[o]]) -> String:
    return String(view[].p[])


@no_inline
def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], State(View(token[])))


def main() raises:
    var app = App()
    build(app)
    var client = TestClient(app)
    _ = client.get("/")
